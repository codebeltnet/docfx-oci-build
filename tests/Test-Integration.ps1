#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Bundled', 'Custom', 'Legacy', 'Production', 'UnavailableBuilder', 'GenerationFailure', 'MissingOutput', 'ExportFailure')]
    [string]$Scenario,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$ConsumerRoot,
    [string]$VerifierPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$nativeDocker = (Get-Command docker -CommandType Application | Select-Object -First 1).Source
$productionPackaging = $Scenario -eq 'Production'
$testNginx = 'ghcr.io/nginx/nginx-unprivileged:1.31-alpine'
$testVersion = '8.4.3-rc.1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) "docfx-integration-$([guid]::NewGuid().ToString('N'))"
$tracked = @{ Container = $null; Builder = $null }
$expectedFailure = @{
    UnavailableBuilder = 'Could not create a container from DocFX builder image'
    GenerationFailure = 'DocFX framework views failed'
    MissingOutput = 'Could not retrieve'
    ExportFailure = 'Docker Buildx failed to create the DocFX OCI artifact'
}[$Scenario]

# Invoke real Docker. Keep the public test base and injected faults here.
function docker {
    $arguments = @($args)
    if ($arguments[0] -eq 'create') {
        if ($Scenario -eq 'UnavailableBuilder') {
            $imageIndex = [Array]::IndexOf($arguments, 'pwsh') + 1
            if ($arguments[$imageIndex] -eq '--') { $imageIndex++ }
            $arguments[$imageIndex] = "docfx-missing:$([guid]::NewGuid().ToString('N'))"
            $arguments[2] = 'never'
        }
        $tracked.Container = & $nativeDocker @arguments
        return $tracked.Container
    }

    if ($Scenario -eq 'MissingOutput' -and $arguments[0] -eq 'cp' -and $arguments[1].EndsWith(':/tmp/docfx-output/site')) {
        # Ask real Docker to retrieve a missing path after the engine exits successfully.
        $arguments[1] = "$($tracked.Container):/tmp/docfx-output/absent-site"
    }
    if ($arguments[0] -eq 'buildx' -and $arguments[1] -eq 'create') {
        $tracked.Builder = $arguments[[Array]::IndexOf($arguments, '--name') + 1]
    }
    if ($arguments[0] -eq 'buildx' -and $arguments[1] -eq 'build') {
        $file = $arguments[[Array]::IndexOf($arguments, '--file') + 1]
        if ([IO.Path]::GetFileName($file) -eq 'framework-views.Dockerfile') {
            $dockerfileText = Get-Content -LiteralPath $file -Raw
            if ($dockerfileText -notmatch '(?m)^ARG NGINX_IMAGE=dhi\.io/nginx:.+@sha256:[a-f0-9]{64}\r?$') {
                throw 'The bundled Dockerfile must retain the hardened NGINX default.'
            }
            if (!$productionPackaging) {
                $arguments = $arguments[0], $arguments[1], '--build-arg', "NGINX_IMAGE=$testNginx" + $arguments[2..($arguments.Length - 1)]
            }
        } elseif ($Scenario -in 'Bundled', 'Production') {
            throw "Expected bundled packaging, received '$file'."
        }
        if ($Scenario -ne 'Legacy') {
            $context = $arguments[-1]
            $manifest = Get-Content -LiteralPath "$context/site/framework-views.json" -Raw | ConvertFrom-Json
            if (!(Test-Path -LiteralPath "$context/nginx.conf" -PathType Leaf) -or @($manifest.viewOrder).Count -lt 2) {
                throw 'Expected generated NGINX routing and more than one native framework view.'
            }
            if ($Scenario -eq 'ExportFailure') {
                $arguments = $arguments[0], $arguments[1], '--target', 'target-does-not-exist' + $arguments[2..($arguments.Length - 1)]
            }
        }
    }
    & $nativeDocker @arguments
}

$previousRunnerTemp = $env:RUNNER_TEMP
$previousGithubOutput = $env:GITHUB_OUTPUT
try {
    if (!$ConsumerRoot) {
        $ConsumerRoot = Join-Path $scratch 'checkout'
        New-Item -ItemType Directory -Path $ConsumerRoot -Force | Out-Null
        Get-ChildItem -LiteralPath "$PSScriptRoot/fixture" -Force | Copy-Item -Destination $ConsumerRoot -Recurse
        if ($Scenario -eq 'GenerationFailure') {
            Set-Content -LiteralPath "$ConsumerRoot/.docfx/docfx.json" -Value '{'
        }
        & git -C $ConsumerRoot init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the fixture repository.' }
        & git -C $ConsumerRoot add --all
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the fixture sources.' }
        & git -C $ConsumerRoot -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgSign=false commit --quiet -m fixture
        if ($LASTEXITCODE -ne 0) { throw 'Could not commit the fixture.' }
    }

    $consumerRevision = & git -C $ConsumerRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Could not get the fixture revision.' }
    $beforeStatus = & git -C $ConsumerRoot status --porcelain --untracked-files=all
    if ($LASTEXITCODE -ne 0 -or $beforeStatus) { throw 'Integration requires a clean consumer checkout.' }
    $parameters = @{
        Version = $testVersion
        Revision = $consumerRevision
        OutputPath = [IO.Path]::GetFullPath($OutputPath)
        WorkspaceRoot = $ConsumerRoot
        DocfxConfig = '.docfx/docfx.json'
        Platforms = 'linux/amd64,linux/arm64'
        FrameworkViews = 'true'
    }
    if ($Scenario -eq 'Custom') {
        $parameters.Dockerfile = '.docfx/Dockerfile.framework'
    } elseif ($Scenario -eq 'Legacy') {
        $parameters.FrameworkViews = 'false'
        $parameters.DocfxConfig = '.docfx/legacy.json'
    }
    $env:RUNNER_TEMP = Join-Path $scratch 'staging'
    $env:GITHUB_OUTPUT = if ($previousGithubOutput) { $previousGithubOutput } else { Join-Path $scratch 'outputs' }
    New-Item -ItemType Directory -Path $env:RUNNER_TEMP -Force | Out-Null
    try {
        & "$PSScriptRoot/../scripts/build-docfx-oci.ps1" @parameters
        if ($expectedFailure) { throw 'An expected failure did not occur.' }
    } catch {
        if (!$expectedFailure -or $_.Exception.Message -notlike "*$expectedFailure*") { throw }
        if ((Test-Path -LiteralPath $parameters.OutputPath) -or (Test-Path -LiteralPath "$($parameters.OutputPath).sha256") -or
            (Test-Path -LiteralPath $env:GITHUB_OUTPUT) -and (Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw) -match '(?m)^(archive-path|checksum-path|digest)=') {
            throw 'A failed build exposed files or outputs.'
        }
        Write-Host "Caught expected failure for $Scenario."
    }
    if ($tracked.Container) {
        $containers = & $nativeDocker ps -aq --no-trunc --filter "id=$($tracked.Container)"
        if ($LASTEXITCODE -ne 0 -or $containers) { throw 'Framework builder container leaked.' }
    }
    if ($tracked.Builder) {
        $builders = & $nativeDocker buildx ls --format '{{.Name}}'
        if ($LASTEXITCODE -ne 0 -or $tracked.Builder -in $builders) { throw 'Buildx builder leaked.' }
        $containers = & $nativeDocker ps -aq --filter "name=buildx_buildkit_$($tracked.Builder)0"
        if ($LASTEXITCODE -ne 0 -or $containers) { throw 'BuildKit container leaked.' }
    }
    if (Get-ChildItem -LiteralPath $env:RUNNER_TEMP -Force) { throw 'Action staging files leaked.' }
    if ($Scenario -ne 'Legacy') {
        $afterStatus = & git -C $ConsumerRoot status --porcelain --untracked-files=all
        if ($LASTEXITCODE -ne 0 -or $afterStatus) { throw 'The framework build changed the consumer checkout.' }
    }
    if (!$expectedFailure) {
        if ($VerifierPath) {
            & dotnet run --file $VerifierPath -- $parameters.OutputPath "$($parameters.OutputPath).sha256" $testVersion $consumerRevision
            if ($LASTEXITCODE -ne 0) { throw 'Codebelt OCI artifact verification failed.' }
        }
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value @("version=$testVersion", "revision=$consumerRevision") -Encoding utf8
    }
    Write-Host "Completed integration scenario $Scenario."
} finally {
    $env:RUNNER_TEMP = $previousRunnerTemp
    $env:GITHUB_OUTPUT = $previousGithubOutput
    if (Test-Path -LiteralPath $scratch -PathType Container) {
        $resolvedScratch = (Resolve-Path -LiteralPath $scratch).Path
        if ([IO.Path]::GetRelativePath([IO.Path]::GetTempPath(), $resolvedScratch) -match '^docfx-integration-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
        }
    }
}

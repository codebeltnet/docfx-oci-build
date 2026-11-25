[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$Revision,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$DocfxConfig,

    [string]$Dockerfile,

    [string]$DocfxVersion = '2.81.0',

    [Parameter(Mandatory = $true)]
    [string]$Platforms,

    [string]$FrameworkViews = 'false'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$frameworkViewsEnabled = $false
if (![bool]::TryParse($FrameworkViews, [ref] $frameworkViewsEnabled)) {
    throw "Set framework-views to 'true' or 'false'."
}
if (-not $env:GITHUB_OUTPUT) {
    throw 'GITHUB_OUTPUT is not available; this build script must run from a GitHub Action.'
}

$semverPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?$'
if ($Version -notmatch $semverPattern) {
    throw "Release version '$Version' is not a supported SemVer value."
}
if ($Revision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'The source revision must be a full 40-character commit SHA.'
}

$workspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$actualRevision = & git -C $workspaceRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Could not resolve the checked out source revision.'
}
$actualRevision = $actualRevision.Trim()
if ($actualRevision -ne $Revision) {
    throw "The workspace is at '$actualRevision', but the requested release revision is '$Revision'."
}

$docfxConfigPath = if ([System.IO.Path]::IsPathRooted($DocfxConfig)) {
    [System.IO.Path]::GetFullPath($DocfxConfig)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $DocfxConfig))
}
$bundledPackaging = $frameworkViewsEnabled -and !$Dockerfile
if (!$bundledPackaging -and !$Dockerfile) { $Dockerfile = '.docfx/Dockerfile.docfx' }

$dockerfilePath = if (!$bundledPackaging -and [System.IO.Path]::IsPathRooted($Dockerfile)) {
    [System.IO.Path]::GetFullPath($Dockerfile)
} elseif (!$bundledPackaging) {
    [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $Dockerfile))
}
if (-not (Test-Path -LiteralPath $docfxConfigPath -PathType Leaf)) {
    throw "DocFX configuration was not found: $docfxConfigPath"
}
if (!$bundledPackaging -and -not (Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
    throw "DocFX Dockerfile was not found: $dockerfilePath"
}

if ($frameworkViewsEnabled) {
    $configRelative = [IO.Path]::GetRelativePath($workspaceRoot, $docfxConfigPath).Replace('\', '/')
    if ([IO.Path]::IsPathRooted($configRelative) -or $configRelative -eq '..' -or $configRelative.StartsWith('../')) {
        throw 'Framework views require docfx-config inside the checked-out workspace.'
    }
}

$docfxRoot = Split-Path -Parent $docfxConfigPath
$docfxConfigName = Split-Path -Leaf $docfxConfigPath
$runnerTemp = if ($env:RUNNER_TEMP) {
    $env:RUNNER_TEMP
} else {
    [System.IO.Path]::GetTempPath()
}
$runnerTemp = [IO.Path]::GetFullPath($runnerTemp)

$outputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
if (Test-Path -LiteralPath $outputPath) {
    throw "OCI archive output already exists; choose a fresh output path: $outputPath"
}
$checksumPath = "$outputPath.sha256"
if (Test-Path -LiteralPath $checksumPath) {
    throw "OCI checksum output already exists; choose a fresh output path: $checksumPath"
}

$platformList = @($Platforms.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not ($platformList -contains 'linux/amd64') -or -not ($platformList -contains 'linux/arm64')) {
    throw 'The DocFX OCI artifact must include linux/amd64 and linux/arm64.'
}

$apiRoot = Join-Path $docfxRoot 'api'
$temporaryRoot = Join-Path $runnerTemp "docfx-oci-$([guid]::NewGuid().ToString('N'))"
$originalPath = $env:PATH
$builderName = Split-Path -Leaf $temporaryRoot
$builderCreated = $false
$exportStarted = $false
$exportCompleted = $false
$engineContainer = $null
$legacyMetadataStarted = $false
$locationPushed = $false
$contextPath = $docfxRoot
try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    if ($frameworkViewsEnabled) {
        $builderImage = 'codebeltnet/docfx:2.81.0-v1.1.0'
        Write-Host "Using DocFX framework-view builder image '$builderImage'."
        $containerCommand = @'
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
New-Item -ItemType Directory -Path /tmp/workspace | Out-Null
& /bin/cp -R /docfx-source/. /tmp/workspace
Set-Location /tmp/workspace

& /opt/docfx/framework-views/Build-DocfxFrameworkViews.ps1 -DocfxConfig $env:DOCFX_CONFIG -OutputRoot /tmp/docfx-output
exit $LASTEXITCODE
'@
        $engineContainer = & docker create --pull always --mount "type=bind,source=$workspaceRoot,target=/docfx-source,readonly" `
            --env "DOCFX_CONFIG=$configRelative" --entrypoint pwsh `
            -- $builderImage -NoProfile -NonInteractive -Command $containerCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create a container from DocFX builder image '$builderImage'. Confirm the upstream release has published this tag and the runner can pull it from Docker Hub."
        }
        & docker start --attach $engineContainer
        if ($LASTEXITCODE -ne 0) {
            throw "DocFX framework views failed in '$builderImage'. Use a builder image with the shared framework-view engine and the SDKs required by the consumer projects."
        }
        $contextPath = Join-Path $temporaryRoot 'image'
        New-Item -ItemType Directory -Path $contextPath | Out-Null
        $containerFiles = @('/tmp/docfx-output/site', '/tmp/docfx-output/nginx.conf')
        if ($bundledPackaging) {
            $containerFiles += '/opt/docfx/framework-views/framework-views.Dockerfile'
            $dockerfilePath = Join-Path $contextPath 'framework-views.Dockerfile'
        }
        foreach ($path in $containerFiles) {
            & docker cp "${engineContainer}:$path" $contextPath
            if ($LASTEXITCODE -ne 0) {
                throw "Could not retrieve '$path' from DocFX builder image '$builderImage'."
            }
        }
    } else {
        $toolPath = Join-Path $temporaryRoot 'tools'
        & dotnet tool install --tool-path $toolPath docfx --version $DocfxVersion
        if ($LASTEXITCODE -ne 0) {
            throw "Could not install DocFX CLI version $DocfxVersion."
        }
        $env:PATH = "$toolPath$([System.IO.Path]::PathSeparator)$originalPath"
        Push-Location $docfxRoot
        $locationPushed = $true
        Write-Host 'Generating legacy DocFX metadata.'
        $legacyMetadataStarted = $true
        & docfx metadata $docfxConfigName
        if ($LASTEXITCODE -ne 0) {
            throw "DocFX metadata generation failed with exit code $LASTEXITCODE."
        }
    }

    & docker buildx version
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Buildx is not available.'
    }
    & docker buildx create --name $builderName --driver docker-container
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create a Docker Buildx builder for the OCI export.'
    }
    $builderCreated = $true
    & docker buildx inspect --bootstrap $builderName
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not start the Docker Buildx builder.'
    }

    $outputSpec = "type=oci,dest=$outputPath,name=codebelt-docfx:$Version,oci-mediatypes=true"
    $buildArguments = @(
        'build'
        '--builder', $builderName
        '--progress', 'plain'
        '--platform', ($platformList -join ',')
        '--file', $dockerfilePath
        '--annotation', "index:org.opencontainers.image.version=$Version"
        '--annotation', "index:org.opencontainers.image.revision=$Revision"
        '--output', $outputSpec
        if ($frameworkViewsEnabled -and !$bundledPackaging) { '--build-context'; "docfx-source=$docfxRoot" }
        $contextPath
    )
    $exportStarted = $true
    & docker buildx @buildArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Buildx failed to create the DocFX OCI artifact with exit code $LASTEXITCODE. For registry authorization errors, authenticate with docker login before invoking the action (docker login dhi.io for the bundled Dockerfile). Buildx uses the caller's Docker configuration and credential helpers."
    }
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "Docker Buildx completed without creating the expected OCI archive: $outputPath"
    }
    $archiveHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumText = "$archiveHash  $([System.IO.Path]::GetFileName($outputPath))$([System.Environment]::NewLine)"
    [System.IO.File]::WriteAllText($checksumPath, $checksumText, [System.Text.UTF8Encoding]::new($false))
    $exportCompleted = $true
} finally {
    if ($exportStarted -and !$exportCompleted) {
        Remove-Item -LiteralPath $outputPath, $checksumPath -ErrorAction SilentlyContinue
    }
    if ($builderCreated) {
        & docker buildx rm $builderName | Out-Null
    }
    if ($engineContainer) {
        & docker rm -f $engineContainer | Out-Null
    }
    if ($locationPushed) {
        Pop-Location
    }
    $env:PATH = $originalPath

    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $temporary = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($runnerTemp), $temporary)
        if ($relative -match '^docfx-oci-[a-f0-9]{32}$') { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
    if ($legacyMetadataStarted -and (Test-Path -LiteralPath $apiRoot -PathType Container)) {
        Get-ChildItem -LiteralPath $apiRoot -Recurse -File -Force |
            Where-Object { $_.Extension -eq '.yml' -or $_.Name -eq '.manifest' } |
            Remove-Item -Force
    }
}

try {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value @("archive-path=$outputPath", "checksum-path=$checksumPath") -Encoding utf8
} catch {
    Remove-Item -LiteralPath $outputPath, $checksumPath -ErrorAction SilentlyContinue
    throw
}
Write-Host "Exported OCI archive $outputPath for $Version at $Revision."

#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$buildScript = Get-Content -LiteralPath "$PSScriptRoot/../scripts/build-docfx-oci.ps1" -Raw
if ($buildScript -notmatch '(?m)^\s+\$builderImage = ''(?<image>codebeltnet/docfx:(?<cli>\d+\.\d+\.\d+)-v(?<engine>\d+\.\d+\.\d+))''\s*$') {
    throw 'Expected an engine-qualified builder reference in the action script.'
}
$image = $Matches.image
$engineVersion = $Matches.engine
$cliVersion = $Matches.cli
$registryResult = & docker buildx imagetools inspect --raw $image 2>&1
if ($LASTEXITCODE -eq 0) {
    $index = ($registryResult -join "`n") | ConvertFrom-Json
    $platforms = @($index.manifests | Where-Object { $_.platform.os -eq 'linux' } | ForEach-Object { $_.platform.architecture })
    if ($index.mediaType -ne 'application/vnd.oci.image.index.v1+json' -or 'amd64' -notin $platforms -or 'arm64' -notin $platforms) {
        throw "Published builder '$image' must be an OCI index with linux/amd64 and linux/arm64."
    }
    & docker pull $image
    if ($LASTEXITCODE -ne 0) { throw "Could not pull '$image'." }
    $labels = & docker image inspect --format '{{json .Config.Labels}}' $image | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $labels.'net.codebelt.docfx.cli.version' -ne $cliVersion -or
        $labels.'net.codebelt.docfx.engine.version' -ne $engineVersion) {
        throw "Published builder '$image' does not match the requested CLI and engine versions."
    }
    Write-Host "Using published builder '$image'."
    return
}
if (($registryResult -join "`n") -notmatch '\bnot found\b') {
    throw "Registry inspection failed for '$image'. $registryResult"
}

# The source revision records the approved pre-publication fixture for this release.
$candidateRevision = 'aa0150169358bc9a5763cf644778f442e174e49e'
$workspace = Join-Path $env:RUNNER_TEMP "docfx-upstream-candidate-$([guid]::NewGuid().ToString('N'))"
$previousBuilder = $env:BUILDX_BUILDER
& git clone --quiet https://github.com/codebeltnet/docfx.git $workspace
if ($LASTEXITCODE -ne 0) { throw 'Could not clone the upstream builder source.' }
& git -C $workspace checkout --quiet --detach $candidateRevision
if ($LASTEXITCODE -ne 0) { throw 'Could not check out the approved upstream candidate revision.' }

$builder = "docfx-candidate-$([guid]::NewGuid().ToString('N'))"
& docker buildx create --name $builder --driver docker-container
if ($LASTEXITCODE -ne 0) { throw 'Could not create the candidate Buildx builder.' }
try {
    $env:BUILDX_BUILDER = $builder
    $candidateBuild = @{
        Tag = 'docfx-oci-pr'
        DocfxVersion = $cliVersion
        EngineVersion = $engineVersion
        BuildOnly = $true
        Platform = 'linux/amd64'
        RequireNative = $true
        ArchivePath = "$workspace/candidate.oci.tar"
        MetadataFile = "$workspace/candidate.json"
        PassThru = $true
    }
    Push-Location $workspace
    try {
        $record = & ./BuildAndPushDocfxImage.ps1 @candidateBuild | Select-Object -Last 1
    } finally {
        Pop-Location
    }
    if (!$record.NativeVerified -or $record.SourceCommit -cne $candidateRevision) {
        throw 'The upstream tools did not verify the expected candidate.'
    }
    $candidate = "codebeltnet/docfx-oci-pr:${cliVersion}-v$engineVersion"
    if ($candidate -notin $record.EngineQualifiedTags) { throw "Expected the verified local image '$candidate'." }
    Write-Host "Docker Hub has no '$image'. Using verified local candidate '$candidate' for integration."
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "local-image=$candidate" -Encoding utf8
} finally {
    $env:BUILDX_BUILDER = $previousBuilder
    & docker buildx rm $builder
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove the candidate Buildx builder.' }
}

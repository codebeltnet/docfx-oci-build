#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$buildScript = Get-Content -LiteralPath "$PSScriptRoot/../scripts/build-docfx-oci.ps1" -Raw
if ($buildScript -notmatch '(?m)^\s+\$builderImage = ''(?<image>codebeltnet/docfx:(?<cli>\d+\.\d+\.\d+)-v(?<engine>\d+\.\d+\.\d+))''\s*$') {
    throw 'Expected an engine-qualified builder reference in the action script.'
}
$image = $Matches.image
$cliVersion = $Matches.cli
$engineVersion = $Matches.engine

$index = & docker buildx imagetools inspect $image --format '{{json .Manifest}}' | ConvertFrom-Json
$platforms = @($index.manifests | Where-Object { $_.platform.os -eq 'linux' } | ForEach-Object { $_.platform.architecture })
if ($index.mediaType -ne 'application/vnd.oci.image.index.v1+json' -or 'amd64' -notin $platforms -or 'arm64' -notin $platforms) {
    throw "Published builder '$image' must be an OCI index with linux/amd64 and linux/arm64."
}

$configs = & docker buildx imagetools inspect $image --format '{{json .Image}}' | ConvertFrom-Json -AsHashtable
foreach ($platform in 'linux/amd64', 'linux/arm64') {
    $labels = $configs[$platform].config.Labels
    if ($labels.'net.codebelt.docfx.cli.version' -cne $cliVersion -or $labels.'net.codebelt.docfx.engine.version' -cne $engineVersion) {
        throw "Published builder '$image' on $platform does not match the requested CLI and engine versions."
    }
}
Write-Host "Verified published builder '$image' ($($index.digest)) for linux/amd64 and linux/arm64."

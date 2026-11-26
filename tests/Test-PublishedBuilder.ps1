#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$buildScript = Get-Content -LiteralPath "$PSScriptRoot/../scripts/build-docfx-oci.ps1" -Raw
if ($buildScript -cnotmatch '(?m)^\s+\$builderImage = ''(?<image>codebeltnet/docfx:2)''\s*$') {
    throw 'Expected the stable Codebelt builder tag in the action script.'
}
$image = $Matches.image

$index = & docker buildx imagetools inspect $image --format '{{json .Manifest}}' | ConvertFrom-Json
$platforms = @($index.manifests | Where-Object { $_.mediaType -eq 'application/vnd.oci.image.manifest.v1+json' -and $_.platform.os -eq 'linux' } | ForEach-Object { $_.platform.architecture })
if ($index.mediaType -ne 'application/vnd.oci.image.index.v1+json' -or 'amd64' -notin $platforms -or 'arm64' -notin $platforms) {
    throw "Published builder '$image' must be an OCI index with linux/amd64 and linux/arm64."
}

Write-Host "Verified published builder '$image' ($($index.digest)) for linux/amd64 and linux/arm64."

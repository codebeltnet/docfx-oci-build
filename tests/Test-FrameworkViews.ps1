#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string] $SharedTemplatePath)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "docfx-framework-test-$([guid]::NewGuid().ToString('N'))"
$docs = "$root/docs"
$config = "$docs/docfx.json"
$build = "$PSScriptRoot/../scripts/Build-DocfxFrameworkViews.ps1"
$arguments = @{
    DocfxConfig = $config
    ApiPath = 'reference'
    DefaultFramework = 'net11.0'
    Framework = @('net11.0', 'net10.0')
    SharedTemplatePath = $SharedTemplatePath
    MetadataCache = "$root/cache"
    MetadataCacheKey = 'synthetic-regression'
}

New-Item -ItemType Directory "$root/src/Runtime", "$root/src/Legacy", "$root/src/Excluded", $docs | Out-Null
Set-Content "$root/src/Runtime/Runtime.csproj" '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFrameworks>net11.0;net10.0</TargetFrameworks></PropertyGroup></Project>'
Set-Content "$root/src/Runtime/Runtime.cs" @'
namespace FrameworkFixture;
public class Common { }
#if NET11_0
public class Modern { }
#endif
'@
Set-Content "$root/src/Legacy/Legacy.csproj" '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>'
Set-Content "$root/src/Legacy/Legacy.cs" 'namespace FrameworkFixture.Compatibility; public class Legacy { }'
Set-Content "$root/src/Excluded/Excluded.csproj" 'This project must be excluded by the DocFX mapping.'
Set-Content "$docs/index.md" '# Shared concept'
@{
    metadata = @(
        @{ src = @(@{ src = '../src'; files = @('**.csproj'); exclude = @('Excluded/**', 'Legacy/**') }); dest = 'reference/runtime' }
        @{ src = @(@{ src = '../src'; files = @('Legacy/Legacy.csproj') }); dest = 'reference/legacy' }
    )
    build = @{
        content = @(@{ files = @('reference/**/*.yml', 'index.md') })
        globalMetadata = @{ _enableSearch = $true }
        template = @('default', 'modern', 'templates/ms-style')
        dest = 'rendered'
    }
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config

& $build @arguments -OutputRoot "$root/fresh"
$site = "$root/fresh/site"
$manifest = Get-Content "$site/framework-views.json" -Raw | ConvertFrom-Json
if (($manifest.viewOrder -join ',') -cne 'net-11.0,net-10.0') { throw 'Configured order was not preserved.' }
foreach ($path in 'index.html', 'reference/runtime/FrameworkFixture.Modern.html', '_frameworks/net10/reference/legacy/FrameworkFixture.Compatibility.Legacy.html', '_frameworks/net10/reference/runtime/FrameworkFixture.Common.html', '_frameworks/net10/index.json') {
    if (!(Test-Path -LiteralPath "$site/$path" -PathType Leaf)) { throw "Missing '$path'." }
}
foreach ($path in 'reference/legacy/FrameworkFixture.Compatibility.Legacy.html', '_frameworks/net10/reference/runtime/FrameworkFixture.Modern.html') {
    if (Test-Path -LiteralPath "$site/$path") { throw "Unexpected '$path'." }
}

& $build @arguments -OutputRoot "$root/cached"
if (Get-ChildItem -LiteralPath "$root/cached" -Filter metadata.log -Recurse) { throw 'The second build did not reuse all metadata.' }
foreach ($path in 'xrefmap.yml', '_frameworks/net10/xrefmap.yml', 'framework-views.json') {
    if ((Get-FileHash -LiteralPath "$site/$path").Hash -cne (Get-FileHash -LiteralPath "$root/cached/site/$path").Hash) {
        throw "Cached and fresh output differ for '$path'."
    }
}

Set-Content -LiteralPath (Get-ChildItem -LiteralPath "$root/cache" -Filter 'net11.0.zip' -Recurse).FullName 'invalid cache'
& $build @arguments -OutputRoot "$root/recovered"
if (!(Test-Path -LiteralPath "$root/recovered/net11/metadata.log") -or (Test-Path -LiteralPath "$root/recovered/net10/metadata.log")) {
    throw 'The damaged cache did not trigger an isolated metadata rebuild.'
}
Write-Host "Framework build, exclusions, independent group output and cache recovery passed in $root."

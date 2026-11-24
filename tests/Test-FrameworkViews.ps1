#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SharedTemplatePath,
    [switch] $ProjectSdk8,
    [switch] $TestRouting
)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "docfx-framework-test-$([guid]::NewGuid().ToString('N'))"
$docs = "$root/docs"
$config = "$docs/docfx.json"
$build = "$PSScriptRoot/../scripts/Build-DocfxFrameworkViews.ps1"
$defaultTfm, $otherTfm = if ($ProjectSdk8) { 'net8.0', 'netstandard2.1' } else { 'net11.0', 'net10.0' }
$defaultView, $otherView = $defaultTfm, $otherTfm -creplace '^(net(?:standard)?)(\d)', '$1-$2'
$defaultDirectory = $defaultTfm -replace '\.0$', ''
$otherDirectory = $otherTfm -replace '\.0$', ''
$settings = "$docs/framework-views.json"
$arguments = @{
    DocfxConfig = $config
    SettingsPath = $settings
    MetadataCache = "$root/cache"
    MetadataCacheKey = 'synthetic-regression'
}

New-Item -ItemType Directory "$root/src/Runtime", "$root/src/Legacy", "$root/src/Excluded", $docs | Out-Null
if ($ProjectSdk8) {
    Set-Content "$root/global.json" '{"sdk":{"version":"8.0.100","rollForward":"latestFeature"}}'
}
$constant = $defaultTfm.ToUpperInvariant().Replace('.', '_')
Set-Content "$root/src/Runtime/Runtime.csproj" "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><TargetFrameworks>$defaultTfm;$otherTfm</TargetFrameworks><LangVersion>latest</LangVersion></PropertyGroup></Project>"
Set-Content "$root/src/Runtime/Runtime.cs" @"
namespace FrameworkFixture;
public class Common { }
#if $constant
public class Modern { }
#endif
"@
Set-Content "$root/src/Legacy/Legacy.csproj" "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><TargetFramework>$otherTfm</TargetFramework><LangVersion>latest</LangVersion></PropertyGroup></Project>"
Set-Content "$root/src/Legacy/Legacy.cs" 'namespace FrameworkFixture.Compatibility; public class Legacy { }'
Set-Content "$root/src/Excluded/Excluded.csproj" 'This project must be excluded by the DocFX mapping.'
Set-Content "$docs/index.md" '# Shared concept'
@{
    metadata = @(
        @{ src = @(@{ src = '../src'; files = @('**.csproj'); exclude = @('Excluded/**', 'Legacy/**') }); dest = 'reference/runtime' }
        @{ src = @{ src = '../src'; files = 'Legacy/Legacy.csproj' }; dest = 'reference/legacy' }
    )
    build = @{
        content = @(@{ files = @('reference/**/*.yml', 'index.md') })
        globalMetadata = @{ _enableSearch = $true }
        template = @('default', 'modern', 'templates/ms-style')
        dest = 'rendered'
    }
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config
@{ apiPath = 'reference'; defaultFramework = $defaultTfm; templatePath = (Resolve-Path -LiteralPath $SharedTemplatePath).Path } |
    ConvertTo-Json | Set-Content -LiteralPath $settings

& $build @arguments -OutputRoot "$root/fresh"
$site = "$root/fresh/site"
$manifest = Get-Content "$site/framework-views.json" -Raw | ConvertFrom-Json
if (($manifest.viewOrder -join ',') -cne "$defaultView,$otherView") { throw 'Discovered order was not preserved.' }
foreach ($path in 'index.html', 'reference/runtime/FrameworkFixture.Modern.html', "_frameworks/$otherDirectory/reference/legacy/FrameworkFixture.Compatibility.Legacy.html", "_frameworks/$otherDirectory/reference/runtime/FrameworkFixture.Common.html", "_frameworks/$otherDirectory/index.json") {
    if (!(Test-Path -LiteralPath "$site/$path" -PathType Leaf)) { throw "Missing '$path'." }
}
foreach ($path in 'reference/legacy/FrameworkFixture.Compatibility.Legacy.html', "_frameworks/$otherDirectory/reference/runtime/FrameworkFixture.Modern.html") {
    if (Test-Path -LiteralPath "$site/$path") { throw "Unexpected '$path'." }
}

& $build @arguments -OutputRoot "$root/cached"
if (Get-ChildItem -LiteralPath "$root/cached" -Filter metadata.log -Recurse) { throw 'The second build did not reuse all metadata.' }
foreach ($path in 'xrefmap.yml', "_frameworks/$otherDirectory/xrefmap.yml", 'framework-views.json') {
    if ((Get-FileHash -LiteralPath "$site/$path").Hash -cne (Get-FileHash -LiteralPath "$root/cached/site/$path").Hash) {
        throw "Cached and fresh output differ for '$path'."
    }
}

Set-Content -LiteralPath (Get-ChildItem -LiteralPath "$root/cache" -Filter "$defaultTfm.zip" -Recurse).FullName 'invalid cache'
& $build @arguments -OutputRoot "$root/recovered"
if (!(Test-Path -LiteralPath "$root/recovered/$defaultDirectory/metadata.log") -or (Test-Path -LiteralPath "$root/recovered/$otherDirectory/metadata.log")) {
    throw 'The damaged cache did not trigger an isolated metadata rebuild.'
}

if ($TestRouting) {
    Set-Content "$site/reference/runtime/index.html" 'default API index'
    Set-Content "$site/_frameworks/$otherDirectory/reference/runtime/index.html" 'other API index'
    Set-Content "$site/_frameworks/$otherDirectory/reference/legacy/index.html" 'other legacy index'
    $mounts = @('--mount', "type=bind,source=$site,target=/usr/share/nginx/html,readonly",
        '--mount', "type=bind,source=$root/fresh/nginx.conf,target=/etc/nginx/conf.d/default.conf,readonly")
    & docker run --rm @mounts dhi.io/nginx:1.31-alpine -t
    if ($LASTEXITCODE -ne 0) { throw 'Generated NGINX configuration is invalid.' }
    $container = & docker run --rm -d -p 127.0.0.1::8080 @mounts dhi.io/nginx:1.31-alpine
    if ($LASTEXITCODE -ne 0) { throw 'Could not start NGINX for routing checks.' }
    try {
        $endpoint = (& docker port $container 8080/tcp).Trim()
        if ($LASTEXITCODE -ne 0 -or $endpoint -notmatch '^127\.0\.0\.1:\d+$') { throw 'Could not resolve the test origin.' }
        $responses = @(
            @{ path = '/reference/runtime/'; status = 200; body = 'default API index' }
            @{ path = "/reference/runtime/?view=$defaultView"; status = 200; body = 'default API index' }
            @{ path = "/reference/runtime/?view=$otherView"; status = 200; body = 'other API index' }
            @{ path = "/reference/runtime/index.html?view=$otherView"; status = 200; body = 'other API index' }
            @{ path = "/reference/runtime/FrameworkFixture.Common.html?view=$otherView"; status = 200; body = 'FrameworkFixture' }
            @{ path = '/reference/runtime/?view=unknown'; status = 400; body = 'Unknown documentation view.' }
            @{ path = "/reference/runtime/FrameworkFixture.Modern.html?view=$otherView"; status = 404 }
            @{ path = '/reference/legacy/'; status = 404 }
            @{ path = "/reference/legacy/?view=$otherView"; status = 200; body = 'other legacy index' }
        )
        foreach ($expected in $responses) {
            $result = Invoke-WebRequest "http://$endpoint$($expected.path)" -SkipHttpErrorCheck -MaximumRedirection 0
            $body = if ($result.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($result.Content) } else { $result.Content }
            if ($result.StatusCode -ne $expected.status -or ($expected.body -and !$body.Contains($expected.body)) -or
                $result.Headers['Cache-Control'] -notlike '*no-store*' -or $result.Headers['ETag']) {
                throw "Unexpected routing or caching for '$($expected.path)' (HTTP $($result.StatusCode))."
            }
        }
    } finally {
        & docker stop $container | Out-Null
    }
    Write-Host 'Generated NGINX file and directory routing passed.'
}
Write-Host "Framework build, exclusions, independent group output and cache recovery passed in $root."

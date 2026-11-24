#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Explicit')]
param(
    [Parameter(Mandatory)][string] $DocfxConfig,
    [Parameter(Mandatory)][string] $OutputRoot,
    [Parameter(Mandatory, ParameterSetName = 'Settings')][string] $SettingsPath,
    [Parameter(Mandatory, ParameterSetName = 'Explicit')][string] $DefaultFramework,
    [Parameter(Mandatory, ParameterSetName = 'Explicit')][string] $ApiPath,
    [Parameter(ParameterSetName = 'Explicit')][string[]] $Framework,
    [Parameter(ParameterSetName = 'Explicit')][string] $SharedTemplatePath,
    [Parameter(ParameterSetName = 'Explicit')][string] $BuilderImage,
    [Parameter(ParameterSetName = 'Explicit')][switch] $BuildInContainer,
    [Parameter(ParameterSetName = 'Explicit')][switch] $AlignAssemblyVersion,
    [switch] $NoRestore,
    [switch] $ForceMetadata,
    [string] $MetadataCache,
    [string] $MetadataCacheKey
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Step([string] $Log, [string] $Command, [string[]] $Arguments) {
    & $Command @Arguments *> $Log
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $Log -Tail 25 | Write-Host
        throw "$Command exited with $LASTEXITCODE. See $Log"
    }
}

function Write-Json([string] $Path, $Value) {
    ConvertTo-Json -InputObject $Value -Depth 100 | Set-Content -LiteralPath $Path
}

function Read-Json([string] $Path) {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
}

function Get-MetadataFingerprint([string[]] $Directories) {
    $entries = foreach ($directory in $Directories) {
        if (!(Test-Path -LiteralPath "$directory/.manifest" -PathType Leaf)) { return }
        foreach ($file in Get-ChildItem -LiteralPath $directory -Recurse -File -Force | Where-Object { $_.Extension -eq '.yml' -or $_.Name -eq '.manifest' } | Sort-Object FullName -CaseSensitive) {
            "$([IO.Path]::GetRelativePath($directory, $file.FullName).Replace('\', '/'))=$((Get-FileHash -LiteralPath $file.FullName).Hash)"
        }
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))))
}

$configPath = (Resolve-Path -LiteralPath $DocfxConfig).Path
$source = Split-Path -Parent $configPath
if ($SettingsPath) {
    $SettingsPath = (Resolve-Path -LiteralPath $SettingsPath).Path
    $settings = Read-Json $SettingsPath
    $ApiPath = $settings.apiPath
    $DefaultFramework = $settings.defaultFramework
    $Framework = $settings.frameworks
    $AlignAssemblyVersion = [bool]$settings.alignAssemblyVersion
    $BuilderImage = $settings.builderImage
    $BuildInContainer = [bool]$BuilderImage
    if ($settings.templatePath) {
        $SharedTemplatePath = [IO.Path]::GetFullPath($settings.templatePath, (Split-Path -Parent $SettingsPath))
    }
}
if (!$DefaultFramework) { throw 'Specify the default framework in the settings or with -DefaultFramework.' }
if ((!$SharedTemplatePath -or $BuildInContainer) -and !$BuilderImage) {
    throw 'Specify a framework-aware template path for native rendering or an explicit DocFX builder image.'
}
$work = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$relativeWork = [IO.Path]::GetRelativePath($source, $work)
if ($relativeWork -eq '.' -or ($relativeWork -ne '..' -and !$relativeWork.StartsWith("..$([IO.Path]::DirectorySeparatorChar)") -and ![IO.Path]::IsPathRooted($relativeWork))) {
    throw 'Place the framework output outside the DocFX input directory.'
}
if ((Test-Path -LiteralPath $work) -and @(Get-ChildItem -LiteralPath $work -Force).Count) {
    throw "Framework output directory must be empty: $work"
}
if ($ApiPath -cnotmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$') { throw "Invalid API path: $ApiPath" }
if ($MetadataCache -and !$MetadataCacheKey) { throw 'A metadata cache requires a metadata input fingerprint.' }
if ($MetadataCache) { $MetadataCache = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MetadataCache) }
if ($SharedTemplatePath) { $SharedTemplatePath = (Resolve-Path -LiteralPath $SharedTemplatePath).Path }
New-Item -ItemType Directory -Path $work -Force | Out-Null
Write-Host "Artifacts: $work"

$config = Read-Json $configPath
$buildDestination = if ($config.build.dest) { $config.build.dest } elseif ($config.build.output) { $config.build.output } else { '_site' }
if ($buildDestination -cnotmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or $buildDestination -match '(^|/)\.{1,2}(/|$)') {
    throw 'Framework views require a relative DocFX site destination.'
}
if (!$config.metadata.Count) { throw 'Configure at least one project metadata group.' }
foreach ($group in $config.metadata) {
    if ($group.dest -cnotmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$' -or
        ($group.dest -cne $ApiPath -and !$group.dest.StartsWith("$ApiPath/", [StringComparison]::Ordinal))) {
        throw "Metadata destination '$($group.dest)' must be at or below '$ApiPath'."
    }
}

$supportedDocfx = '2.81.0'
$docfx = (Get-Command docfx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (!$docfx) { throw "Install DocFX $supportedDocfx as a .NET tool and add its executable to PATH." }
$version = & $docfx --version
if ($LASTEXITCODE -ne 0 -or !$version) { throw 'Could not determine the installed DocFX version.' }
$version = $version.Trim()
if (($version -split '\+', 2)[0] -cne $supportedDocfx) {
    throw "Framework views use DocFX $supportedDocfx for project discovery. Install that CLI version (found '$version')."
}
$store = Join-Path (Split-Path -Parent $docfx) ".store/docfx/$supportedDocfx/docfx/$supportedDocfx/tools"
if (!(Test-Path -LiteralPath $store -PathType Container)) {
    throw "DocFX $supportedDocfx mapping libraries were not found in '$store'. Install DocFX as a global or --tool-path .NET tool."
}
$tools = Get-ChildItem -LiteralPath $store -Filter Docfx.Glob.dll -File -Recurse | Sort-Object {
    [version]($_.Directory.Parent.Name.Substring(3))
} | Select-Object -First 1
if (!$tools) { throw "Install DocFX as a .NET tool so its mapping library can be found in $store." }
$resolver = "$PSScriptRoot/Resolve-DocfxProjects.cs"
$resolvedPath = "$work/projects.json"
$resolverDirectory = "$work/resolver"
New-Item -ItemType Directory -Path $resolverDirectory | Out-Null
# The file-based app needs .NET 10 or later even if the project pins an older SDK.
Write-Json "$resolverDirectory/global.json" @{ sdk = @{ version = '10.0.100'; rollForward = 'latestMajor'; allowPrerelease = $true } }
Push-Location $resolverDirectory
try {
    Invoke-Step "$work/resolver-sdk.log" dotnet @('--version')
    $resolverSdk = (Get-Content -LiteralPath "$work/resolver-sdk.log" -Raw).Trim()
    Invoke-Step "$work/discovery.log" dotnet @('run', '--file', $resolver, '--', $tools.DirectoryName, $configPath, $resolvedPath)
} finally {
    Pop-Location
}
Push-Location $source
try {
    $mappings = Read-Json $resolvedPath
    $projects = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $groups = for ($groupIndex = 0; $groupIndex -lt $config.metadata.Count; $groupIndex++) {
        $group = $config.metadata[$groupIndex]
        if (!$group.properties) { $group.properties = @{} }
        $groupProjects = @(
            foreach ($mapping in $mappings[$groupIndex]) {
                $root = if ($mapping.source) { [IO.Path]::GetFullPath($mapping.source, $source) } else { $source }
                foreach ($file in $mapping.files) {
                    if ([IO.Path]::GetExtension($file) -notin '.csproj', '.fsproj', '.vbproj') {
                        throw "Framework views require project inputs. Found '$file' in '$($group.dest)'."
                    }
                    $path = [IO.Path]::GetFullPath($file)
                    $relative = [IO.Path]::GetRelativePath($root, $path).Replace('\', '/')
                    $properties = @($group.properties.GetEnumerator() | ForEach-Object { "-p:$($_.Key)=$($_.Value)" })
                    if ($group.properties.Contains('TargetFramework')) { throw "Remove TargetFramework from the properties for '$($group.dest)'." }
                    if (!$projects.ContainsKey($path)) {
                        $evaluation = & dotnet msbuild $path -nologo -getProperty:TargetFrameworks,TargetFramework @properties
                        if ($LASTEXITCODE -ne 0) { throw "MSBuild evaluation failed for $path." }
                        # SDK first-run messages and project warnings can precede the property JSON.
                        $evaluationText = $evaluation -join "`n"
                        $propertyJson = [regex]::Match($evaluationText, '(?ms)^\{\n.*?^\}$')
                        if (!$propertyJson.Success) { throw "MSBuild did not return target framework properties for ${path}: $evaluationText" }
                        $evaluated = ($propertyJson.Value | ConvertFrom-Json).Properties
                        $targets = @("$($evaluated.TargetFrameworks);$($evaluated.TargetFramework)" -split ';' | Where-Object { $_ } | Select-Object -Unique)
                        if (!$targets.Count) { throw "No target frameworks for $path." }
                        $projects[$path] = @{ targets = $targets; properties = $properties; id = $projects.Count }
                        Write-Host "$relative declares $($targets -join ', ')"
                    } elseif (($projects[$path].properties -join "`n") -cne ($properties -join "`n")) {
                        throw "Use the same metadata properties for each occurrence of '$path'."
                    }
                    @{ path = $path; root = $root; relative = $relative }
                }
            }
        )
        if (!$groupProjects.Count) { throw "No project matched metadata destination '$($group.dest)'." }
        @{ config = $group; projects = $groupProjects }
    }

    $matrix = @($projects.Values | ForEach-Object { $_.targets } | Sort-Object -Unique -CaseSensitive)
    if (!$Framework) {
        # Prefer the configured default, then follow the target order declared by the projects.
        $Framework = @($DefaultFramework; foreach ($group in $groups) {
            foreach ($project in $group.projects) { $projects[$project.path].targets }
        }) | Select-Object -Unique
    }
    if ($DefaultFramework -cnotin $Framework -or @($Framework | Select-Object -Unique).Count -ne $Framework.Count) {
        throw 'The ordered framework list must include the default and contain unique targets.'
    }
    $views = [ordered]@{}
    foreach ($tfm in $Framework) {
        if ($tfm -cnotin $matrix) { throw "Undeclared framework: $tfm" }
        if ($tfm -cnotmatch '^(net|netstandard|netcoreapp)(\d+)\.(\d+)$' -and $tfm -cnotmatch '^(net)([1-4])([0-9]+)$') {
            throw "No public view mapping for $tfm."
        }
        $view = if ($tfm.Contains('.')) { "$($Matches[1])-$($Matches[2]).$($Matches[3])" } else { $tfm }
        $directory = if ($tfm -cmatch '^net([5-9]|[1-9]\d+)\.0$') { "net$($Matches[1])" } else { $tfm }
        $views[$view] = [ordered]@{ tfm = $tfm; directory = $directory; xref = "/xrefmap.yml?view=$view"; projects = @() }
    }

    $shared = "$work/shared"
    New-Item -ItemType Directory -Path $shared | Out-Null
    if ($SharedTemplatePath) {
        Copy-Item -LiteralPath $SharedTemplatePath -Destination "$shared/ms-style" -Recurse
    } else {
        Invoke-Step "$work/templates.log" docker @('run', '--rm', '--mount', "type=bind,source=$shared,target=/stage",
            $BuilderImage, 'cp', '-R', '/opt/docfx/templates/ms-style', '/stage/ms-style')
    }
    if (!(Test-Path -LiteralPath "$shared/ms-style/public/framework-view.js" -PathType Leaf)) {
        throw 'Use an ms-style template with framework view support.'
    }

    $sdk = (& dotnet --version).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not determine the selected .NET SDK.' }
    if ($MetadataCache) {
        $cacheVersion = @(Get-FileHash -LiteralPath $PSCommandPath, $resolver, $configPath, $resolvedPath | ForEach-Object Hash) -join ':'
        $cacheInputs = "$version/$sdk/$resolverSdk/$cacheVersion/$MetadataCacheKey/$DefaultFramework/$($Framework -join ',')/$AlignAssemblyVersion"
        $cacheId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($cacheInputs)))
        $cacheRoot = "$MetadataCache/$cacheId"
        New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    }
    $restored = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($view in $views.Keys) {
        $entry = $views[$view]
        $tfm = $entry.tfm
        $mixedTargets = $AlignAssemblyVersion -and @($projects.Values | Where-Object { $tfm -cnotin $_.targets }).Count -gt 0
        $stage = "$work/$($entry.directory)"
        New-Item -ItemType Directory -Path $stage | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
            if ($item.Name -in @('.git', 'bin', 'obj', 'wwwroot', '_site', ($buildDestination -split '/')[0])) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination $stage -Recurse -Force
        }
        $metadata = @(
            foreach ($group in $groups) {
                $original = $group.config
                $destination = "$stage/$($original.dest)"
                if (Test-Path -LiteralPath $destination -PathType Container) {
                    Get-ChildItem -LiteralPath $destination -Recurse -File -Force | Where-Object {
                        $_.Name -eq '.manifest' -or ($_.Extension -eq '.yml' -and (Get-Content -LiteralPath $_.FullName -TotalCount 1) -match '^### YamlMime:(ManagedReference|ApiPage|TableOfContent)')
                    } | Remove-Item -Force
                    # Native metadata TOCs have no YAML MIME marker.
                    $originManifest = Join-Path $source "$($original.dest)/.manifest"
                    if (Test-Path -LiteralPath $originManifest -PathType Leaf) {
                        $generatedToc = Join-Path $destination 'toc.yml'
                        if (Test-Path -LiteralPath $generatedToc -PathType Leaf) { Remove-Item -LiteralPath $generatedToc }
                    }
                }
                $selected = @($group.projects | Where-Object { $tfm -cin $projects[$_.path].targets })
                if (!$selected.Count) { continue }
                $entry.projects += @($selected.relative)
                $metadataGroup = ConvertTo-Json $original -Depth 100 | ConvertFrom-Json -AsHashtable
                $metadataGroup.src = @($selected | Group-Object root | ForEach-Object { @{ src = $_.Name; files = @($_.Group.relative) } })
                $metadataGroup.properties.TargetFramework = $tfm
                $metadataGroup
            }
        )
        $metadataPath = "$stage/framework-metadata.json"
        Write-Json $metadataPath @{ metadata = $metadata }
        $directories = @($metadata | ForEach-Object { "$stage/$($_.dest)" })
        $cacheFile = if ($MetadataCache) { "$cacheRoot/$tfm.zip" }
        $cache = "$work/cache-$tfm"
        $cached = $false
        if (!$ForceMetadata -and $cacheFile -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
            try {
                [IO.Compression.ZipFile]::ExtractToDirectory($cacheFile, $cache)
                $cachedFingerprint = Get-MetadataFingerprint @($metadata | ForEach-Object { "$cache/$($_.dest)" })
                $cached = $cachedFingerprint -and $cachedFingerprint -ceq (Get-Content -LiteralPath "$cache/fingerprint" -Raw).Trim()
            } catch {
                Write-Warning "Metadata cache for $view could not be read: $($_.Exception.Message)"
            }
        }
        if ($cached) {
            foreach ($group in $metadata) {
                $destination = "$stage/$($group.dest)"
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                Get-ChildItem -LiteralPath "$cache/$($group.dest)" -Force | Copy-Item -Destination $destination -Recurse -Force
            }
            Write-Host "Reused metadata for $view."
        } else {
            foreach ($group in $metadata) {
                $selected = @($group.src | ForEach-Object { $mapping = $_; $_.files | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $mapping.src $_)) } })
                $versions = foreach ($project in $selected) {
                    $info = $projects[$project]
                    if (!$NoRestore -and $restored.Add($project)) {
                        Invoke-Step "$work/restore-$($info.id).log" dotnet (@('restore', $project) + $info.properties)
                    }
                    if (!$mixedTargets) { continue }
                    $arguments = @('build', $project, '-c', 'Release', '-f', $tfm, '--no-restore') + $info.properties
                    Invoke-Step "$stage/build-$($info.id).log" dotnet $arguments
                    $assemblyVersion = & dotnet msbuild $project -nologo -p:Configuration=Release "-p:TargetFramework=$tfm" -t:GetAssemblyVersion -getProperty:AssemblyVersion @($info.properties)
                    if ($LASTEXITCODE -ne 0 -or $assemblyVersion -notmatch '^\d+(\.\d+){3}$') { throw "Cannot evaluate assembly version for $project." }
                    $assemblyVersion
                }
                if ($versions) {
                    $distinct = @($versions | Select-Object -Unique)
                    if ($distinct.Count -ne 1) { throw "The mixed-target workaround requires a common assembly version for '$($group.dest)'." }
                    $group.properties.AssemblyVersion = $distinct[0]
                }
            }
            Write-Json $metadataPath @{ metadata = $metadata }
            Invoke-Step "$stage/metadata.log" $docfx @('metadata', $metadataPath, '--noRestore')
            $fingerprint = Get-MetadataFingerprint $directories
            if (!$fingerprint) { throw "Incomplete metadata for $view." }
            if ($cacheFile) {
                $temporary = "$work/generated-$tfm"
                foreach ($group in $metadata) {
                    $destination = "$temporary/$($group.dest)"
                    New-Item -ItemType Directory -Path $destination -Force | Out-Null
                    Get-ChildItem -LiteralPath "$stage/$($group.dest)" -Recurse -File -Force | Where-Object { $_.Extension -eq '.yml' -or $_.Name -eq '.manifest' } | ForEach-Object {
                        $output = Join-Path $destination ([IO.Path]::GetRelativePath("$stage/$($group.dest)", $_.FullName))
                        New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
                        Copy-Item -LiteralPath $_.FullName -Destination $output
                    }
                }
                Set-Content -LiteralPath "$temporary/fingerprint" -Value $fingerprint
                $archive = "$cacheFile-$([guid]::NewGuid().ToString('N')).tmp"
                try {
                    [IO.Compression.ZipFile]::CreateFromDirectory($temporary, $archive)
                    [IO.File]::Move($archive, $cacheFile, $true)
                } finally {
                    [IO.File]::Delete($archive)
                }
            }
        }

        $build = ConvertTo-Json $config.build -Depth 100 | ConvertFrom-Json -AsHashtable
        if (!$build.globalMetadata) { $build.globalMetadata = @{} }
        $build.globalMetadata._frameworkApi = $ApiPath
        $build.globalMetadata._frameworkDirectory = $entry.directory
        $build.dest = $buildDestination
        $build.Remove('output')
        $templateFound = $false
        $build.template = @($build.template | ForEach-Object {
            if ((Split-Path -Leaf $_) -ceq 'ms-style') { $templateFound = $true; 'framework-template/ms-style' } else { $_ }
        })
        if (!$templateFound) { throw 'Configure ms-style in the DocFX build template list.' }
        New-Item -ItemType Directory -Path "$stage/framework-template" | Out-Null
        Copy-Item -LiteralPath "$shared/ms-style" -Destination "$stage/framework-template/ms-style" -Recurse
        Write-Json "$stage/framework-build.json" @{ build = $build }
        if ($BuildInContainer) {
            Invoke-Step "$stage/build.log" docker @('run', '--rm', '--mount', "type=bind,source=$stage,target=/stage",
                '-w', '/stage', $BuilderImage, 'docfx', 'build', 'framework-build.json', '--warningsAsErrors')
        } else {
            Invoke-Step "$stage/build.log" $docfx @('build', "$stage/framework-build.json", '--warningsAsErrors')
        }
        $count = 0
        foreach ($directory in $directories) { $count += (Read-Json "$directory/.manifest").Count }
        if (!$count) { throw "Empty DocFX metadata for $view." }
        Write-Host "$view rendered $count metadata UIDs"
    }
} finally {
    Pop-Location
}

$defaultView = @($views.Keys.Where({ $views[$_].tfm -ceq $DefaultFramework }))[0]
$site = "$work/site"
Copy-Item -LiteralPath "$work/$($views[$defaultView].directory)/$buildDestination" -Destination $site -Recurse
$routes = foreach ($view in $views.Keys) {
    $directory = $views[$view].directory
    if ($view -ceq $defaultView) {
        '    ~^{0}$ "";' -f [regex]::Escape($view)
        continue
    }
    $native = "$work/$directory/$buildDestination"
    $destination = "$site/_frameworks/$directory"
    New-Item -ItemType Directory -Path (Split-Path -Parent "$destination/$ApiPath") | Out-Null
    Copy-Item -LiteralPath "$native/$ApiPath" -Destination "$destination/$ApiPath" -Recurse
    Copy-Item -LiteralPath "$native/xrefmap.yml" -Destination $destination
    if (Test-Path -LiteralPath "$native/index.json" -PathType Leaf) { Copy-Item -LiteralPath "$native/index.json" -Destination $destination }
    foreach ($asset in Get-ChildItem -LiteralPath $native -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($native, $asset.FullName).Replace('\', '/')
        if ($relative.StartsWith("$ApiPath/") -or ($relative -notmatch '^public/' -and $asset.Extension -in '.html', '.json', '.yml', '.xml')) { continue }
        if (!(Test-Path -LiteralPath "$site/$relative" -PathType Leaf) -or
            (Get-FileHash -LiteralPath "$site/$relative").Hash -cne (Get-FileHash -LiteralPath $asset.FullName).Hash) {
            throw "Cannot share $relative with $view."
        }
    }
    '    ~^{0}$ /_frameworks/{1};' -f [regex]::Escape($view), $directory
}
$searchRoutes = foreach ($view in $views.Keys) {
    $directory = $views[$view].directory
    $root = if ($view -ceq $defaultView) { '""' } else { "/_frameworks/$directory" }
    '    ~^{0}$ {1};' -f [regex]::Escape($directory), $root
}
Write-Json "$site/framework-views.json" ([ordered]@{ schemaVersion = 1; apiPath = "/$ApiPath/"; defaultView = $defaultView; viewOrder = @($views.Keys); views = $views })
(Get-Content -LiteralPath "$PSScriptRoot/framework-views.nginx.conf" -Raw).Replace('__API__', "/$ApiPath/").
    Replace('__VIEWS__', ($routes -join "`n")).Replace('__SEARCH__', ($searchRoutes -join "`n")) | Set-Content -LiteralPath "$work/nginx.conf"
Write-Host "Site: $site"

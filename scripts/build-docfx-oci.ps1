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

    [Parameter(Mandatory = $true)]
    [string]$DocfxVersion,

    [Parameter(Mandatory = $true)]
    [string]$Platforms,

    [string]$FrameworkViews
)

$ErrorActionPreference = 'Stop'

$semverPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?$'
if ($Version -notmatch $semverPattern) {
    throw "Release version '$Version' is not a supported SemVer value."
}
if ($Revision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'The source revision must be a full 40-character commit SHA.'
}

$workspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$actualRevision = (& git -C $workspaceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Could not resolve the checked out source revision.'
}
if ($actualRevision -ne $Revision) {
    throw "The workspace is at '$actualRevision', but the requested release revision is '$Revision'."
}

$docfxConfigPath = if ([System.IO.Path]::IsPathRooted($DocfxConfig)) {
    [System.IO.Path]::GetFullPath($DocfxConfig)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $DocfxConfig))
}
if (!$Dockerfile) {
    if ($FrameworkViews) {
        throw "Framework views require an explicit dockerfile input. Use 'bundled-framework-views' to adopt the standard NGINX image and verification, or specify a compatible consumer Dockerfile."
    }
    $Dockerfile = '.docfx/Dockerfile.docfx'
}
$bundledPackaging = $FrameworkViews -and $Dockerfile -ceq 'bundled-framework-views'
$dockerfilePath = if ($bundledPackaging) {
    "$PSScriptRoot/framework-views.Dockerfile"
} elseif ([System.IO.Path]::IsPathRooted($Dockerfile)) {
    [System.IO.Path]::GetFullPath($Dockerfile)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $workspaceRoot $Dockerfile))
}
if (-not (Test-Path -LiteralPath $docfxConfigPath -PathType Leaf)) {
    throw "DocFX configuration was not found: $docfxConfigPath"
}
if (-not (Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
    throw "DocFX Dockerfile was not found: $dockerfilePath"
}

$docfxRoot = Split-Path -Parent $docfxConfigPath
$docfxConfigName = Split-Path -Leaf $docfxConfigPath
if (!$FrameworkViews) {
    $sourceRoot = [System.IO.Path]::GetFullPath((Join-Path $docfxRoot '../src'))
    $docfxConfigObject = Get-Content -LiteralPath $docfxConfigPath -Raw | ConvertFrom-Json
    $metadataProjectPatterns = @(
        foreach ($metadata in $docfxConfigObject.metadata) {
            foreach ($source in $metadata.src) {
                $metadataSourceRoot = if ($source.src) {
                    [System.IO.Path]::GetFullPath((Join-Path $docfxRoot $source.src))
                } else {
                    $docfxRoot
                }

                foreach ($file in $source.files) {
                    (Join-Path $metadataSourceRoot $file).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                }
            }
        }
    )

    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "The metadata source root was not found: $sourceRoot"
    }
    $sourceProjects = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter '*.csproj')
    $metadataProjects = @(
        $sourceProjects |
            Where-Object {
                $projectPath = $_.FullName
                foreach ($pattern in $metadataProjectPatterns) {
                    if ($projectPath -like $pattern) {
                        return $true
                    }
                }

                return $false
            }
    )

    $sourceProjectsHaveRestoreAssets = $sourceProjects.Count -gt 0
    foreach ($project in $sourceProjects) {
        $restoreAssetsPath = Join-Path $project.DirectoryName 'obj/project.assets.json'
        if (-not (Test-Path -LiteralPath $restoreAssetsPath -PathType Leaf)) {
            $sourceProjectsHaveRestoreAssets = $false
            break
        }
    }

    $useNoRestore = $metadataProjects.Count -gt 0 -and $sourceProjectsHaveRestoreAssets
    $restoreInputNames = @('Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'NuGet.Config', 'nuget.config', 'global.json')
    foreach ($project in $metadataProjects) {
        $restoreAssetsPath = Join-Path $project.DirectoryName 'obj/project.assets.json'
        if (-not (Test-Path -LiteralPath $restoreAssetsPath -PathType Leaf)) {
            $useNoRestore = $false
            break
        }

        $restoreAssetsLastWriteTime = (Get-Item -LiteralPath $restoreAssetsPath).LastWriteTimeUtc
        $restoreInputPaths = [System.Collections.Generic.List[string]]::new()
        $restoreInputPaths.Add($project.FullName)

        $inputDirectory = $project.DirectoryName
        while ($inputDirectory) {
            foreach ($name in $restoreInputNames) {
                $restoreInputPath = Join-Path $inputDirectory $name
                if (Test-Path -LiteralPath $restoreInputPath -PathType Leaf) {
                    $restoreInputPaths.Add($restoreInputPath)
                }
            }

            $parentDirectory = Split-Path -Parent $inputDirectory
            if (-not $parentDirectory -or $parentDirectory -eq $inputDirectory) {
                break
            }

            $inputDirectory = $parentDirectory
        }

        $lockFilePath = Join-Path $project.DirectoryName 'packages.lock.json'
        if (Test-Path -LiteralPath $lockFilePath -PathType Leaf) {
            $restoreInputPaths.Add($lockFilePath)
        }

        $userNuGetConfigPaths = [System.Collections.Generic.List[string]]::new()
        if ($env:APPDATA) {
            $userNuGetConfigPaths.Add((Join-Path $env:APPDATA 'NuGet/NuGet.Config'))
        }
        if ($env:HOME) {
            $userNuGetConfigPaths.Add((Join-Path $env:HOME '.nuget/NuGet/NuGet.Config'))
        }
        foreach ($userNuGetConfigPath in $userNuGetConfigPaths) {
            if (Test-Path -LiteralPath $userNuGetConfigPath -PathType Leaf) {
                $restoreInputPaths.Add($userNuGetConfigPath)
            }
        }

        foreach ($restoreInputPath in $restoreInputPaths | Sort-Object -Unique) {
            if ((Get-Item -LiteralPath $restoreInputPath).LastWriteTimeUtc -gt $restoreAssetsLastWriteTime) {
                $useNoRestore = $false
                break
            }
        }

        if (-not $useNoRestore) {
            break
        }
    }
}

$runnerTemp = if ($env:RUNNER_TEMP) {
    $env:RUNNER_TEMP
} else {
    [System.IO.Path]::GetTempPath()
}
$toolPath = Join-Path $runnerTemp "docfx-$DocfxVersion-tools"
New-Item -ItemType Directory -Force -Path $toolPath | Out-Null
& dotnet tool install --tool-path $toolPath docfx --version $DocfxVersion
if ($LASTEXITCODE -ne 0) {
    throw "Could not install DocFX CLI version $DocfxVersion."
}
$env:PATH = "$toolPath$([System.IO.Path]::PathSeparator)$env:PATH"

$outputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
if (Test-Path -LiteralPath $outputPath) {
    throw "OCI archive output already exists; choose a fresh output path: $outputPath"
}

$platformList = @($Platforms.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not ($platformList -contains 'linux/amd64') -or -not ($platformList -contains 'linux/arm64')) {
    throw 'The DocFX OCI artifact must include linux/amd64 and linux/arm64.'
}

$apiRoot = Join-Path $docfxRoot 'api'
$builderName = "docfx-oci-$PID"
$builderCreated = $false
$frameworkRoot = $null
$contextPath = $docfxRoot
Push-Location $docfxRoot
try {
    if ($FrameworkViews) {
        $settingsPath = [IO.Path]::GetFullPath($FrameworkViews, $workspaceRoot)
        $frameworkRoot = Join-Path $runnerTemp "docfx-framework-oci-$([guid]::NewGuid().ToString('N'))"
        & "$PSScriptRoot/Build-DocfxFrameworkViews.ps1" -DocfxConfig $docfxConfigPath `
            -OutputRoot "$frameworkRoot/build" -SettingsPath $settingsPath
        $contextPath = "$frameworkRoot/image"
        New-Item -ItemType Directory -Path $contextPath | Out-Null
        Move-Item -LiteralPath "$frameworkRoot/build/site", "$frameworkRoot/build/nginx.conf" -Destination $contextPath
    } elseif ($useNoRestore) {
        Write-Host 'All restore assets match current restore inputs; generating DocFX metadata without restoring again.'
        & docfx metadata $docfxConfigName --noRestore
    } else {
        Write-Host 'Restore assets are missing or stale; allowing DocFX metadata to restore its source projects.'
        & docfx metadata $docfxConfigName
    }
    if (!$FrameworkViews -and $LASTEXITCODE -ne 0) {
        throw "DocFX metadata generation failed with exit code $LASTEXITCODE."
    }

    & docker buildx version
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Buildx is not available.'
    }
    & docker buildx create --name $builderName --driver docker-container --use
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
        if ($FrameworkViews -and !$bundledPackaging) { '--build-context'; "docfx-source=$docfxRoot" }
        $contextPath
    )
    & docker buildx @buildArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Buildx failed to create the DocFX OCI artifact with exit code $LASTEXITCODE."
    }
} finally {
    if ($builderCreated) {
        & docker buildx rm $builderName | Out-Null
    }
    Pop-Location

    if ($frameworkRoot -and (Test-Path -LiteralPath $frameworkRoot -PathType Container)) {
        $temporary = (Resolve-Path -LiteralPath $frameworkRoot).Path
        $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($runnerTemp), $temporary)
        if ($relative -match '^docfx-framework-oci-[a-f0-9]{32}$') { Remove-Item -LiteralPath $temporary -Recurse -Force }
    } elseif (!$FrameworkViews -and (Test-Path -LiteralPath $apiRoot -PathType Container)) {
        Get-ChildItem -LiteralPath $apiRoot -Recurse -File |
            Where-Object { $_.Extension -eq '.yml' -or $_.Name -eq '.manifest' } |
            Remove-Item -Force
    }
}

if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw "Docker Buildx completed without creating the expected OCI archive: $outputPath"
}
$checksumPath = "$outputPath.sha256"
$archiveHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumText = "$archiveHash  $([System.IO.Path]::GetFileName($outputPath))$([System.Environment]::NewLine)"
[System.IO.File]::WriteAllText($checksumPath, $checksumText, [System.Text.UTF8Encoding]::new($false))

if (-not $env:GITHUB_OUTPUT) {
    throw 'GITHUB_OUTPUT is not available; this build script must run from a GitHub Action.'
}
Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "archive-path=$outputPath" -Encoding utf8
Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "checksum-path=$checksumPath" -Encoding utf8
Write-Host "Created OCI archive $outputPath for $Version at $Revision."

$ErrorActionPreference = 'Stop'

$actionPath = Join-Path $PSScriptRoot '..\action.yml'
$readmePath = Join-Path $PSScriptRoot '..\README.md'
$actionText = Get-Content -LiteralPath $actionPath -Raw
$readmeText = Get-Content -LiteralPath $readmePath -Raw

function Assert-Contains {
  param(
    [string] $Text,
    [string] $Expected,
    [string] $Message
  )

  if (-not $Text.Contains($Expected)) {
    throw "$Message Expected to find: $Expected"
  }
}

function Assert-DoesNotContain {
  param(
    [string] $Text,
    [string] $Unexpected,
    [string] $Message
  )

  if ($Text.Contains($Unexpected)) {
    throw "$Message Found unexpected text: $Unexpected"
  }
}

Assert-Contains -Text $actionText -Expected 'name: Require .NET 10 SDK' -Message 'The action must fail fast when the required SDK is missing.'
Assert-Contains -Text $actionText -Expected 'dotnet --list-sdks' -Message 'The action must inspect installed SDKs for the fail-fast prerequisite check.'
Assert-Contains -Text $actionText -Expected "Install .NET 10 or newer before invoking codebeltnet/docfx-oci-build." -Message 'The prerequisite diagnostic must tell callers how to fix a missing SDK.'
Assert-Contains -Text $actionText -Expected "[int]`$Matches.major -ge 10" -Message 'The action must accept compatible SDKs that are newer than .NET 10.'
Assert-Contains -Text $actionText -Expected 'uses: codebeltnet/oci-artifact-verify@v1' -Message 'The action must continue validating the built OCI artifact.'
Assert-DoesNotContain -Text $actionText -Unexpected 'install-dotnet:' -Message 'The action must not pass an install-dotnet toggle to nested actions.'
foreach ($inputName in 'version', 'revision', 'output-path', 'docfx-config', 'dockerfile', 'docfx-version', 'framework-views', 'platforms') {
  Assert-Contains -Text $actionText -Expected ('${{ inputs.' + $inputName + ' }}') -Message "The action must consume its '$inputName' input."
}

$outputCondition = 'value: ${{ steps.verify.outcome == ''success'' && steps.verify.outputs.digest'
Assert-Contains $actionText "$outputCondition && steps.build.outputs.archive-path || '' }}" 'The archive output must depend on verification.'
Assert-Contains $actionText "$outputCondition && steps.build.outputs.checksum-path || '' }}" 'The checksum output must depend on verification.'
Assert-Contains $actionText "$outputCondition || '' }}" 'The digest output must depend on verification.'
Assert-Contains -Text $actionText -Expected 'archive-path: ${{ steps.build.outputs.archive-path }}' -Message 'Verification must use the archive produced by the build.'
Assert-Contains -Text $actionText -Expected 'checksum-path: ${{ steps.build.outputs.checksum-path }}' -Message 'Verification must use the checksum produced by the build.'
Assert-DoesNotContain -Text $actionText -Unexpected 'docfx-engine-revision' -Message 'The action must use the conventional builder image.'
Assert-Contains -Text $readmeText -Expected 'install the .NET 10 SDK or newer' -Message 'The README must document the explicit SDK prerequisite.'
Assert-Contains -Text $readmeText -Expected 'fails immediately with an explicit diagnostic' -Message 'The README must describe the fail-fast prerequisite behavior.'

$actionRoot = (Resolve-Path -LiteralPath "$PSScriptRoot/..").Path
$build = Join-Path $actionRoot 'scripts/build-docfx-oci.ps1'
$arguments = @{
  Version = '1.1.0'
  Revision = (git -C $actionRoot rev-parse HEAD)
  OutputPath = (Join-Path ([IO.Path]::GetTempPath()) "docfx-oci-contract-$([guid]::NewGuid().ToString('N')).tar")
  WorkspaceRoot = $actionRoot
  DocfxConfig = 'action.yml'
  Platforms = 'linux/amd64,linux/arm64'
}

function Assert-BuildFailure($Expected) {
  $failure = ''
  try { & $build @arguments } catch { $failure = $_.Exception.Message }
  Assert-Contains -Text $failure -Expected $Expected -Message 'Unexpected action validation result.'
  if (Test-Path -LiteralPath $arguments.OutputPath) { throw 'Validation failure produced an OCI archive.' }
}

# Capture the packaging commands without contacting a registry or running Buildx.
$calls = [Collections.Generic.List[object]]::new()
function docker {
  $calls.Add(@($args))
  $global:LASTEXITCODE = 0
  if ($args[0] -eq 'create') { return 'test-container' }
  if ($args[0] -eq 'buildx' -and $args[1] -eq 'build') {
    Set-Content -LiteralPath $arguments.OutputPath -Value 'test OCI output'
  }
}

$previousGithubOutput = $env:GITHUB_OUTPUT
$env:GITHUB_OUTPUT = [IO.Path]::GetTempFileName()
try {
  Assert-BuildFailure 'DocFX Dockerfile was not found'
  $arguments.FrameworkViews = 'false'
  Assert-BuildFailure 'DocFX Dockerfile was not found'
  $arguments.FrameworkViews = 'invalid'
  Assert-BuildFailure "Set framework-views to 'true' or 'false'."
  $arguments.FrameworkViews = 'true'
  $arguments.Dockerfile = 'missing.Dockerfile'
  Assert-BuildFailure 'DocFX Dockerfile was not found'

  foreach ($custom in $false, $true) {
    $calls.Clear()
    $arguments.OutputPath = (Join-Path ([IO.Path]::GetTempPath()) "docfx-oci-contract-$([guid]::NewGuid().ToString('N')).tar")
    if ($custom) { $arguments.Dockerfile = 'action.yml' } else { $arguments.Remove('Dockerfile') }
    try {
      & $build @arguments
      $create = $calls | Where-Object { $_[0] -eq 'create' } | ForEach-Object { $_ -join ' ' }
      Assert-Contains $create '--pull always' 'Production must pull the approved builder tag.'
      Assert-Contains $create 'codebeltnet/docfx:2 ' 'Framework generation must use the stable Codebelt builder tag.'
      Assert-Contains $create '/opt/docfx/framework-views/Build-DocfxFrameworkViews.ps1 -DocfxConfig $env:DOCFX_CONFIG -OutputRoot /tmp/docfx-output' 'Framework generation must delegate to the bundled entry point.'
      Assert-DoesNotContain $create 'DOCFX_SETTINGS' 'Framework generation must use only the DocFX configuration.'
      $copies = ($calls | Where-Object { $_[0] -eq 'cp' } | ForEach-Object { $_[1] }) -join ' '
      Assert-Contains $copies 'test-container:/tmp/docfx-output/site' 'Packaging must use the generated site.'
      Assert-Contains $copies 'test-container:/tmp/docfx-output/nginx.conf' 'Packaging must use the generated routing.'
      $export = $calls | Where-Object { $_[0] -eq 'buildx' -and $_[1] -eq 'build' } | ForEach-Object { $_ -join ' ' }
      if ($custom) {
        Assert-DoesNotContain $copies 'framework-views.Dockerfile' 'Explicit packaging must use the consumer Dockerfile.'
        Assert-Contains $export "--file $(Join-Path $actionRoot 'action.yml')" 'The requested Dockerfile must be passed to Buildx.'
        Assert-Contains $export '--build-context docfx-source=' 'Custom packaging must receive the authored DocFX inputs.'
      } else {
        Assert-Contains $copies 'test-container:/opt/docfx/framework-views/framework-views.Dockerfile' 'Bundled packaging must be selected by default.'
        Assert-Contains $export 'framework-views.Dockerfile' 'Buildx must use the bundled Dockerfile.'
        Assert-DoesNotContain $export 'docfx-source=' 'Bundled packaging needs only generated output.'
      }
      if (!(Test-Path -LiteralPath "$($arguments.OutputPath).sha256" -PathType Leaf)) { throw 'The archive checksum was not written.' }
    } finally {
      Remove-Item -LiteralPath $arguments.OutputPath, "$($arguments.OutputPath).sha256" -ErrorAction SilentlyContinue
    }
  }
} finally {
  Remove-Item -LiteralPath $env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
  $env:GITHUB_OUTPUT = $previousGithubOutput
}

Write-Host 'DocFX OCI build action contract passed.'

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

Assert-Contains -Text $actionText -Expected 'value: ${{ steps.build.outputs.archive-path }}' -Message 'The action must expose the archive path.'
Assert-Contains -Text $actionText -Expected 'value: ${{ steps.build.outputs.checksum-path }}' -Message 'The action must expose the detached checksum path.'
Assert-Contains -Text $actionText -Expected 'value: ${{ steps.verify.outputs.digest }}' -Message 'The action must expose the verified OCI index digest.'
Assert-Contains -Text $actionText -Expected 'archive-path: ${{ steps.build.outputs.archive-path }}' -Message 'Verification must use the archive produced by the build.'
Assert-Contains -Text $actionText -Expected 'checksum-path: ${{ steps.build.outputs.checksum-path }}' -Message 'Verification must use the checksum produced by the build.'
Assert-DoesNotContain -Text $actionText -Unexpected 'docfx-engine-revision' -Message 'The builder image must be selected through the existing framework-view settings.'
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
  FrameworkViews = 'missing-framework-views.json'
  Platforms = 'linux/amd64,linux/arm64'
  Dockerfile = 'bundled-framework-views'
}

$failure = $null
try {
  & $build @arguments
} catch {
  $failure = $_.Exception.Message
}
Assert-Contains -Text $failure -Expected 'Framework views settings were not found' -Message 'The build must diagnose missing framework-view settings.'
if (Test-Path -LiteralPath $arguments.OutputPath) {
  throw 'Missing framework-view settings produced an OCI archive.'
}

Write-Host 'DocFX OCI build action contract passed.'

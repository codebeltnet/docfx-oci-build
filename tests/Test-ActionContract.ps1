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
Assert-Contains -Text $readmeText -Expected 'install the .NET 10 SDK or newer' -Message 'The README must document the explicit SDK prerequisite.'
Assert-Contains -Text $readmeText -Expected 'fails immediately with an explicit diagnostic' -Message 'The README must describe the fail-fast prerequisite behavior.'

Write-Host 'DocFX OCI build action contract passed.'

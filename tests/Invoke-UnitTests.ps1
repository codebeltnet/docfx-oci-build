#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$CoverageOutputPath = (Join-Path ([IO.Path]::GetTempPath()) 'docfx-oci-coverage.xml')
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 5.7.1
$configuration = New-PesterConfiguration
$configuration.Run.Path = "$PSScriptRoot/Build-DocfxOci.Tests.ps1"
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = (Resolve-Path "$PSScriptRoot/../scripts/build-docfx-oci.ps1").Path
$configuration.CodeCoverage.OutputPath = $CoverageOutputPath
$configuration.CodeCoverage.CoveragePercentTarget = 100

$result = Invoke-Pester -Configuration $configuration
$result.CodeCoverage.MissedCommands | Format-Table Line, Command -AutoSize | Out-Host
if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0 -or
    $result.CodeCoverage.CommandsAnalyzedCount -eq 0 -or $result.CodeCoverage.CommandsMissedCount -ne 0) {
    throw "Expected passing Pester tests and 100% measured command coverage. Passed: $($result.PassedCount), failed: $($result.FailedCount), coverage: $($result.CodeCoverage.CoveragePercent)%."
}

#Requires -Version 5.1
<#
.SYNOPSIS
    PCScope - inventory and health check for Windows computers.

.DESCRIPTION
    Collects a read-only inventory of this computer (hardware, storage, Windows,
    security, network and installed software), saves it as JSON and builds a
    self-contained HTML dashboard from every JSON found in the data folder.

    Running it on several computers with the same -OutputPath (for example a
    network share) produces one dashboard for the whole office.

.PARAMETER OutputPath
    Folder for the results. The JSON files go to <OutputPath>\data and the
    dashboard to <OutputPath>\report.html. Default: .\output next to this script.

.PARAMETER NoReport
    Only collect and save the JSON; do not build the dashboard.

.PARAMETER ReportOnly
    Do not collect anything; just rebuild the dashboard from existing JSON files.

.PARAMETER Open
    Open the dashboard in the default browser when finished.

.EXAMPLE
    .\PCScope.ps1 -Open

.EXAMPLE
    .\PCScope.ps1 -OutputPath \\server\it\pcscope -NoReport
#>
[CmdletBinding(DefaultParameterSetName = 'Collect')]
param(
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),

    [Parameter(ParameterSetName = 'Collect')]
    [switch] $NoReport,

    [Parameter(ParameterSetName = 'ReportOnly')]
    [switch] $ReportOnly,

    [switch] $Open
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'src\Collector.ps1')
. (Join-Path $PSScriptRoot 'src\Report.ps1')

$OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
$dataPath = Join-Path $OutputPath 'data'
if (-not (Test-Path -Path $dataPath)) {
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
}

if (-not $ReportOnly) {
    Write-Host "Collecting inventory of $env:COMPUTERNAME..."
    $inventory = Get-PCScopeInventory
    $jsonFile = Join-Path $dataPath "$($inventory.computerName).json"
    $json = $inventory | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($jsonFile, $json, (New-Object Text.UTF8Encoding($false)))

    Write-Host ("Saved {0} ({1} programs, {2} s)" -f $jsonFile, @($inventory.software).Count, $inventory.collector.durationSeconds)
    foreach ($problem in $inventory.errors) {
        Write-Warning "Section '$($problem.section)' failed: $($problem.message)"
    }
    if (-not $inventory.collector.elevated -and $inventory.battery -and $null -eq $inventory.battery.healthPercent) {
        Write-Host 'Tip: run as administrator to read the battery capacity on this laptop.'
    }
}

if (-not $NoReport) {
    $report = New-PCScopeReport -DataPath $dataPath -OutputFile (Join-Path $OutputPath 'report.html')
    Write-Host "Dashboard: $($report.FullName)"
    if ($Open) { Start-Process -FilePath $report.FullName }
}

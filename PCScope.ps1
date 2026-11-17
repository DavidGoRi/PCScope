#Requires -Version 5.1
<#
.SYNOPSIS
    PCScope - inventory and health check for Windows computers.

.DESCRIPTION
    Collects a read-only inventory (hardware, storage, Windows, security,
    network and installed software), saves it as JSON and builds a
    self-contained HTML dashboard from every JSON found in the data folder.

    Three ways to collect:
      - This computer (default).
      - Other computers over PowerShell remoting: -ComputerName or -ComputerListPath.
      - Each computer on a schedule, writing to a shared folder:
        see tools\Install-PCScopeTask.ps1.

.PARAMETER OutputPath
    Folder for the results. The JSON files go to <OutputPath>\data and the
    dashboard to <OutputPath>\report.html. Default: .\output next to this script.

.PARAMETER ComputerName
    Collect from these computers over PowerShell remoting (WinRM) instead of
    this one. Nothing needs to be installed on them.

.PARAMETER ComputerListPath
    Text file with one computer name per line (# starts a comment).

.PARAMETER Credential
    Account for the remote connections. By default the current user is used.

.PARAMETER ThrottleLimit
    Maximum number of computers contacted at the same time. Default: 32.

.PARAMETER NoReport
    Only collect and save the JSON; do not build the dashboard.

.PARAMETER ReportOnly
    Do not collect anything; just rebuild the dashboard from existing JSON files.

.PARAMETER RulesPath
    Health rules file. Default: rules.json next to this script.

.PARAMETER HistoryLimit
    Previous inventories kept per device in <OutputPath>\data\history, used to
    show what changed between runs. 0 disables history. Default: 30.

.PARAMETER ExportCsv
    Also export devices, issues, software and changes to CSV files in
    <OutputPath>\export (they open directly in Excel).

.PARAMETER SendAlerts
    Send new critical issues and notable changes by Telegram and/or email, as
    configured in -AlertConfigPath. Already-sent alerts are not repeated.

.PARAMETER AlertConfigPath
    Alert configuration. Default: alerts.json (see alerts.example.json).

.PARAMETER Open
    Open the dashboard in the default browser when finished.

.EXAMPLE
    .\PCScope.ps1 -Open

.EXAMPLE
    .\PCScope.ps1 -ComputerListPath .\computers.txt -Credential (Get-Credential) -Open

.EXAMPLE
    .\PCScope.ps1 -OutputPath \\server\it\pcscope -NoReport
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ReportOnly', Justification = 'Only selects the ReportOnly parameter set')]
[CmdletBinding(DefaultParameterSetName = 'Local')]
param(
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),

    [Parameter(Mandatory, ParameterSetName = 'Remote')]
    [string[]] $ComputerName,

    [Parameter(Mandatory, ParameterSetName = 'RemoteList')]
    [string] $ComputerListPath,

    [Parameter(ParameterSetName = 'Remote')]
    [Parameter(ParameterSetName = 'RemoteList')]
    [pscredential] $Credential,

    [Parameter(ParameterSetName = 'Remote')]
    [Parameter(ParameterSetName = 'RemoteList')]
    [ValidateRange(1, 256)]
    [int] $ThrottleLimit = 32,

    [Parameter(ParameterSetName = 'Local')]
    [Parameter(ParameterSetName = 'Remote')]
    [Parameter(ParameterSetName = 'RemoteList')]
    [switch] $NoReport,

    [Parameter(Mandatory, ParameterSetName = 'ReportOnly')]
    [switch] $ReportOnly,

    [string] $RulesPath = (Join-Path $PSScriptRoot 'rules.json'),

    [ValidateRange(0, 1000)]
    [int] $HistoryLimit = 30,

    [switch] $ExportCsv,

    [switch] $SendAlerts,

    [string] $AlertConfigPath = (Join-Path $PSScriptRoot 'alerts.json'),

    [switch] $Open
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'src\Collector.ps1')
. (Join-Path $PSScriptRoot 'src\Remote.ps1')
. (Join-Path $PSScriptRoot 'src\Report.ps1')
. (Join-Path $PSScriptRoot 'src\Alert.ps1')

$OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
$dataPath = Join-Path $OutputPath 'data'
if (-not (Test-Path -Path $dataPath)) {
    New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
}

switch ($PSCmdlet.ParameterSetName) {
    'Local' {
        Write-Host "Collecting inventory of $env:COMPUTERNAME..."
        $inventory = Get-PCScopeInventory
        $json = $inventory | ConvertTo-Json -Depth 8
        $jsonFile = Save-PCScopeInventory -Json $json -DataPath $dataPath -HistoryLimit $HistoryLimit

        Write-Host ("Saved {0} ({1} programs, {2} s)" -f $jsonFile, @($inventory.software).Count, $inventory.collector.durationSeconds)
        foreach ($problem in $inventory.errors) {
            Write-Warning "Section '$($problem.section)' failed: $($problem.message)"
        }
        if (-not $inventory.collector.elevated -and $inventory.battery -and $null -eq $inventory.battery.healthPercent) {
            Write-Host 'Tip: run as administrator to read the battery capacity on this laptop.'
        }

        # Quick summary in the console, using the same rules as the dashboard
        $issues = @(Get-PCScopeIssue -Inventory ($json | ConvertFrom-Json) -RuleSet (Get-PCScopeRuleSet -Path $RulesPath))
        $colors = @{ critical = 'Red'; warning = 'Yellow'; info = 'Gray' }
        Write-Host ("Status: {0} ({1} issue(s))" -f (Get-PCScopeStatus -Issue $issues).ToUpper(), $issues.Count)
        foreach ($issue in $issues) {
            Write-Host ("  [{0}] {1}" -f $issue.level, $issue.message) -ForegroundColor $colors[$issue.level]
        }
    }

    { $_ -in 'Remote', 'RemoteList' } {
        if ($ComputerListPath) { $ComputerName = Get-PCScopeComputerList -Path $ComputerListPath }
        if (-not $ComputerName) { throw 'No computers to collect from.' }

        Write-Host "Collecting inventory of $(@($ComputerName).Count) computer(s) over PowerShell remoting..."
        $remote = @{ ComputerName = $ComputerName; DataPath = $dataPath; ThrottleLimit = $ThrottleLimit; HistoryLimit = $HistoryLimit }
        if ($Credential) { $remote.Credential = $Credential }
        $results = @(Invoke-PCScopeRemoteCollection @remote)

        foreach ($result in $results) {
            if ($result.Status -eq 'OK') {
                Write-Host ("  [OK]     {0} ({1} s)" -f $result.ComputerName, $result.Seconds) -ForegroundColor Green
            }
            else {
                $message = if ($result.Message.Length -gt 200) { $result.Message.Substring(0, 197) + '...' } else { $result.Message }
                Write-Host ("  [FAILED] {0}: {1}" -f $result.ComputerName, $message) -ForegroundColor Red
            }
        }
        $failed = @($results | Where-Object { $_.Status -ne 'OK' })
        Write-Host ("Collected {0} of {1} computer(s)." -f ($results.Count - $failed.Count), $results.Count)
        if ($failed.Count) {
            $failedFile = Join-Path $OutputPath 'failed-computers.txt'
            [IO.File]::WriteAllLines($failedFile, [string[]]@($failed | ForEach-Object { $_.ComputerName }))
            Write-Host "Unreachable computers saved to $failedFile (use it with -ComputerListPath to retry)."
        }
    }
}

if (-not $NoReport) {
    $report = New-PCScopeReport -DataPath $dataPath -OutputFile (Join-Path $OutputPath 'report.html') -RulesPath $RulesPath
    Write-Host "Dashboard: $($report.FullName)"
    if ($Open) { Start-Process -FilePath $report.FullName }
}

if ($ExportCsv) {
    $exported = @(Export-PCScopeCsv -DataPath $dataPath -OutputPath (Join-Path $OutputPath 'export') -RulesPath $RulesPath)
    Write-Host "CSV files: $(Split-Path -Path $exported[0].FullName -Parent) ($(($exported | ForEach-Object { $_.Name }) -join ', '))"
}

if ($SendAlerts) {
    $fleet = @(Get-PCScopeFleet -DataPath $dataPath -RuleSet (Get-PCScopeRuleSet -Path $RulesPath))
    $sentAlerts = @(Invoke-PCScopeAlert -Fleet $fleet -Config (Get-PCScopeAlertConfig -Path $AlertConfigPath) -StatePath (Join-Path $OutputPath 'alerts-state.json'))
    if ($sentAlerts.Count) { Write-Host "Alerts sent: $($sentAlerts.Count) new." } else { Write-Host 'Alerts: nothing new to report.' }
}

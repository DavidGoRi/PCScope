#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the self-contained HTML dashboard and CSV exports from the
    collected JSON files.

.DESCRIPTION
    The dashboard is a single HTML file with the data embedded, so it can be
    opened straight from disk or a network share: no web server, no internet
    connection and no external libraries are needed.

    Health rules (rules.json) and history comparisons are evaluated here, in
    PowerShell; the page only displays the results.
#>

. (Join-Path $PSScriptRoot 'Rules.ps1')
. (Join-Path $PSScriptRoot 'History.ps1')

function ConvertTo-PCScopeScriptJson {
    <#
    .SYNOPSIS
        Makes JSON safe to embed inside a <script> element.
    .DESCRIPTION
        '<' can only appear inside JSON strings, so replacing it with its JSON
        unicode escape (backslash + u003c) never changes the data and prevents
        a value such as "</script>" from breaking or injecting into the page.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Json)

    $lessThanEscape = [string][char]92 + 'u003c'
    return $Json.Replace('<', $lessThanEscape)
}

function Get-PCScopeFleet {
    <#
    .SYNOPSIS
        Loads every inventory in a data folder with its issues and its
        timeline of changes. Shared by the dashboard and the CSV export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DataPath,
        [Parameter(Mandatory)] $RuleSet,
        [datetime] $Now = (Get-Date),
        [ValidateRange(0, 1000)] [int] $HistoryDepth = 10
    )

    $DataPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DataPath)
    if (-not (Test-Path -Path $DataPath -PathType Container)) {
        throw "Data folder not found: $DataPath"
    }

    # Only the top level: archived snapshots live in the history subfolder
    foreach ($file in Get-ChildItem -Path $DataPath -Filter '*.json' -File | Sort-Object -Property Name) {
        $raw = [IO.File]::ReadAllText($file.FullName).Trim()
        try {
            $inventory = $raw | ConvertFrom-Json -ErrorAction Stop
            if (-not $inventory.computerName) { throw 'missing computerName' }
        }
        catch {
            Write-Warning "Skipping $($file.Name): not a valid PCScope inventory ($($_.Exception.Message))"
            continue
        }

        $issues = @(Get-PCScopeIssue -Inventory $inventory -RuleSet $RuleSet -Now $Now)
        $changes = @()
        if ($HistoryDepth -gt 0) {
            $history = @(Get-PCScopeHistory -DataPath $DataPath -ComputerName $inventory.computerName -Depth $HistoryDepth)
            if ($history.Count) { $changes = @(Get-PCScopeTimeline -History $history -Current $inventory) }
        }

        [pscustomobject]@{
            Name      = [string]$inventory.computerName
            Raw       = $raw
            Inventory = $inventory
            Issues    = $issues
            Status    = Get-PCScopeStatus -Issue $issues
            Changes   = $changes
        }
    }
}

function New-PCScopeReport {
    <#
    .SYNOPSIS
        Creates the dashboard from every *.json inventory found in a folder.

    .EXAMPLE
        New-PCScopeReport -DataPath .\output\data -OutputFile .\output\report.html
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)] [string] $DataPath,
        [Parameter(Mandatory)] [string] $OutputFile,
        [string] $RulesPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'rules.json'),
        [string] $TemplatePath = (Join-Path $PSScriptRoot 'report-template.html'),
        [string] $Title = 'PCScope',
        [datetime] $Now = (Get-Date),
        [ValidateRange(0, 1000)] [int] $HistoryDepth = 10
    )

    $ruleSet = Get-PCScopeRuleSet -Path $RulesPath
    $fleet = @(Get-PCScopeFleet -DataPath $DataPath -RuleSet $ruleSet -Now $Now -HistoryDepth $HistoryDepth)

    $issuesByDevice = [ordered]@{}
    $changesByDevice = [ordered]@{}
    foreach ($device in $fleet) {
        $issuesByDevice[$device.Name] = [object[]]$device.Issues
        $changesByDevice[$device.Name] = [object[]]$device.Changes
    }

    $devicesJson = ConvertTo-PCScopeScriptJson ('[' + (($fleet | ForEach-Object { $_.Raw }) -join ',') + ']')
    $issuesJson = ConvertTo-PCScopeScriptJson (ConvertTo-Json -InputObject $issuesByDevice -Depth 5 -Compress)
    $changesJson = ConvertTo-PCScopeScriptJson (ConvertTo-Json -InputObject $changesByDevice -Depth 5 -Compress)

    $template = [IO.File]::ReadAllText($TemplatePath)
    $html = $template.
        Replace('/*PCSCOPE_DATA*/[]', $devicesJson).
        Replace('/*PCSCOPE_ISSUES*/{}', $issuesJson).
        Replace('/*PCSCOPE_CHANGES*/{}', $changesJson).
        Replace('{{TITLE}}', [Net.WebUtility]::HtmlEncode($Title)).
        Replace('{{GENERATED_AT}}', $Now.ToString('yyyy-MM-ddTHH:mm:ss'))

    # Resolve against the PowerShell location, not the process working directory
    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputFile)
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Write dashboard')) { return }

    $folder = Split-Path -Path $fullPath -Parent
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    [IO.File]::WriteAllText($fullPath, $html, (New-Object Text.UTF8Encoding($false)))

    Write-Verbose "Report created with $($fleet.Count) device(s): $fullPath"
    return Get-Item -Path $fullPath
}

function Export-PCScopeCsv {
    <#
    .SYNOPSIS
        Exports devices, issues, installed software and changes to CSV files
        that open directly in Excel.

    .DESCRIPTION
        Creates devices.csv, issues.csv, software.csv and changes.csv in
        -OutputPath. Files are UTF-8 with BOM and, by default, use the list
        separator of the current culture (";" in Spanish, "," in English), which
        is what Excel expects when the file is double-clicked.

    .EXAMPLE
        Export-PCScopeCsv -DataPath .\output\data -OutputPath .\output\export
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $DataPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [string] $RulesPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'rules.json'),
        [string] $Delimiter = (Get-Culture).TextInfo.ListSeparator,
        [datetime] $Now = (Get-Date),
        [ValidateRange(0, 1000)] [int] $HistoryDepth = 10
    )

    $fleet = @(Get-PCScopeFleet -DataPath $DataPath -RuleSet (Get-PCScopeRuleSet -Path $RulesPath) -Now $Now -HistoryDepth $HistoryDepth)
    $OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Export CSV files')) { return }
    if (-not (Test-Path -Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

    $devices = foreach ($device in $fleet) {
        $inv = $device.Inventory
        $hw = $inv.hardware; $os = $inv.operatingSystem; $sec = $inv.security
        $volumes = @($inv.storage.volumes | Where-Object { $_ })
        $system = $volumes | Where-Object { $_.drive -eq 'C:' } | Select-Object -First 1
        $activeAv = @($sec.antivirusProducts | Where-Object { $_ -and $_.enabled } | ForEach-Object { $_.name })
        [pscustomobject][ordered]@{
            Device         = $device.Name
            Status         = $device.Status
            Critical       = @($device.Issues | Where-Object { $_.level -eq 'critical' }).Count
            Warnings       = @($device.Issues | Where-Object { $_.level -eq 'warning' }).Count
            Manufacturer   = $hw.manufacturer
            Model          = $hw.model
            SerialNumber   = $hw.serialNumber
            Type           = $hw.formFactor
            CPU            = $hw.cpu.name
            RamGB          = $hw.memory.totalGB
            Windows        = $os.name
            Version        = $os.displayVersion
            Build          = $os.build
            LastUpdate     = $os.lastUpdate.date
            SystemDriveUsedPercent = $(if ($system) { $system.usedPercent } else { $null })
            SystemDriveFreeGB      = $(if ($system) { $system.freeGB } else { $null })
            BitLocker      = $(if ($system) { $system.bitLocker } else { $null })
            Antivirus      = ($activeAv -join ', ')
            User           = $inv.users.lastLoggedOnUser
            IPv4           = (@($inv.network | ForEach-Object { $_.ipv4 }) -join ', ')
            CollectedAt    = $inv.collectedAt
        }
    }
    $issues = foreach ($device in $fleet) {
        foreach ($issue in $device.Issues) {
            [pscustomobject][ordered]@{ Device = $device.Name; Level = $issue.level; Rule = $issue.rule; Issue = $issue.message }
        }
    }
    $software = foreach ($device in $fleet) {
        foreach ($program in @($device.Inventory.software | Where-Object { $_ })) {
            [pscustomobject][ordered]@{
                Device = $device.Name; Program = $program.name; Version = $program.version
                Publisher = $program.publisher; InstallDate = $program.installDate; Scope = $program.scope
            }
        }
    }
    $changes = foreach ($device in $fleet) {
        foreach ($change in $device.Changes) {
            [pscustomobject][ordered]@{
                Date = $change.date; Device = $device.Name; Category = $change.category
                Type = $change.type; Change = $change.message; Notable = $change.notable
            }
        }
    }

    $files = [ordered]@{
        'devices.csv'  = @($devices)
        'issues.csv'   = @($issues)
        'software.csv' = @($software)
        'changes.csv'  = @($changes)
    }
    foreach ($name in $files.Keys) {
        $path = Join-Path $OutputPath $name
        if ($files[$name].Count) {
            $files[$name] | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Delimiter $Delimiter
        }
        else {
            # Still create the file, empty, so scripts that read it do not fail
            [IO.File]::WriteAllText($path, '', (New-Object Text.UTF8Encoding($true)))
        }
        Get-Item -Path $path
    }
}

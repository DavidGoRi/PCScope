#Requires -Version 5.1
<#
.SYNOPSIS
    Health rules: turn an inventory into a list of issues.

.DESCRIPTION
    Rules and their thresholds live in rules.json, so each organisation can
    adapt them without touching the code. Every rule is optional: a rule that
    is missing from the file or has "enabled": false is skipped.

    The functions work on inventories parsed from JSON (ConvertFrom-Json), which
    is how the report reads them.
#>

$script:PCScopeLevels = @{ critical = 3; warning = 2; info = 1 }

function Get-PCScopeRuleSet {
    <#
    .SYNOPSIS
        Loads and validates a rules file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Rules file not found: $Path"
    }
    # .NET resolves relative paths against the process directory, not the
    # PowerShell location, so resolve the path first
    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $ruleSet = [IO.File]::ReadAllText($fullPath) | ConvertFrom-Json
    if (-not $ruleSet.rules) {
        throw "Invalid rules file (no 'rules' section): $Path"
    }
    foreach ($property in $ruleSet.rules.PSObject.Properties) {
        $level = $property.Value.level
        if ($level -and -not $script:PCScopeLevels.ContainsKey([string]$level)) {
            throw "Rule '$($property.Name)' has an invalid level '$level' (use critical, warning or info)"
        }
    }
    return $ruleSet
}

function ConvertTo-PCScopeVersion {
    <#
    .SYNOPSIS
        Parses the numeric start of a version string ("131.0.6778.86",
        "24.08", "8.6.2 (64-bit)") into a [version], or $null.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param([string] $Text)

    if ($Text -notmatch '^\s*(\d+(\.\d+){0,3})') { return $null }
    $value = $Matches[1]
    if ($value -notmatch '\.') { $value += '.0' }
    return [version]$value
}

function Get-PCScopeIssue {
    <#
    .SYNOPSIS
        Evaluates the rules against one inventory and returns its issues,
        most severe first.

    .PARAMETER Now
        Reference date for age-based rules. Defaults to the current date;
        tests pass a fixed date.

    .EXAMPLE
        $inventory = Get-Content .\output\data\PC01.json -Raw | ConvertFrom-Json
        Get-PCScopeIssue -Inventory $inventory -RuleSet (Get-PCScopeRuleSet .\rules.json)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Inventory,
        [Parameter(Mandatory)] $RuleSet,
        [datetime] $Now = (Get-Date)
    )

    $rules = $RuleSet.rules
    $issues = New-Object System.Collections.Generic.List[object]

    # Small closures keep each rule below short and readable
    $on = { param($name) $cfg = $rules.$name; return ($null -ne $cfg -and $cfg.enabled -ne $false) }
    $add = { param($rule, $level, $message) $issues.Add([pscustomobject][ordered]@{ rule = $rule; level = $level; message = $message }) }
    $days = { param($isoDate, $reference) if (-not $isoDate) { return $null }; return [Math]::Floor(($reference - [datetime]$isoDate).TotalDays) }

    $hw = $Inventory.hardware
    $os = $Inventory.operatingSystem
    $sec = $Inventory.security
    $volumes = @($Inventory.storage.volumes | Where-Object { $_ })

    if (& $on 'diskSpace') {
        $cfg = $rules.diskSpace
        foreach ($volume in $volumes) {
            if ($null -eq $volume.usedPercent) { continue }
            if ($volume.usedPercent -ge $cfg.criticalPercent) {
                & $add 'diskSpace' 'critical' "Drive $($volume.drive) is $($volume.usedPercent)% full ($($volume.freeGB) GB free)"
            }
            elseif ($volume.usedPercent -ge $cfg.warningPercent) {
                & $add 'diskSpace' 'warning' "Drive $($volume.drive) is $($volume.usedPercent)% full ($($volume.freeGB) GB free)"
            }
        }
    }

    if (& $on 'diskHealth') {
        foreach ($disk in @($Inventory.storage.physical | Where-Object { $_ })) {
            if ($disk.healthStatus -and $disk.healthStatus -ne 'Healthy') {
                & $add 'diskHealth' $rules.diskHealth.level "Disk '$($disk.name)' reports health '$($disk.healthStatus)' ($($disk.operationalStatus)): back up and replace it"
            }
        }
    }

    $products = @($sec.antivirusProducts | Where-Object { $_ })
    $defenderActive = ($sec.defender -and $sec.defender.realTimeProtection -eq $true)
    $activeProducts = @($products | Where-Object { $_.enabled })
    $avKnown = ($products.Count -gt 0 -or $sec.defender)

    if ((& $on 'antivirus') -and $avKnown -and $activeProducts.Count -eq 0 -and -not $defenderActive) {
        & $add 'antivirus' $rules.antivirus.level 'No active antivirus'
    }

    if (& $on 'antivirusDefinitions') {
        $cfg = $rules.antivirusDefinitions
        foreach ($product in @($activeProducts | Where-Object { -not $_.upToDate })) {
            & $add 'antivirusDefinitions' $cfg.level "$($product.name) definitions are out of date"
        }
        if ($defenderActive -and $sec.defender.signatureAgeDays -gt $cfg.maxAgeDays -and
            -not ($activeProducts | Where-Object { $_.name -like '*Defender*' -and -not $_.upToDate })) {
            & $add 'antivirusDefinitions' $cfg.level "Defender signatures are $($sec.defender.signatureAgeDays) days old"
        }
    }

    if (& $on 'firewall') {
        $off = @($sec.firewall | Where-Object { $_ -and $_.enabled -eq $false } | ForEach-Object { $_.profile })
        if ($off.Count) { & $add 'firewall' $rules.firewall.level "Firewall disabled on: $($off -join ', ')" }
    }

    if ((& $on 'uac') -and $sec.uacEnabled -eq $false) {
        & $add 'uac' $rules.uac.level 'User Account Control (UAC) is disabled'
    }

    if ((& $on 'windowsUpdates') -and $os.lastUpdate) {
        $cfg = $rules.windowsUpdates
        $age = & $days $os.lastUpdate.date $Now
        if ($null -ne $age -and $age -gt $cfg.criticalDays) {
            & $add 'windowsUpdates' 'critical' "No Windows update installed for $age days"
        }
        elseif ($null -ne $age -and $age -gt $cfg.warningDays) {
            & $add 'windowsUpdates' 'warning' "No Windows update installed for $age days"
        }
    }

    if ((& $on 'unsupportedWindows') -and $os.build) {
        $major = 0
        if ([int]::TryParse(([string]$os.build).Split('.')[0], [ref]$major) -and $major -lt $rules.unsupportedWindows.minBuild) {
            $detail = $(if ($os.name -like '*Windows 10*') { ': Windows 10 stopped receiving security updates on 14 Oct 2025' } else { '' })
            & $add 'unsupportedWindows' $rules.unsupportedWindows.level "$($os.name) (build $($os.build)) is no longer supported$detail"
        }
    }

    if ((& $on 'pendingReboot') -and $os.pendingReboot -and $os.pendingReboot.required) {
        & $add 'pendingReboot' $rules.pendingReboot.level "Restart pending ($(@($os.pendingReboot.reasons) -join ', '))"
    }

    if ((& $on 'uptime') -and $os.uptimeDays -gt $rules.uptime.maxDays) {
        & $add 'uptime' $rules.uptime.level "Not restarted for $([Math]::Floor($os.uptimeDays)) days"
    }

    if ((& $on 'laptopEncryption') -and $hw.formFactor -eq 'Laptop') {
        $system = $volumes | Where-Object { $_.drive -eq 'C:' } | Select-Object -First 1
        if ($system -and $system.bitLocker -eq 'Off') {
            & $add 'laptopEncryption' $rules.laptopEncryption.level 'Laptop system drive is not encrypted (BitLocker off)'
        }
    }

    if ((& $on 'batteryHealth') -and $Inventory.battery -and $null -ne $Inventory.battery.healthPercent -and
        $Inventory.battery.healthPercent -lt $rules.batteryHealth.minPercent) {
        & $add 'batteryHealth' $rules.batteryHealth.level "Battery holds $($Inventory.battery.healthPercent)% of its design capacity"
    }

    if ((& $on 'memory') -and $hw.memory -and [Math]::Round([double]$hw.memory.totalGB) -lt $rules.memory.minGB) {
        & $add 'memory' $rules.memory.level "Only $($hw.memory.totalGB) GB of RAM"
    }

    if (& $on 'localAdministrators') {
        $allowed = @($rules.localAdministrators.allowed)
        $unexpected = @($sec.localAdministrators | Where-Object { $_ } | ForEach-Object { $_.name } | Where-Object {
            $account = ([string]$_).Split('\')[-1]
            -not ($allowed | Where-Object { $_ -eq $account })
        })
        if ($unexpected.Count) {
            & $add 'localAdministrators' $rules.localAdministrators.level "Unexpected local administrators: $($unexpected -join ', ')"
        }
    }

    $software = @($Inventory.software | Where-Object { $_ })
    # "7-Zip 23.01 (x64)" already contains its version: do not repeat it
    $label = { param($program)
        if (-not $program.version -or ([string]$program.name).Contains([string]$program.version)) { return [string]$program.name }
        return "$($program.name) $($program.version)"
    }

    if (& $on 'blockedSoftware') {
        foreach ($pattern in @($rules.blockedSoftware.patterns)) {
            foreach ($program in @($software | Where-Object { $_.name -like "*$pattern*" })) {
                & $add 'blockedSoftware' $rules.blockedSoftware.level "Unapproved software installed: $(& $label $program)"
            }
        }
    }

    if (& $on 'outdatedSoftware') {
        foreach ($entry in $rules.outdatedSoftware.minimumVersions.PSObject.Properties) {
            $minimum = ConvertTo-PCScopeVersion $entry.Value
            foreach ($program in @($software | Where-Object { $_.name -like "$($entry.Name)*" })) {
                $installed = ConvertTo-PCScopeVersion $program.version
                if ($installed -and $minimum -and $installed -lt $minimum) {
                    & $add 'outdatedSoftware' $rules.outdatedSoftware.level "$(& $label $program) is outdated (minimum $($entry.Value))"
                }
            }
        }
    }

    if ((& $on 'staleInventory') -and $Inventory.collectedAt) {
        $age = & $days $Inventory.collectedAt $Now
        if ($age -gt $rules.staleInventory.maxDays) {
            & $add 'staleInventory' $rules.staleInventory.level "Inventory is $age days old: the data may be out of date"
        }
    }

    if (& $on 'collectionErrors') {
        $failed = @($Inventory.errors | Where-Object { $_ } | ForEach-Object { $_.section })
        if ($failed.Count) {
            & $add 'collectionErrors' $rules.collectionErrors.level "Could not collect: $($failed -join ', ')"
        }
    }

    # Most severe first, keeping the rule order within each level
    $sorted = foreach ($level in 'critical', 'warning', 'info') {
        $issues | Where-Object { $_.level -eq $level }
    }
    return @($sorted)
}

function Get-PCScopeStatus {
    <#
    .SYNOPSIS
        Overall status of a device: critical, warning or ok (info issues do
        not change the status).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]] $Issue)

    if (@($Issue | Where-Object { $_.level -eq 'critical' }).Count) { return 'critical' }
    if (@($Issue | Where-Object { $_.level -eq 'warning' }).Count) { return 'warning' }
    return 'ok'
}

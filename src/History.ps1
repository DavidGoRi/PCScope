#Requires -Version 5.1
<#
.SYNOPSIS
    Inventory history: keeps previous snapshots and finds what changed.

.DESCRIPTION
    When a new inventory replaces an existing one, the old file is moved to
    <data>\history\<DEVICE>\<yyyyMMdd-HHmmss>.json. Comparing consecutive
    snapshots answers questions such as "what was installed on this PC last
    week?" or "when did this disk start filling up?".
#>

function ConvertTo-PCScopeFileName {
    <#
    .SYNOPSIS
        Makes a computer name safe to use as a file name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Name)

    return ($Name -replace '[^\w.-]', '_')
}

function Save-PCScopeInventory {
    <#
    .SYNOPSIS
        Saves an inventory as <data>\<DEVICE>.json, archiving the previous one.

    .PARAMETER HistoryLimit
        Snapshots kept per device (oldest are deleted). 0 disables history.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Json,
        [Parameter(Mandatory)] [string] $DataPath,
        [ValidateRange(0, 1000)] [int] $HistoryLimit = 30
    )

    $DataPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DataPath)
    $inventory = $Json | ConvertFrom-Json
    if (-not $inventory.computerName) { throw 'The inventory has no computerName.' }

    $name = ConvertTo-PCScopeFileName $inventory.computerName
    $file = Join-Path $DataPath "$name.json"
    $utf8 = New-Object Text.UTF8Encoding($false)
    if (-not $PSCmdlet.ShouldProcess($file, 'Save inventory')) { return $file }
    if (-not (Test-Path -Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath -Force | Out-Null }

    if ($HistoryLimit -gt 0 -and (Test-Path -Path $file)) {
        $previousText = [IO.File]::ReadAllText($file)
        $previous = $null
        try { $previous = $previousText | ConvertFrom-Json } catch { Write-Warning "Previous inventory of $name is not valid JSON; it will not be archived." }

        if ($previous -and $previous.collectedAt -and $previous.collectedAt -ne $inventory.collectedAt) {
            $folder = Join-Path $DataPath "history\$name"
            if (-not (Test-Path -Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            $stamp = ([datetime]$previous.collectedAt).ToString('yyyyMMdd-HHmmss')
            [IO.File]::WriteAllText((Join-Path $folder "$stamp.json"), $previousText, $utf8)

            Get-ChildItem -Path $folder -Filter '*.json' -File |
                Sort-Object -Property Name -Descending |
                Select-Object -Skip $HistoryLimit |
                Remove-Item -Force
        }
    }

    [IO.File]::WriteAllText($file, $Json, $utf8)
    return $file
}

function Get-PCScopeHistory {
    <#
    .SYNOPSIS
        Returns the archived snapshots of a device, oldest first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DataPath,
        [Parameter(Mandatory)] [string] $ComputerName,
        [ValidateRange(1, 1000)] [int] $Depth = 10
    )

    $folder = Join-Path $DataPath ("history\{0}" -f (ConvertTo-PCScopeFileName $ComputerName))
    if (-not (Test-Path -Path $folder)) { return @() }

    $snapshots = foreach ($file in Get-ChildItem -Path $folder -Filter '*.json' -File | Sort-Object -Property Name -Descending | Select-Object -First $Depth) {
        try { [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json }
        catch { Write-Warning "Skipping invalid history file $($file.FullName)" }
    }
    return @($snapshots | Sort-Object -Property { [datetime]$_.collectedAt })
}

function Compare-PCScopeInventory {
    <#
    .SYNOPSIS
        Lists what changed between two inventories of the same device.

    .DESCRIPTION
        Each change has a category (Software, Hardware, Storage, Windows,
        Security, Network, Users), a type (added, removed, changed), a
        human-readable message and a "notable" flag for changes worth a look:
        security settings weakened, new administrators, hardware swapped.

    .EXAMPLE
        Compare-PCScopeInventory -Previous $lastWeek -Current $today | Format-Table category, message
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Previous,
        [Parameter(Mandatory)] $Current,
        [ValidateRange(1, 100)] [int] $DiskChangePercent = 5
    )

    # Messages use string interpolation, which is culture-invariant (7.8 GB, not 7,8 GB);
    # the -f operator would follow the system language
    $changes = New-Object System.Collections.Generic.List[object]
    $add = {
        param($category, $type, $message, $notable)
        $changes.Add([pscustomobject][ordered]@{ category = $category; type = $type; message = $message; notable = [bool]$notable })
    }
    # Index a list by a key so items can be matched between snapshots
    $index = {
        param($items, $key)
        $map = [ordered]@{}
        foreach ($item in @($items | Where-Object { $_ })) {
            $id = ([string]$item.$key).ToLowerInvariant()
            if ($id -and -not $map.Contains($id)) { $map[$id] = $item }
        }
        return $map
    }
    $text = { param($value) if ($null -eq $value -or $value -eq '') { return 'unknown' } return [string]$value }

    # --- Software -----------------------------------------------------------
    $before = & $index $Previous.software 'name'
    $after = & $index $Current.software 'name'
    foreach ($id in $after.Keys) {
        $program = $after[$id]
        if (-not $before.Contains($id)) {
            & $add 'Software' 'added' ("Installed {0} {1}" -f $program.name, $program.version).Trim() $false
        }
        elseif ([string]$before[$id].version -ne [string]$program.version) {
            & $add 'Software' 'changed' ("{0}: {1} -> {2}" -f $program.name, (& $text $before[$id].version), (& $text $program.version)) $false
        }
    }
    foreach ($id in $before.Keys) {
        if (-not $after.Contains($id)) { & $add 'Software' 'removed' "Uninstalled $($before[$id].name)" $false }
    }

    # --- Hardware -----------------------------------------------------------
    $hwBefore = $Previous.hardware; $hwAfter = $Current.hardware
    if ($hwBefore -and $hwAfter) {
        if ($hwBefore.memory -and $hwAfter.memory -and [Math]::Abs([double]$hwAfter.memory.totalGB - [double]$hwBefore.memory.totalGB) -ge 0.5) {
            & $add 'Hardware' 'changed' "RAM: $($hwBefore.memory.totalGB) GB -> $($hwAfter.memory.totalGB) GB" $true
        }
        if ($hwBefore.cpu -and $hwAfter.cpu -and $hwBefore.cpu.name -ne $hwAfter.cpu.name) {
            & $add 'Hardware' 'changed' ("CPU: {0} -> {1}" -f $hwBefore.cpu.name, $hwAfter.cpu.name) $true
        }
        if ($hwBefore.serialNumber -ne $hwAfter.serialNumber) {
            & $add 'Hardware' 'changed' ("Serial number: {0} -> {1} (device or motherboard replaced?)" -f (& $text $hwBefore.serialNumber), (& $text $hwAfter.serialNumber)) $true
        }
        if ($hwBefore.biosVersion -ne $hwAfter.biosVersion) {
            & $add 'Hardware' 'changed' ("BIOS updated: {0} -> {1}" -f (& $text $hwBefore.biosVersion), (& $text $hwAfter.biosVersion)) $false
        }
    }
    if ($Previous.battery -and $Current.battery -and $null -ne $Previous.battery.healthPercent -and $null -ne $Current.battery.healthPercent -and
        ([double]$Previous.battery.healthPercent - [double]$Current.battery.healthPercent) -ge 5) {
        & $add 'Hardware' 'changed' "Battery health: $($Previous.battery.healthPercent)% -> $($Current.battery.healthPercent)%" $false
    }

    # --- Storage ------------------------------------------------------------
    $before = & $index $Previous.storage.volumes 'drive'
    $after = & $index $Current.storage.volumes 'drive'
    foreach ($id in $after.Keys) {
        $volume = $after[$id]
        if (-not $before.Contains($id)) { & $add 'Storage' 'added' "New volume $($volume.drive) ($($volume.sizeGB) GB)" $false; continue }
        $old = $before[$id]
        if ($null -ne $old.usedPercent -and $null -ne $volume.usedPercent -and
            [Math]::Abs([double]$volume.usedPercent - [double]$old.usedPercent) -ge $DiskChangePercent) {
            & $add 'Storage' 'changed' "Drive $($volume.drive) $($old.usedPercent)% -> $($volume.usedPercent)% used" ([double]$volume.usedPercent -ge 90)
        }
        if ($old.bitLocker -ne $volume.bitLocker -and $old.bitLocker -ne 'Unknown' -and $volume.bitLocker -ne 'Unknown') {
            & $add 'Security' 'changed' ("BitLocker on {0}: {1} -> {2}" -f $volume.drive, $old.bitLocker, $volume.bitLocker) ($volume.bitLocker -eq 'Off')
        }
    }
    foreach ($id in $before.Keys) {
        if (-not $after.Contains($id)) { & $add 'Storage' 'removed' "Volume $($before[$id].drive) no longer present" $false }
    }
    $before = & $index $Previous.storage.physical 'name'
    $after = & $index $Current.storage.physical 'name'
    foreach ($id in $after.Keys) {
        if (-not $before.Contains($id)) { & $add 'Storage' 'added' "New disk: $($after[$id].name) ($($after[$id].sizeGB) GB)" $true }
        elseif ($before[$id].healthStatus -ne $after[$id].healthStatus) {
            & $add 'Storage' 'changed' ("Disk {0} health: {1} -> {2}" -f $after[$id].name, $before[$id].healthStatus, $after[$id].healthStatus) ($after[$id].healthStatus -ne 'Healthy')
        }
    }
    foreach ($id in $before.Keys) {
        if (-not $after.Contains($id)) { & $add 'Storage' 'removed' "Disk removed: $($before[$id].name)" $true }
    }

    # --- Windows ------------------------------------------------------------
    $osBefore = $Previous.operatingSystem; $osAfter = $Current.operatingSystem
    if ($osBefore -and $osAfter) {
        if ($osBefore.name -ne $osAfter.name) {
            & $add 'Windows' 'changed' ("Edition: {0} -> {1}" -f $osBefore.name, $osAfter.name) $true
        }
        if ($osBefore.displayVersion -ne $osAfter.displayVersion) {
            & $add 'Windows' 'changed' ("Feature update: {0} -> {1}" -f (& $text $osBefore.displayVersion), (& $text $osAfter.displayVersion)) $false
        }
        elseif ($osBefore.build -ne $osAfter.build) {
            & $add 'Windows' 'changed' ("Update installed: build {0} -> {1}" -f $osBefore.build, $osAfter.build) $false
        }
    }

    # --- Security -----------------------------------------------------------
    $secBefore = $Previous.security; $secAfter = $Current.security
    if ($secBefore -and $secAfter) {
        $before = & $index $secBefore.antivirusProducts 'name'
        $after = & $index $secAfter.antivirusProducts 'name'
        foreach ($id in $after.Keys) {
            if (-not $before.Contains($id)) { & $add 'Security' 'added' "Antivirus installed: $($after[$id].name)" $false }
            elseif ([bool]$before[$id].enabled -ne [bool]$after[$id].enabled) {
                $state = if ($after[$id].enabled) { 'enabled' } else { 'disabled' }
                & $add 'Security' 'changed' "$($after[$id].name) $state" (-not $after[$id].enabled)
            }
        }
        foreach ($id in $before.Keys) {
            if (-not $after.Contains($id)) { & $add 'Security' 'removed' "Antivirus removed: $($before[$id].name)" $true }
        }

        $before = & $index $secBefore.firewall 'profile'
        $after = & $index $secAfter.firewall 'profile'
        foreach ($id in $after.Keys) {
            if ($before.Contains($id) -and [bool]$before[$id].enabled -ne [bool]$after[$id].enabled) {
                $state = if ($after[$id].enabled) { 'enabled' } else { 'disabled' }
                & $add 'Security' 'changed' "Firewall ($($after[$id].profile)) $state" (-not $after[$id].enabled)
            }
        }
        if ($null -ne $secBefore.uacEnabled -and $null -ne $secAfter.uacEnabled -and $secBefore.uacEnabled -ne $secAfter.uacEnabled) {
            $state = if ($secAfter.uacEnabled) { 'enabled' } else { 'disabled' }
            & $add 'Security' 'changed' "UAC $state" (-not $secAfter.uacEnabled)
        }
        if ($null -ne $secBefore.secureBoot -and $null -ne $secAfter.secureBoot -and $secBefore.secureBoot -ne $secAfter.secureBoot) {
            $state = if ($secAfter.secureBoot) { 'enabled' } else { 'disabled' }
            & $add 'Security' 'changed' "Secure Boot $state" (-not $secAfter.secureBoot)
        }

        $before = & $index $secBefore.localAdministrators 'name'
        $after = & $index $secAfter.localAdministrators 'name'
        foreach ($id in $after.Keys) {
            if (-not $before.Contains($id)) { & $add 'Security' 'added' "New local administrator: $($after[$id].name)" $true }
        }
        foreach ($id in $before.Keys) {
            if (-not $after.Contains($id)) { & $add 'Security' 'removed' "No longer a local administrator: $($before[$id].name)" $false }
        }
    }

    # --- Network ------------------------------------------------------------
    $before = & $index $Previous.network 'macAddress'
    $after = & $index $Current.network 'macAddress'
    foreach ($id in $after.Keys) {
        $adapter = $after[$id]
        if (-not $before.Contains($id)) { & $add 'Network' 'added' "New network adapter: $($adapter.description)" $false; continue }
        $oldIp = (@($before[$id].ipv4) -join ', '); $newIp = (@($adapter.ipv4) -join ', ')
        if ($oldIp -ne $newIp) { & $add 'Network' 'changed' ("IP address: {0} -> {1}" -f (& $text $oldIp), (& $text $newIp)) $false }
    }
    foreach ($id in $before.Keys) {
        if (-not $after.Contains($id)) { & $add 'Network' 'removed' "Network adapter removed: $($before[$id].description)" $false }
    }

    # --- Users --------------------------------------------------------------
    if ($Previous.users -and $Current.users -and $Previous.users.lastLoggedOnUser -and $Current.users.lastLoggedOnUser -and
        $Previous.users.lastLoggedOnUser -ne $Current.users.lastLoggedOnUser) {
        & $add 'Users' 'changed' ("Main user: {0} -> {1}" -f $Previous.users.lastLoggedOnUser, $Current.users.lastLoggedOnUser) $false
    }

    # @() over this List fails in Windows PowerShell 5.1 ("argument types do not match")
    return $changes.ToArray()
}

function Get-PCScopeTimeline {
    <#
    .SYNOPSIS
        Compares each snapshot with the next one and returns every change,
        newest first, with the date it was detected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $History,
        [Parameter(Mandatory)] $Current
    )

    $snapshots = @($History) + @($Current)
    $timeline = for ($i = $snapshots.Count - 1; $i -ge 1; $i--) {
        $newer = $snapshots[$i]; $older = $snapshots[$i - 1]
        foreach ($change in Compare-PCScopeInventory -Previous $older -Current $newer) {
            $change | Add-Member -NotePropertyName date -NotePropertyValue $newer.collectedAt -PassThru |
                Add-Member -NotePropertyName since -NotePropertyValue $older.collectedAt -PassThru
        }
    }
    return @($timeline)
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Inventory collection functions for PCScope.

.DESCRIPTION
    Every function in this file is read-only: nothing on the computer is changed.
    Each section is collected independently, so a failure in one of them
    (for example, missing administrator rights) never stops the whole inventory.
    Errors are recorded in the "errors" list of the result instead.
#>

$script:PCScopeVersion = '1.0.0'
$script:PCScopeSchemaVersion = 1

#region Helpers

function ConvertTo-PCScopeIsoDate {
    <#
    .SYNOPSIS
        Converts a date to an ISO 8601 string (Windows PowerShell 5.1 would
        otherwise serialize DateTime values as "\/Date(...)\/").
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(ValueFromPipeline)] $Date)

    process {
        if ($null -eq $Date) { return $null }
        if ($Date -is [string]) {
            # Registry install dates use the yyyyMMdd format
            $parsed = [datetime]::MinValue
            if ($Date -match '^\d{8}$' -and
                [datetime]::TryParseExact($Date, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                return $parsed.ToString('yyyy-MM-dd')
            }
            return $null
        }
        if ($Date -is [datetime]) {
            if ($Date.Year -lt 1990) { return $null }
            return $Date.ToString('yyyy-MM-ddTHH:mm:ss')
        }
        return $null
    }
}

function Get-PCScopeRegistryValue {
    <#
    .SYNOPSIS
        Reads a single registry value and returns $null when it does not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )

    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $null
    }
}

function ConvertTo-PCScopeGB {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)] [double] $Bytes)

    return [Math]::Round($Bytes / 1GB, 1)
}

function ConvertFrom-PCScopeBitLockerState {
    <#
    .SYNOPSIS
        Translates the shell property System.Volume.BitLockerProtection,
        which can be read without administrator rights.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($State)

    switch ([string]$State) {
        '1' { return 'On' }
        '2' { return 'Off' }
        '3' { return 'Encrypting' }
        '4' { return 'Decrypting' }
        '5' { return 'Suspended' }
        '6' { return 'On (locked)' }
        '8' { return 'Waiting for activation' }
        default { return 'Unknown' }
    }
}

function ConvertFrom-PCScopeAntivirusState {
    <#
    .SYNOPSIS
        Decodes the productState bit field reported by Windows Security Center.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $ProductState)

    [ordered]@{
        enabled    = (($ProductState -band 0x1000) -ne 0)
        upToDate   = (($ProductState -band 0x10) -eq 0)
    }
}

function Test-PCScopeElevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#endregion

#region Sections

function Get-PCScopeHardware {
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure | Select-Object -First 1

    # Chassis types that correspond to portable devices
    $portable = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $isLaptop = $false
    foreach ($type in @($enclosure.ChassisTypes)) {
        if ($portable -contains [int]$type) { $isLaptop = $true }
    }

    $totalBytes = [double]$cs.TotalPhysicalMemory
    $freeBytes = [double]$os.FreePhysicalMemory * 1KB

    $modules = @(Get-CimInstance -ClassName Win32_PhysicalMemory | ForEach-Object {
        [ordered]@{
            slot       = $_.DeviceLocator
            capacityGB = ConvertTo-PCScopeGB -Bytes ([double]$_.Capacity)
            speedMHz   = $_.Speed
            vendor     = ([string]$_.Manufacturer).Trim()
        }
    })

    [ordered]@{
        manufacturer = ([string]$cs.Manufacturer).Trim()
        model        = ([string]$cs.Model).Trim()
        serialNumber = ([string]$bios.SerialNumber).Trim()
        biosVersion  = $bios.SMBIOSBIOSVersion
        biosDate     = ConvertTo-PCScopeIsoDate $bios.ReleaseDate
        formFactor   = $(if ($isLaptop) { 'Laptop' } else { 'Desktop' })
        cpu          = [ordered]@{
            name              = ([string]$cpu.Name).Trim()
            cores             = $cpu.NumberOfCores
            logicalProcessors = $cpu.NumberOfLogicalProcessors
            maxClockMHz       = $cpu.MaxClockSpeed
        }
        memory       = [ordered]@{
            totalGB     = ConvertTo-PCScopeGB -Bytes $totalBytes
            freeGB      = ConvertTo-PCScopeGB -Bytes $freeBytes
            usedPercent = [Math]::Round((1.0 - ($freeBytes / $totalBytes)) * 100.0, 0)
            modules     = $modules
        }
    }
}

function Get-PCScopeStorage {
    [CmdletBinding()]
    param()

    $bitLockerStates = @{}
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($volume in Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3') {
            $folder = $shell.NameSpace("$($volume.DeviceID)\")
            if ($folder) {
                $state = $folder.Self.ExtendedProperty('System.Volume.BitLockerProtection')
                $bitLockerStates[$volume.DeviceID] = ConvertFrom-PCScopeBitLockerState $state
            }
        }
    }
    catch {
        Write-Verbose "BitLocker state not available: $($_.Exception.Message)"
    }

    $volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $size = [double]$_.Size
        $free = [double]$_.FreeSpace
        [ordered]@{
            drive       = $_.DeviceID
            label       = $_.VolumeName
            fileSystem  = $_.FileSystem
            sizeGB      = ConvertTo-PCScopeGB -Bytes $size
            freeGB      = ConvertTo-PCScopeGB -Bytes $free
            usedPercent = $(if ($size -gt 0) { [Math]::Round((1.0 - ($free / $size)) * 100.0, 0) } else { $null })
            bitLocker   = $(if ($bitLockerStates.ContainsKey($_.DeviceID)) { $bitLockerStates[$_.DeviceID] } else { 'Unknown' })
        }
    })

    $physical = @()
    if (Get-Command -Name Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $physical = @(Get-PhysicalDisk | ForEach-Object {
            [ordered]@{
                name              = $_.FriendlyName
                mediaType         = [string]$_.MediaType
                busType           = [string]$_.BusType
                sizeGB            = ConvertTo-PCScopeGB -Bytes ([double]$_.Size)
                healthStatus      = [string]$_.HealthStatus
                operationalStatus = (@($_.OperationalStatus) -join ', ')
            }
        })
    }

    [ordered]@{
        volumes  = $volumes
        physical = $physical
    }
}

function Get-PCScopeBattery {
    [CmdletBinding()]
    param()

    $battery = Get-CimInstance -ClassName Win32_Battery | Select-Object -First 1
    if (-not $battery) { return $null }

    $design = $null
    $full = $null
    try {
        $design = (Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction Stop |
            Select-Object -First 1).DesignedCapacity
        $full = (Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop |
            Select-Object -First 1).FullChargedCapacity
    }
    catch {
        Write-Verbose "Battery capacity not available: $($_.Exception.Message)"
    }

    $health = $null
    if ($design -and $full -and $design -gt 0) {
        $health = [Math]::Min(100.0, [Math]::Round(([double]$full / [double]$design) * 100.0, 0))
    }

    [ordered]@{
        chargePercent         = $battery.EstimatedChargeRemaining
        designCapacityMWh     = $design
        fullChargeCapacityMWh = $full
        healthPercent         = $health
    }
}

function Get-PCScopeLastUpdate {
    <#
    .SYNOPSIS
        Returns the most recent successfully installed Windows update (one with
        a KB number), ignoring Defender definition updates (they install daily)
        and Microsoft Store app updates.
    #>
    [CmdletBinding()]
    param()

    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $history = $searcher.QueryHistory(0, [Math]::Min(200, $count))
            $latest = $history |
                Where-Object { $_.Operation -eq 1 -and $_.ResultCode -eq 2 -and
                    $_.Title -match 'KB\d+' -and
                    $_.Title -notmatch 'Defender|Security Intelligence|Antivirus|KB2267602' } |
                Sort-Object -Property Date -Descending |
                Select-Object -First 1
            if ($latest) {
                return [ordered]@{
                    title  = $latest.Title
                    date   = ConvertTo-PCScopeIsoDate $latest.Date.ToLocalTime()
                    source = 'Windows Update history'
                }
            }
        }
    }
    catch {
        Write-Verbose "Windows Update history not available: $($_.Exception.Message)"
    }

    $hotfix = Get-HotFix -ErrorAction SilentlyContinue |
        Where-Object { $_.InstalledOn } |
        Sort-Object -Property InstalledOn -Descending |
        Select-Object -First 1
    if ($hotfix) {
        return [ordered]@{
            title  = $hotfix.HotFixID
            date   = ConvertTo-PCScopeIsoDate $hotfix.InstalledOn
            source = 'Get-HotFix'
        }
    }
    return $null
}

function Get-PCScopePendingReboot {
    [CmdletBinding()]
    param()

    $reasons = New-Object System.Collections.Generic.List[string]
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('Component Based Servicing')
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('Windows Update')
    }
    $renames = Get-PCScopeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
    if ($renames) { $reasons.Add('Pending file rename operations') }

    [ordered]@{
        required = ($reasons.Count -gt 0)
        reasons  = @($reasons)
    }
}

function Get-PCScopeOperatingSystem {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $displayVersion = Get-PCScopeRegistryValue -Path $key -Name 'DisplayVersion'
    if (-not $displayVersion) { $displayVersion = Get-PCScopeRegistryValue -Path $key -Name 'ReleaseId' }
    $currentBuild = Get-PCScopeRegistryValue -Path $key -Name 'CurrentBuild'
    $ubr = Get-PCScopeRegistryValue -Path $key -Name 'UBR'

    $uptime = (Get-Date) - $os.LastBootUpTime

    [ordered]@{
        name           = ([string]$os.Caption).Trim()
        displayVersion = $displayVersion
        build          = $(if ($null -ne $ubr) { "$currentBuild.$ubr" } else { "$currentBuild" })
        architecture   = $os.OSArchitecture
        language       = (Get-Culture).Name
        installDate    = ConvertTo-PCScopeIsoDate $os.InstallDate
        lastBoot       = ConvertTo-PCScopeIsoDate $os.LastBootUpTime
        uptimeDays     = [Math]::Round($uptime.TotalDays, 1)
        domain         = $cs.Domain
        partOfDomain   = [bool]$cs.PartOfDomain
        lastUpdate     = Get-PCScopeLastUpdate
        pendingReboot  = Get-PCScopePendingReboot
    }
}

function Get-PCScopeLocalAdministrator {
    <#
    .SYNOPSIS
        Lists the members of the local Administrators group. The group is
        found by its well-known SID because its name is localized
        ("Administradores", "Administrateurs"...).
    #>
    [CmdletBinding()]
    param()

    $sid = 'S-1-5-32-544'
    if (Get-Command -Name Get-LocalGroupMember -ErrorAction SilentlyContinue) {
        try {
            return @(Get-LocalGroupMember -SID $sid -ErrorAction Stop | ForEach-Object {
                [ordered]@{ name = $_.Name; type = [string]$_.ObjectClass; source = [string]$_.PrincipalSource }
            })
        }
        catch {
            # Fails when the group contains orphaned SIDs; fall back to ADSI
            Write-Verbose "Get-LocalGroupMember failed: $($_.Exception.Message)"
        }
    }

    $groupName = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    $group = [ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group"
    return @($group.Invoke('Members') | ForEach-Object {
        $path = $_.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $_, $null)
        $class = $_.GetType().InvokeMember('Class', 'GetProperty', $null, $_, $null)
        [ordered]@{ name = ($path -replace '^WinNT://', '' -replace '/', '\'); type = $class; source = 'ADSI' }
    })
}

function Get-PCScopeSecurity {
    [CmdletBinding()]
    param()

    $defender = $null
    if (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $defender = [ordered]@{
                serviceEnabled       = [bool]$mp.AMServiceEnabled
                antivirusEnabled     = [bool]$mp.AntivirusEnabled
                realTimeProtection   = [bool]$mp.RealTimeProtectionEnabled
                signatureLastUpdated = ConvertTo-PCScopeIsoDate $mp.AntivirusSignatureLastUpdated
                signatureAgeDays     = $mp.AntivirusSignatureAge
            }
        }
        catch {
            Write-Verbose "Defender status not available: $($_.Exception.Message)"
        }
    }

    $antivirus = @()
    try {
        $antivirus = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntivirusProduct -ErrorAction Stop |
            ForEach-Object {
                $state = ConvertFrom-PCScopeAntivirusState -ProductState ([int]$_.productState)
                [ordered]@{ name = $_.displayName; enabled = $state.enabled; upToDate = $state.upToDate }
            })
    }
    catch {
        Write-Verbose "Security Center not available (Windows Server?): $($_.Exception.Message)"
    }

    $firewall = @()
    if (Get-Command -Name Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
        $firewall = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{ profile = $_.Name; enabled = ([string]$_.Enabled -eq 'True') }
        })
    }

    $policies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $secureBoot = Get-PCScopeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled'

    [ordered]@{
        defender            = $defender
        antivirusProducts   = $antivirus
        firewall            = $firewall
        uacEnabled          = ((Get-PCScopeRegistryValue -Path $policies -Name 'EnableLUA') -eq 1)
        secureBoot          = $(if ($null -eq $secureBoot) { $null } else { $secureBoot -eq 1 })
        localAdministrators = @(Get-PCScopeLocalAdministrator)
    }
}

function Get-PCScopeSoftware {
    <#
    .SYNOPSIS
        Reads installed programs from the registry. Win32_Product is avoided on
        purpose: it is very slow and can trigger MSI repairs.
    #>
    [CmdletBinding()]
    param()

    $sources = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'User' }
    )

    $seen = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($source in $sources) {
        foreach ($entry in Get-ItemProperty -Path $source.Path -ErrorAction SilentlyContinue) {
            $name = [string]$entry.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($entry.SystemComponent -eq 1) { continue }
            if ($entry.ParentKeyName) { continue }   # updates of another product

            $version = [string]$entry.DisplayVersion
            $id = "$name|$version".ToLowerInvariant()
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true

            $result.Add([ordered]@{
                name        = $name.Trim()
                version     = $version.Trim()
                publisher   = ([string]$entry.Publisher).Trim()
                installDate = ConvertTo-PCScopeIsoDate ([string]$entry.InstallDate)
                scope       = $source.Scope
            })
        }
    }

    return @($result | Sort-Object -Property { $_.name })
}

function Get-PCScopeNetwork {
    [CmdletBinding()]
    param()

    @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' | ForEach-Object {
        $addresses = @($_.IPAddress)
        [ordered]@{
            description = $_.Description
            macAddress  = $_.MACAddress
            ipv4        = @($addresses | Where-Object { $_ -notmatch ':' })
            ipv6        = @($addresses | Where-Object { $_ -match ':' })
            gateway     = @($_.DefaultIPGateway | Where-Object { $_ })
            dnsServers  = @($_.DNSServerSearchOrder | Where-Object { $_ })
            dhcpEnabled = [bool]$_.DHCPEnabled
        }
    })
}

function Get-PCScopeUser {
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    [ordered]@{
        currentUser    = $cs.UserName
        lastLoggedOnUser = Get-PCScopeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -Name 'LastLoggedOnUser'
    }
}

#endregion

function Get-PCScopeInventory {
    <#
    .SYNOPSIS
        Collects the full inventory of the local computer.

    .PARAMETER Method
        How the inventory was obtained, recorded in the result: 'local' (run on
        the computer itself) or 'remote' (run through PowerShell remoting).

    .EXAMPLE
        Get-PCScopeInventory | ConvertTo-Json -Depth 8
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('local', 'remote')] [string] $Method = 'local'
    )

    $started = Get-Date
    $errors = New-Object System.Collections.Generic.List[object]

    $sections = [ordered]@{
        hardware        = 'Get-PCScopeHardware'
        storage         = 'Get-PCScopeStorage'
        battery         = 'Get-PCScopeBattery'
        operatingSystem = 'Get-PCScopeOperatingSystem'
        security        = 'Get-PCScopeSecurity'
        network         = 'Get-PCScopeNetwork'
        users           = 'Get-PCScopeUser'
        software        = 'Get-PCScopeSoftware'
    }

    $inventory = [ordered]@{
        schemaVersion = $script:PCScopeSchemaVersion
        computerName  = $env:COMPUTERNAME
        collectedAt   = ConvertTo-PCScopeIsoDate $started
        collector     = [ordered]@{
            version         = $script:PCScopeVersion
            method          = $Method
            runAs           = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            elevated        = Test-PCScopeElevated
            durationSeconds = $null
        }
    }

    foreach ($section in $sections.Keys) {
        Write-Verbose "Collecting $section"
        try {
            $value = & $sections[$section]
            # PowerShell unrolls arrays returned by functions: keep lists as lists
            if (@('network', 'software') -contains $section) { $value = @($value) }
            $inventory[$section] = $value
        }
        catch {
            $inventory[$section] = $null
            $errors.Add([ordered]@{ section = $section; message = $_.Exception.Message })
        }
    }

    $inventory.Add('errors', [object[]]$errors.ToArray())
    $inventory.collector.durationSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    return $inventory
}

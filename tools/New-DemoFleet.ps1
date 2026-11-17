#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a fleet of fictitious devices for the PCScope demo and tests.

.DESCRIPTION
    Writes one JSON inventory per device, with the same schema the collector
    produces. Companies, models, people and serial numbers are invented; the
    software names are real so the dashboard looks realistic. A fixed -Seed
    always produces the same fleet, and dates are relative to -Now so the demo
    never looks stale.

.EXAMPLE
    .\tools\New-DemoFleet.ps1 -OutputPath .\demo\data -Count 25
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $OutputPath,
    [ValidateRange(1, 500)] [int] $Count = 25,
    [int] $Seed = 2026,
    [datetime] $Now = (Get-Date),
    [ValidateRange(0, 20)] [int] $HistorySnapshots = 3
)

$ErrorActionPreference = 'Stop'
$rng = New-Object System.Random($Seed)
# History uses its own generator, so adding or tuning it never changes the current fleet
$historyRng = New-Object System.Random($Seed + 1)
$OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)

function Get-RandomItem([object[]] $Items) { return $Items[$rng.Next($Items.Count)] }
function Test-Chance([double] $Probability) { return ($rng.NextDouble() -lt $Probability) }
# Problems are more likely on "neglected" devices and rare on well-kept ones,
# which gives a believable mix instead of every device having a bit of everything
$script:ProblemFactor = 1.0
function Test-Problem([double] $Probability) { return ($rng.NextDouble() -lt ($Probability * $script:ProblemFactor)) }
function Get-RandomNumber([double] $Min, [double] $Max, [int] $Digits = 0) {
    return [Math]::Round($Min + ($rng.NextDouble() * ($Max - $Min)), $Digits)
}
function Format-Date([datetime] $Date) { return $Date.ToString('yyyy-MM-ddTHH:mm:ss') }

function New-DemoHistory {
    <#
    .SYNOPSIS
        Writes older snapshots of a device, one week apart, by undoing
        plausible changes: updates, installed programs, a fuller disk, a new
        administrator, a RAM upgrade...
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called inside the ShouldProcess block of the script')]
    param([string] $CurrentJson, [string] $Folder, [int] $Snapshots)

    $chance = { param($p) $historyRng.NextDouble() -lt $p }
    $newerJson = $CurrentJson
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null

    for ($k = 1; $k -le $Snapshots; $k++) {
        $older = $newerJson | ConvertFrom-Json
        $collected = ([datetime]$older.collectedAt).AddDays(-7).AddHours(-$historyRng.Next(0, 6))
        $older.collectedAt = Format-Date $collected

        foreach ($volume in @($older.storage.volumes)) {
            $volume.usedPercent = [Math]::Max(10, $volume.usedPercent - $historyRng.Next(1, 7))
            $volume.freeGB = [Math]::Round($volume.sizeGB * (100 - $volume.usedPercent) / 100, 1)
        }
        $update = $older.operatingSystem.lastUpdate
        if ($update -and [datetime]$update.date -gt $collected) {
            # The last update was installed after this older snapshot: undo it
            $parts = ([string]$older.operatingSystem.build).Split('.')
            $older.operatingSystem.build = '{0}.{1}' -f $parts[0], [Math]::Max(1000, [int]$parts[1] - $historyRng.Next(80, 400))
            $update.date = Format-Date ($collected.AddDays(-$historyRng.Next(20, 32)))
            $update.title = $update.title -replace '^\d{4}-\d{2}', ('{0:yyyy-MM}' -f [datetime]$update.date)
        }
        $chrome = @($older.software | Where-Object { $_.name -eq 'Google Chrome' }) | Select-Object -First 1
        if ($chrome -and (& $chance 0.5)) {
            $v = $chrome.version.Split('.')
            $chrome.version = '{0}.0.{1}.{2}' -f ([int]$v[0] - 1), $historyRng.Next(6000, 8000), $historyRng.Next(10, 99)
        }
        # Programs installed after this older snapshot did not exist yet
        $optional = @($older.software | Where-Object { $_.installDate -and [datetime]$_.installDate -gt $collected })
        if ($optional.Count) {
            $installedLater = $optional[$historyRng.Next($optional.Count)].name
            $older.software = @($older.software | Where-Object { $_.name -ne $installedLater })
        }
        if (& $chance 0.12) {
            $older.software = @($older.software) + [pscustomobject]@{ name = 'WinRAR 7.01 (64-bit)'; version = '7.01.0'; publisher = 'win.rar GmbH'; installDate = $null; scope = 'Machine' }
        }
        $admins = @($older.security.localAdministrators)
        if ($admins.Count -gt 2 -and (& $chance 0.7)) {
            $older.security.localAdministrators = @($admins | Select-Object -First 2)
        }
        if ($older.hardware.memory.totalGB -ge 15 -and (& $chance 0.06)) {
            $older.hardware.memory.totalGB = 7.8
        }
        $system = @($older.storage.volumes | Where-Object { $_.drive -eq 'C:' }) | Select-Object -First 1
        if ($older.hardware.formFactor -eq 'Laptop' -and $system -and $system.bitLocker -eq 'On' -and (& $chance 0.15)) {
            $system.bitLocker = 'Off'
        }
        if (& $chance 0.15) {
            $adapter = @($older.network)[0]
            $adapter.ipv4 = @('10.20.{0}.{1}' -f $historyRng.Next(10, 40), $historyRng.Next(20, 200))
        }

        $newerJson = $older | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path $Folder ("{0:yyyyMMdd-HHmmss}.json" -f $collected)), $newerJson, (New-Object Text.UTF8Encoding($false)))
    }
}

$departments = @(
    @{ Code = 'FRONT'; Laptop = 0.1; Software = @('Zoom Workplace') },
    @{ Code = 'ACC';   Laptop = 0.2; Software = @('Contoso Ledger 2026', 'Microsoft Power BI Desktop') },
    @{ Code = 'SALES'; Laptop = 0.9; Software = @('Zoom Workplace', 'Northwind CRM Connector') },
    @{ Code = 'HR';    Laptop = 0.4; Software = @('Zoom Workplace', 'Adobe Acrobat (64-bit)') },
    @{ Code = 'MKT';   Laptop = 0.6; Software = @('Adobe Photoshop 2026', 'Canva', 'VLC media player') },
    @{ Code = 'WH';    Laptop = 0.0; Software = @('Tailspin Label Printer Utility') },
    @{ Code = 'MGMT';  Laptop = 1.0; Software = @('Zoom Workplace', 'Adobe Acrobat (64-bit)') },
    @{ Code = 'IT';    Laptop = 0.5; Software = @('Wireshark 4.4.2 x64', 'PuTTY release 0.83 (64-bit)', 'Notepad++ (64-bit x64)', 'Git') }
)

# Real programs get plausible versions; the rest get random ones
$knownVersions = @{
    'Notepad++ (64-bit x64)'      = '8.8.7'
    'Git'                         = '2.52.0'
    'Wireshark 4.4.2 x64'         = '4.4.2'
    'PuTTY release 0.83 (64-bit)' = '0.83.0.0'
    'VLC media player'            = '3.0.21'
    'Zoom Workplace'              = '6.6.4.11251'
    'Canva'                       = '1.118.0'
    'Adobe Acrobat (64-bit)'      = '25.001.20844'
    'Adobe Photoshop 2026'        = '27.1.0'
    'Microsoft Power BI Desktop'  = '2.149.1203.0'
}

$desktops = @(
    @{ Maker = 'Contoso Computers'; Model = 'OptiDesk 5000' },
    @{ Maker = 'Contoso Computers'; Model = 'OptiDesk 7000 SFF' },
    @{ Maker = 'Northwind Devices'; Model = 'WorkCenter M3 Tower' }
)
$laptops = @(
    @{ Maker = 'Fabrikam'; Model = 'TravelBook 14 G5' },
    @{ Maker = 'Fabrikam'; Model = 'ProBook 15 Gen 3' },
    @{ Maker = 'Tailspin Systems'; Model = 'Ultra 13 Air' }
)
$cpus = @(
    @{ Name = 'Intel(R) Core(TM) i5-12500'; Cores = 6; Threads = 12; Clock = 3000 },
    @{ Name = 'Intel(R) Core(TM) i5-1335U'; Cores = 10; Threads = 12; Clock = 1300 },
    @{ Name = 'Intel(R) Core(TM) i7-1365U'; Cores = 10; Threads = 12; Clock = 1800 },
    @{ Name = 'AMD Ryzen 5 PRO 7530U with Radeon Graphics'; Cores = 6; Threads = 12; Clock = 2000 },
    @{ Name = 'Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz'; Cores = 4; Threads = 8; Clock = 1800 }
)
$firstNames = @('ana', 'luis', 'marta', 'john', 'sofia', 'pierre', 'lucia', 'omar', 'elena', 'kenji', 'paula', 'david', 'irene', 'mateo', 'nora', 'ravi', 'clara', 'hugo', 'laura', 'tomas')
$lastNames = @('garcia', 'smith', 'moreau', 'rossi', 'novak', 'silva', 'tanaka', 'khan', 'lopez', 'meyer', 'ruiz', 'costa')

$windows = @(
    @{ Name = 'Microsoft Windows 11 Pro'; Version = '25H2'; Build = '26200'; Weight = 0.45 },
    @{ Name = 'Microsoft Windows 11 Pro'; Version = '24H2'; Build = '26100'; Weight = 0.35 },
    @{ Name = 'Microsoft Windows 11 Enterprise'; Version = '24H2'; Build = '26100'; Weight = 0.1 },
    @{ Name = 'Microsoft Windows 10 Pro'; Version = '22H2'; Build = '19045'; Weight = 0.1 }
)

$counters = @{}
$usedNames = @{}

for ($i = 0; $i -lt $Count; $i++) {
    $care = $rng.NextDouble()
    $neglected = $care -ge 0.85
    $script:ProblemFactor = if ($care -lt 0.5) { 0.05 } elseif ($neglected) { 2.5 } else { 0.4 }
    $dept = Get-RandomItem $departments
    $isLaptop = Test-Chance $dept.Laptop
    $counters[$dept.Code] = 1 + [int]$counters[$dept.Code]
    $name = '{0}-{1}{2:D2}' -f $dept.Code, $(if ($isLaptop) { 'LT' } else { 'PC' }), $counters[$dept.Code]
    if ($usedNames.ContainsKey($name)) { continue }
    $usedNames[$name] = $true

    $hw = if ($isLaptop) { Get-RandomItem $laptops } else { Get-RandomItem $desktops }
    $cpu = Get-RandomItem $cpus
    $old = Test-Problem 0.2          # older machine: smaller disk, less RAM
    $user = '{0}.{1}' -f (Get-RandomItem $firstNames), (Get-RandomItem $lastNames)

    # Windows version, weighted
    $roll = $rng.NextDouble(); $acc = 0.0; $win = $windows[0]
    foreach ($candidate in $windows) { $acc += $candidate.Weight; if ($roll -lt $acc) { $win = $candidate; break } }
    if ($win.Build -eq '19045' -and -not $neglected) { $win = $windows[1] }   # only neglected devices still run Windows 10

    $ramGB = if ($old) { Get-RandomItem @(4, 8) } else { Get-RandomItem @(16, 16, 32) }
    $usedRam = Get-RandomNumber 35 85
    $diskGB = if ($old) { 237.9 } else { Get-RandomItem @(476.3, 476.3, 953.3) }
    $diskUsed = if (Test-Problem 0.15) { Get-RandomNumber 91 98 } elseif (Test-Problem 0.15) { Get-RandomNumber 81 89 } else { Get-RandomNumber 25 75 }
    $diskHealthy = -not (Test-Problem 0.06)

    $collectedAt = if (Test-Problem 0.08) { $Now.AddDays(-(Get-RandomNumber 9 20)) } else { $Now.AddHours(-(Get-RandomNumber 1 30)) }
    $uptime = if (Test-Problem 0.2) { Get-RandomNumber 15 45 1 } else { Get-RandomNumber 0.2 6 1 }
    $updateAge = if (Test-Problem 0.12) { Get-RandomNumber 61 150 } elseif (Test-Problem 0.12) { Get-RandomNumber 31 59 } else { Get-RandomNumber 2 25 }
    if ($win.Build -eq '19045') { $updateAge = [Math]::Max($updateAge, 90) }
    $lastUpdate = $collectedAt.AddDays(-$updateAge)

    $avActive = -not (Test-Problem 0.07)
    $sigAge = if ($avActive -and (Test-Problem 0.08)) { Get-RandomNumber 9 40 } else { Get-RandomNumber 0 1 }
    $thirdParty = Test-Chance 0.2
    $antivirus = @([ordered]@{ name = 'Windows Defender'; enabled = ($avActive -and -not $thirdParty); upToDate = ($sigAge -le 7) })
    if ($thirdParty) { $antivirus += [ordered]@{ name = 'Contoso Endpoint Security'; enabled = $avActive; upToDate = $true } }

    $admins = @([ordered]@{ name = "$name\Administrator"; type = 'User'; source = 'Local' },
        [ordered]@{ name = 'CONTOSO\Domain Admins'; type = 'Group'; source = 'ActiveDirectory' })
    if (Test-Problem 0.15) { $admins += [ordered]@{ name = "CONTOSO\$user"; type = 'User'; source = 'ActiveDirectory' } }

    $chrome = if (Test-Problem 0.15) { '14{0}.0.{1}.{2}' -f $rng.Next(0, 9), $rng.Next(6000, 7000), $rng.Next(10, 99) } else { '15{0}.0.{1}.{2}' -f $rng.Next(5, 8), $rng.Next(7000, 8000), $rng.Next(10, 99) }
    $sevenZip = if (Test-Problem 0.15) { '23.01' } else { '24.09' }
    $catalog = @(
        @('Google Chrome', $chrome, 'Google LLC'),
        @('Microsoft 365 Apps for business - en-us', '16.0.19127.20264', 'Microsoft Corporation'),
        @('Microsoft Teams', '25290.205.4069.4894', 'Microsoft Corporation'),
        @("7-Zip $sevenZip (x64)", $sevenZip, 'Igor Pavlov'),
        @('Adobe Acrobat Reader (64-bit)', '25.001.20844', 'Adobe'),
        @('Microsoft Edge WebView2 Runtime', '142.0.3595.80', 'Microsoft Corporation')
    )
    foreach ($extra in $dept.Software) {
        $version = if ($knownVersions.ContainsKey($extra)) { $knownVersions[$extra] } else { '{0}.{1}.{2}' -f $rng.Next(1, 30), $rng.Next(0, 10), $rng.Next(0, 500) }
        $catalog += , @($extra, $version, 'Various')
    }
    if (Test-Problem 0.08) { $catalog += , @('uTorrent', '3.6.0.47196', 'BitTorrent Inc.') }
    if (Test-Problem 0.15) { $catalog += , @('Mozilla Firefox (x64 en-US)', ('13{0}.0.1' -f $rng.Next(0, 9)), 'Mozilla') }
    $software = @($catalog | Sort-Object { $_[0] } | ForEach-Object {
        [ordered]@{ name = $_[0]; version = $_[1]; publisher = $_[2]; installDate = $Now.AddDays(-$rng.Next(10, 700)).ToString('yyyy-MM-dd'); scope = 'Machine' }
    })

    $volumes = @([ordered]@{
        drive = 'C:'; label = ''; fileSystem = 'NTFS'; sizeGB = $diskGB
        freeGB = [Math]::Round($diskGB * (100 - $diskUsed) / 100, 1); usedPercent = $diskUsed
        bitLocker = $(if ($isLaptop -and (Test-Problem 0.25)) { 'Off' } elseif ($isLaptop -or (Test-Chance 0.5)) { 'On' } else { 'Off' })
    })

    $battery = $null
    if ($isLaptop) {
        $design = Get-RandomItem @(45000, 52000, 56000)
        $health = if ($old -or (Test-Problem 0.15)) { Get-RandomNumber 42 70 } else { Get-RandomNumber 78 99 }
        $battery = [ordered]@{ chargePercent = $rng.Next(20, 100); designCapacityMWh = $design; fullChargeCapacityMWh = [int]($design * $health / 100); healthPercent = $health }
    }

    $ip = '10.20.{0}.{1}' -f $(if ($isLaptop) { 30 } else { 10 }), (20 + $i)
    $pending = Test-Chance 0.25
    $errors = @()
    if (Test-Problem 0.05) { $errors += [ordered]@{ section = 'battery'; message = 'Access denied' } }

    $inventory = [ordered]@{
        schemaVersion = 1
        computerName  = $name
        collectedAt   = Format-Date $collectedAt
        collector     = $(
            # Most devices report through the scheduled task, the rest were collected remotely by IT
            $viaTask = Test-Chance 0.7
            [ordered]@{
                version = '1.0.0'; method = $(if ($viaTask) { 'local' } else { 'remote' })
                runAs = $(if ($viaTask) { 'NT AUTHORITY\SYSTEM' } else { 'CONTOSO\it.admin' })
                elevated = $true; durationSeconds = (Get-RandomNumber 3 9 1)
            })
        hardware      = [ordered]@{
            manufacturer = $hw.Maker; model = $hw.Model; serialNumber = ('DEMO{0:D6}' -f $rng.Next(1, 999999))
            biosVersion = ('1.{0}.{1}' -f $rng.Next(1, 30), $rng.Next(0, 9)); biosDate = Format-Date ($Now.AddDays(-$rng.Next(200, 1500)).Date)
            formFactor = $(if ($isLaptop) { 'Laptop' } else { 'Desktop' })
            cpu = [ordered]@{ name = $cpu.Name; cores = $cpu.Cores; logicalProcessors = $cpu.Threads; maxClockMHz = $cpu.Clock }
            memory = [ordered]@{
                totalGB = [Math]::Round($ramGB - 0.2, 1); freeGB = [Math]::Round($ramGB * (100 - $usedRam) / 100, 1); usedPercent = $usedRam
                modules = @([ordered]@{ slot = 'DIMM1'; capacityGB = $ramGB; speedMHz = $(if ($old) { 2400 } else { 4800 }); vendor = 'Fabrikam Memory' })
            }
        }
        storage       = [ordered]@{
            volumes  = $volumes
            physical = @([ordered]@{
                name = $(if ($old) { 'Generic SATA SSD 256GB' } else { 'Fabrikam NVMe SSD' }); mediaType = 'SSD'; busType = $(if ($old) { 'SATA' } else { 'NVMe' })
                sizeGB = [Math]::Round($diskGB + 0.6, 1); healthStatus = $(if ($diskHealthy) { 'Healthy' } else { 'Warning' })
                operationalStatus = $(if ($diskHealthy) { 'OK' } else { 'Predictive Failure' })
            })
        }
        battery       = $battery
        operatingSystem = [ordered]@{
            name = $win.Name; displayVersion = $win.Version; build = ('{0}.{1}' -f $win.Build, $rng.Next(1000, 7000)); architecture = '64-bit'; language = 'en-US'
            installDate = Format-Date ($Now.AddDays(-$rng.Next(100, 1200))); lastBoot = Format-Date ($collectedAt.AddDays(-$uptime)); uptimeDays = $uptime
            domain = 'contoso.local'; partOfDomain = $true
            lastUpdate = [ordered]@{ title = ('{0:yyyy-MM} Cumulative Update for {1} (KB5{2:D6})' -f $lastUpdate, ($win.Name -replace 'Microsoft ', ''), $rng.Next(0, 999999)); date = Format-Date $lastUpdate; source = 'Windows Update history' }
            pendingReboot = [ordered]@{ required = $pending; reasons = @($(if ($pending) { 'Windows Update' })) }
        }
        security      = [ordered]@{
            defender = [ordered]@{ serviceEnabled = $true; antivirusEnabled = ($avActive -and -not $thirdParty); realTimeProtection = ($avActive -and -not $thirdParty); signatureLastUpdated = Format-Date ($collectedAt.AddDays(-$sigAge)); signatureAgeDays = $sigAge }
            antivirusProducts = $antivirus
            firewall = @('Domain', 'Private', 'Public' | ForEach-Object { [ordered]@{ profile = $_; enabled = -not ($_ -eq 'Public' -and (Test-Problem 0.08)) } })
            uacEnabled = -not (Test-Problem 0.03)
            secureBoot = -not $old
            localAdministrators = $admins
        }
        network       = @([ordered]@{
            description = $(if ($isLaptop) { 'Intel(R) Wi-Fi 6E AX211 160MHz' } else { 'Intel(R) Ethernet Connection I219-LM' })
            macAddress = ('02:00:5E:{0:X2}:{1:X2}:{2:X2}' -f $rng.Next(256), $rng.Next(256), $rng.Next(256))
            ipv4 = @($ip); ipv6 = @(); gateway = @('10.20.0.1'); dnsServers = @('10.20.0.10', '10.20.0.11'); dhcpEnabled = $true
        })
        users         = [ordered]@{ currentUser = "CONTOSO\$user"; lastLoggedOnUser = "CONTOSO\$user" }
        software      = $software
        errors        = $errors
    }

    if (-not (Test-Path -Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $file = Join-Path $OutputPath "$name.json"
    if ($PSCmdlet.ShouldProcess($file, 'Write demo inventory')) {
        $currentJson = $inventory | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($file, $currentJson, (New-Object Text.UTF8Encoding($false)))
        if ($HistorySnapshots -gt 0) {
            New-DemoHistory -CurrentJson $currentJson -Folder (Join-Path $OutputPath "history\$name") -Snapshots $HistorySnapshots
        }
    }
}

Write-Verbose "Generated $($usedNames.Count) demo devices in $OutputPath"

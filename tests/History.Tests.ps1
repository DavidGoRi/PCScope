#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Report.ps1')   # also loads History.ps1 and Rules.ps1
    $fixtureText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\OFFICE-PC01.json'))

    function Get-Fixture { return $fixtureText | ConvertFrom-Json }
    function ConvertTo-Snapshot($Inventory, [string] $CollectedAt) {
        $Inventory.collectedAt = $CollectedAt
        return ($Inventory | ConvertTo-Json -Depth 8)
    }
    function Get-Change($Previous, $Current) { return @(Compare-PCScopeInventory -Previous $Previous -Current $Current) }
}

Describe 'Save-PCScopeInventory' {
    BeforeEach {
        $data = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }

    It 'saves the first inventory without history' {
        $file = Save-PCScopeInventory -Json (ConvertTo-Snapshot (Get-Fixture) '2026-11-01T09:00:00') -DataPath $data
        $file | Should -Exist
        Join-Path $data 'history' | Should -Not -Exist
    }

    It 'archives the previous inventory, named by its collection date' {
        Save-PCScopeInventory -Json (ConvertTo-Snapshot (Get-Fixture) '2026-11-01T09:00:00') -DataPath $data | Out-Null
        Save-PCScopeInventory -Json (ConvertTo-Snapshot (Get-Fixture) '2026-11-08T09:00:00') -DataPath $data | Out-Null
        Join-Path $data 'history\OFFICE-PC01\20261101-090000.json' | Should -Exist
        ([IO.File]::ReadAllText((Join-Path $data 'OFFICE-PC01.json')) | ConvertFrom-Json).collectedAt | Should -Be '2026-11-08T09:00:00'
    }

    It 'does not archive the same collection twice' {
        $json = ConvertTo-Snapshot (Get-Fixture) '2026-11-01T09:00:00'
        Save-PCScopeInventory -Json $json -DataPath $data | Out-Null
        Save-PCScopeInventory -Json $json -DataPath $data | Out-Null
        Join-Path $data 'history' | Should -Not -Exist
    }

    It 'keeps only the newest -HistoryLimit snapshots' {
        foreach ($day in 1..6) {
            Save-PCScopeInventory -Json (ConvertTo-Snapshot (Get-Fixture) ('2026-11-{0:D2}T09:00:00' -f $day)) -DataPath $data -HistoryLimit 3 | Out-Null
        }
        $names = @(Get-ChildItem -Path (Join-Path $data 'history\OFFICE-PC01') -Filter '*.json' | Sort-Object Name | ForEach-Object { $_.BaseName })
        $names | Should -Be @('20261103-090000', '20261104-090000', '20261105-090000')
    }

    It 'keeps no history with -HistoryLimit 0' {
        Save-PCScopeInventory -Json (ConvertTo-Snapshot (Get-Fixture) '2026-11-01T09:00:00') -DataPath $data -HistoryLimit 0 | Out-Null
        Save-PCScopeInventory -Json (ConvertTo-Snapshot (Get-Fixture) '2026-11-08T09:00:00') -DataPath $data -HistoryLimit 0 | Out-Null
        Join-Path $data 'history' | Should -Not -Exist
    }

    It 'returns the history oldest first' {
        foreach ($day in 3, 1, 2, 4) {
            $folder = Join-Path $data 'history\OFFICE-PC01'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -Path (Join-Path $folder ('202611{0:D2}-090000.json' -f $day)) -Value (ConvertTo-Snapshot (Get-Fixture) ('2026-11-{0:D2}T09:00:00' -f $day))
        }
        $device = 'OFFICE-PC01'
        $history = @(Get-PCScopeHistory -DataPath $data -ComputerName $device -Depth 3)
        $history.collectedAt | Should -Be @('2026-11-02T09:00:00', '2026-11-03T09:00:00', '2026-11-04T09:00:00')
    }
}

Describe 'Compare-PCScopeInventory' {
    It 'finds nothing between identical inventories' {
        Get-Change (Get-Fixture) (Get-Fixture) | Should -HaveCount 0
    }

    It 'detects installed, updated and uninstalled programs' {
        $old = Get-Fixture; $new = Get-Fixture
        $new.software = @($new.software | Where-Object { $_.name -notlike '7-Zip*' }) +
            [pscustomobject]@{ name = 'VLC media player'; version = '3.0.21'; publisher = 'VideoLAN'; installDate = $null; scope = 'Machine' }
        ($new.software | Where-Object name -eq 'Google Chrome').version = '153.0.7500.10'

        $messages = (Get-Change $old $new).message
        $messages | Should -Contain 'Installed VLC media player 3.0.21'
        $messages | Should -Contain 'Google Chrome: 152.0.7444.60 -> 153.0.7500.10'
        $messages | Should -Contain 'Uninstalled 7-Zip 24.08 (x64)'
    }

    It 'flags a RAM change as notable' {
        $old = Get-Fixture; $new = Get-Fixture
        $new.hardware.memory.totalGB = 32
        $change = Get-Change $old $new
        $change.message | Should -Be 'RAM: 16 GB -> 32 GB'
        $change.notable | Should -BeTrue
    }

    It 'flags a new local administrator as notable' {
        $old = Get-Fixture; $new = Get-Fixture
        $new.security.localAdministrators = @($new.security.localAdministrators) + [pscustomobject]@{ name = 'CONTOSO\intern'; type = 'User'; source = 'ActiveDirectory' }
        $change = Get-Change $old $new
        $change.message | Should -Be 'New local administrator: CONTOSO\intern'
        $change.notable | Should -BeTrue
    }

    It 'flags security being weakened, but not strengthened' {
        $old = Get-Fixture; $new = Get-Fixture
        ($new.security.firewall | Where-Object profile -eq 'Public').enabled = $false
        $weakened = Get-Change $old $new
        $weakened.message | Should -Be 'Firewall (Public) disabled'
        $weakened.notable | Should -BeTrue

        (Get-Change $new $old).notable | Should -BeFalse
    }

    It 'reports Windows updates and feature upgrades' {
        $old = Get-Fixture; $new = Get-Fixture
        $new.operatingSystem.build = '26100.4100'
        (Get-Change $old $new).message | Should -Be 'Update installed: build 26100.4000 -> 26100.4100'

        $new.operatingSystem.displayVersion = '25H2'
        (Get-Change $old $new).message | Should -Be 'Feature update: 24H2 -> 25H2'
    }

    It 'reports disk usage changes only above the threshold' {
        $old = Get-Fixture; $new = Get-Fixture
        $new.storage.volumes[0].usedPercent = 59
        Get-Change $old $new | Should -HaveCount 0

        $new.storage.volumes[0].usedPercent = 63
        (Get-Change $old $new).message | Should -Be 'Drive C: 56% -> 63% used'
    }

    It 'formats numbers the same whatever the system language' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'es-ES'
            $old = Get-Fixture; $new = Get-Fixture
            $old.hardware.memory.totalGB = 7.8
            (Get-Change $old $new).message | Should -Be 'RAM: 7.8 GB -> 16 GB'
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
    }

    It 'reports IP and main user changes' {
        $old = Get-Fixture; $new = Get-Fixture
        $new.network[0].ipv4 = @('10.0.0.99')
        $new.users.lastLoggedOnUser = 'CONTOSO\luis.lopez'
        $messages = (Get-Change $old $new).message
        $messages | Should -Contain 'IP address: 10.0.0.21 -> 10.0.0.99'
        $messages | Should -Contain 'Main user: CONTOSO\ana.garcia -> CONTOSO\luis.lopez'
    }
}

Describe 'Get-PCScopeTimeline' {
    It 'lists changes newest first, with the date they were detected' {
        $first = Get-Fixture; $first.collectedAt = '2026-11-01T09:00:00'
        $second = Get-Fixture; $second.collectedAt = '2026-11-08T09:00:00'; $second.operatingSystem.build = '26100.4100'
        $third = Get-Fixture; $third.collectedAt = '2026-11-15T09:00:00'; $third.operatingSystem.build = '26100.4100'; $third.hardware.memory.totalGB = 32

        $timeline = @(Get-PCScopeTimeline -History @($first, $second) -Current $third)
        $timeline | Should -HaveCount 2
        $timeline[0].date | Should -Be '2026-11-15T09:00:00'
        $timeline[0].message | Should -Be 'RAM: 16 GB -> 32 GB'
        $timeline[1].since | Should -Be '2026-11-01T09:00:00'
    }
}

Describe 'Dashboard and CSV with history' {
    BeforeAll {
        $data = Join-Path $TestDrive 'fleet'
        Save-PCScopeInventory -Json (ConvertTo-Snapshot (Get-Fixture) '2026-11-01T09:00:00') -DataPath $data | Out-Null
        $newer = Get-Fixture; $newer.hardware.memory.totalGB = 32
        Save-PCScopeInventory -Json (ConvertTo-Snapshot $newer '2026-11-08T09:00:00') -DataPath $data | Out-Null
        $now = [datetime]'2026-11-09T12:00:00'
    }

    It 'embeds the changes in the dashboard' {
        $report = New-PCScopeReport -DataPath $data -OutputFile (Join-Path $TestDrive 'report.html') -Now $now
        $html = [IO.File]::ReadAllText($report.FullName)
        $html | Should -Not -Match '/\*PCSCOPE_CHANGES\*/'
        # ConvertTo-Json escapes '>' as a unicode sequence; the browser shows it as '->'
        $html | Should -Match 'RAM: 16 GB -\S+ 32 GB'
    }

    It 'does not show archived snapshots as extra devices' {
        $fleet = @(Get-PCScopeFleet -DataPath $data -RuleSet (Get-PCScopeRuleSet -Path (Join-Path $root 'rules.json')) -Now $now)
        $fleet | Should -HaveCount 1
    }

    Context 'Export-PCScopeCsv' {
        BeforeAll {
            $out = Join-Path $TestDrive 'export'
            $files = @(Export-PCScopeCsv -DataPath $data -OutputPath $out -Delimiter ',' -Now $now)
        }

        It 'creates the four files' {
            $files.Name | Should -Be @('devices.csv', 'issues.csv', 'software.csv', 'changes.csv')
        }

        It 'writes one row per device with its main data' {
            $rows = @(Import-Csv -Path (Join-Path $out 'devices.csv'))
            $rows | Should -HaveCount 1
            $rows[0].Device | Should -Be 'OFFICE-PC01'
            $rows[0].Status | Should -Be 'ok'
            $rows[0].RamGB | Should -Be '32'
        }

        It 'writes one row per installed program' {
            @(Import-Csv -Path (Join-Path $out 'software.csv')) | Should -HaveCount 3
        }

        It 'exports the changes' {
            (Import-Csv -Path (Join-Path $out 'changes.csv')).Change | Should -Be 'RAM: 16 GB -> 32 GB'
        }

        It 'writes UTF-8 with BOM so Excel shows accents correctly' {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $out 'devices.csv'))
            $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        }

        It 'creates an empty file when there is nothing to export' {
            Join-Path $out 'issues.csv' | Should -Exist
        }
    }
}

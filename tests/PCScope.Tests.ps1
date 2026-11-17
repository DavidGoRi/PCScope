#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Collector.ps1')
    . (Join-Path $root 'src\Report.ps1')
    $fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'Helpers' {
    Context 'ConvertTo-PCScopeIsoDate' {
        It 'formats DateTime values as ISO 8601' {
            ConvertTo-PCScopeIsoDate ([datetime]'2026-03-28 15:07:48') | Should -Be '2026-03-28T15:07:48'
        }
        It 'converts registry yyyyMMdd strings' {
            ConvertTo-PCScopeIsoDate '20240115' | Should -Be '2024-01-15'
        }
        It 'returns $null for invalid or empty values' {
            ConvertTo-PCScopeIsoDate 'not a date' | Should -BeNullOrEmpty
            ConvertTo-PCScopeIsoDate $null | Should -BeNullOrEmpty
            ConvertTo-PCScopeIsoDate ([datetime]'1601-01-01') | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertFrom-PCScopeBitLockerState' {
        It 'maps <State> to <Expected>' -ForEach @(
            @{ State = 1; Expected = 'On' }
            @{ State = 2; Expected = 'Off' }
            @{ State = 5; Expected = 'Suspended' }
            @{ State = $null; Expected = 'Unknown' }
        ) {
            ConvertFrom-PCScopeBitLockerState $State | Should -Be $Expected
        }
    }

    Context 'ConvertFrom-PCScopeAntivirusState' {
        It 'decodes an enabled, up-to-date product (397568)' {
            $state = ConvertFrom-PCScopeAntivirusState -ProductState 397568
            $state.enabled | Should -BeTrue
            $state.upToDate | Should -BeTrue
        }
        It 'decodes a disabled product (393472)' {
            (ConvertFrom-PCScopeAntivirusState -ProductState 393472).enabled | Should -BeFalse
        }
        It 'detects outdated definitions (397584)' {
            (ConvertFrom-PCScopeAntivirusState -ProductState 397584).upToDate | Should -BeFalse
        }
    }
}

Describe 'Get-PCScopeInventory' -Tag 'Integration' {
    BeforeAll {
        $inventory = Get-PCScopeInventory
        $roundTrip = $inventory | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    }

    It 'includes every section' {
        foreach ($key in 'schemaVersion', 'computerName', 'collectedAt', 'collector', 'hardware', 'storage',
            'operatingSystem', 'security', 'network', 'users', 'software', 'errors') {
            $inventory.Contains($key) | Should -BeTrue -Because "'$key' is part of the schema"
        }
    }

    It 'collects without errors' {
        $inventory.errors | Should -HaveCount 0
    }

    It 'identifies the local computer' {
        $inventory.computerName | Should -Be $env:COMPUTERNAME
    }

    It 'serializes dates as ISO strings, not /Date()/' {
        $roundTrip.collectedAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
        ($inventory | ConvertTo-Json -Depth 8) | Should -Not -Match '\\/Date\('
    }

    It 'keeps lists as JSON arrays even with a single item' {
        $json = $inventory | ConvertTo-Json -Depth 8
        $json | Should -Match '"network":\s*\['
        $json | Should -Match '"software":\s*\['
    }

    It 'reports at least one volume with sensible numbers' {
        $inventory.storage.volumes.Count | Should -BeGreaterThan 0
        foreach ($volume in $inventory.storage.volumes) {
            $volume.usedPercent | Should -BeGreaterOrEqual 0
            $volume.usedPercent | Should -BeLessOrEqual 100
        }
    }

    It 'reads installed software with names' {
        foreach ($program in $inventory.software) {
            $program.name | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'New-PCScopeReport' {
    BeforeAll {
        $out = Join-Path $TestDrive 'report.html'
        $report = New-PCScopeReport -DataPath $fixtures -OutputFile $out
        $html = [IO.File]::ReadAllText($out)
    }

    It 'creates the HTML file' {
        $report.FullName | Should -Exist
    }

    It 'embeds every device' {
        $html | Should -Match 'OFFICE-PC01'
        $html | Should -Match 'SALES-LT07'
    }

    It 'replaces all template placeholders' {
        $html | Should -Not -Match '\{\{[A-Z_]+\}\}'
        $html | Should -Not -Match '/\*PCSCOPE_DATA\*/'
    }

    It 'escapes data that could break out of the script tag' {
        $html | Should -Not -Match '</script><b>'
        $html.Contains([string][char]92 + 'u003c/script>') | Should -BeTrue
    }

    It 'skips invalid JSON files with a warning' {
        $data = Join-Path $TestDrive 'data'
        New-Item -ItemType Directory -Path $data | Out-Null
        Copy-Item -Path (Join-Path $fixtures 'OFFICE-PC01.json') -Destination $data
        Set-Content -Path (Join-Path $data 'broken.json') -Value '{ not json'

        $result = New-PCScopeReport -DataPath $data -OutputFile (Join-Path $TestDrive 'r2.html') -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -Not -BeNullOrEmpty
        $warnings | Should -HaveCount 1
    }

    It 'fails clearly when the data folder does not exist' {
        { New-PCScopeReport -DataPath (Join-Path $TestDrive 'missing') -OutputFile (Join-Path $TestDrive 'x.html') } |
            Should -Throw '*not found*'
    }
}

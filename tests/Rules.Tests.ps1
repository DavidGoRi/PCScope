#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Rules.ps1')
    $rulesPath = Join-Path $root 'rules.json'
    $now = [datetime]'2026-11-17T12:00:00'

    function Read-Fixture([string] $Name) {
        return [IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures\$Name.json")) | ConvertFrom-Json
    }
    # A fresh copy of the default rules that each test can modify freely
    function Get-DefaultRuleSet { return Get-PCScopeRuleSet -Path $rulesPath }
}

Describe 'Get-PCScopeRuleSet' {
    It 'loads the default rules file' {
        $ruleSet = Get-DefaultRuleSet
        $ruleSet.rules.diskSpace.criticalPercent | Should -Be 90
    }

    It 'accepts a path relative to the current location' {
        Push-Location -Path $root
        try { (Get-PCScopeRuleSet -Path '.\rules.json').rules | Should -Not -BeNullOrEmpty }
        finally { Pop-Location }
    }

    It 'rejects an invalid level' {
        $file = Join-Path $TestDrive 'bad.json'
        Set-Content -Path $file -Value '{ "rules": { "uac": { "enabled": true, "level": "urgent" } } }'
        { Get-PCScopeRuleSet -Path $file } | Should -Throw '*invalid level*'
    }

    It 'rejects a file without rules' {
        $file = Join-Path $TestDrive 'empty.json'
        Set-Content -Path $file -Value '{ "description": "nothing here" }'
        { Get-PCScopeRuleSet -Path $file } | Should -Throw "*no 'rules' section*"
    }
}

Describe 'ConvertTo-PCScopeVersion' {
    It 'parses "<Text>" as <Expected>' -ForEach @(
        @{ Text = '131.0.6778.86'; Expected = '131.0.6778.86' }
        @{ Text = '24.08'; Expected = '24.8' }
        @{ Text = '8.6.2 (64-bit)'; Expected = '8.6.2' }
        @{ Text = '26'; Expected = '26.0' }
    ) {
        (ConvertTo-PCScopeVersion $Text).ToString() | Should -Be $Expected
    }

    It 'returns $null for text without a version' {
        ConvertTo-PCScopeVersion 'latest' | Should -BeNullOrEmpty
    }
}

Describe 'Get-PCScopeIssue' {
    Context 'Healthy device' {
        It 'finds no issues' {
            $issues = @(Get-PCScopeIssue -Inventory (Read-Fixture 'OFFICE-PC01') -RuleSet (Get-DefaultRuleSet) -Now $now)
            $issues | Should -HaveCount 0
            Get-PCScopeStatus -Issue $issues | Should -Be 'ok'
        }
    }

    Context 'Device with many problems' {
        BeforeAll {
            $issues = @(Get-PCScopeIssue -Inventory (Read-Fixture 'SALES-LT07') -RuleSet (Get-DefaultRuleSet) -Now $now)
            $levelOf = @{}
            foreach ($issue in $issues) { $levelOf[$issue.rule] = $issue.level }
        }

        It 'raises <Rule> as <Level>' -ForEach @(
            @{ Rule = 'diskSpace'; Level = 'critical' }
            @{ Rule = 'diskHealth'; Level = 'critical' }
            @{ Rule = 'antivirus'; Level = 'critical' }
            @{ Rule = 'windowsUpdates'; Level = 'critical' }
            @{ Rule = 'unsupportedWindows'; Level = 'critical' }
            @{ Rule = 'firewall'; Level = 'warning' }
            @{ Rule = 'laptopEncryption'; Level = 'warning' }
            @{ Rule = 'batteryHealth'; Level = 'warning' }
            @{ Rule = 'localAdministrators'; Level = 'warning' }
            @{ Rule = 'outdatedSoftware'; Level = 'warning' }
            @{ Rule = 'pendingReboot'; Level = 'info' }
            @{ Rule = 'uptime'; Level = 'info' }
            @{ Rule = 'collectionErrors'; Level = 'info' }
        ) {
            $levelOf[$Rule] | Should -Be $Level
        }

        It 'does not flag software that is not in the blocked list' {
            $levelOf.ContainsKey('blockedSoftware') | Should -BeFalse
        }

        It 'lists the most severe issues first' {
            $order = @{ critical = 3; warning = 2; info = 1 }
            for ($i = 1; $i -lt $issues.Count; $i++) {
                $order[$issues[$i].level] | Should -BeLessOrEqual $order[$issues[$i - 1].level]
            }
        }

        It 'names the unexpected administrator only' {
            ($issues | Where-Object rule -eq 'localAdministrators').message | Should -Be 'Unexpected local administrators: SALES-LT07\sales'
        }

        It 'reports a critical status' {
            Get-PCScopeStatus -Issue $issues | Should -Be 'critical'
        }
    }

    Context 'Configuration' {
        It 'skips a disabled rule' {
            $ruleSet = Get-DefaultRuleSet
            $ruleSet.rules.diskSpace.enabled = $false
            $issues = @(Get-PCScopeIssue -Inventory (Read-Fixture 'SALES-LT07') -RuleSet $ruleSet -Now $now)
            $issues.rule | Should -Not -Contain 'diskSpace'
        }

        It 'uses the configured thresholds' {
            $ruleSet = Get-DefaultRuleSet
            $ruleSet.rules.diskSpace.criticalPercent = 97
            $issue = Get-PCScopeIssue -Inventory (Read-Fixture 'SALES-LT07') -RuleSet $ruleSet -Now $now |
                Where-Object rule -eq 'diskSpace'
            $issue.level | Should -Be 'warning'
        }

        It 'detects blocked software by pattern' {
            $ruleSet = Get-DefaultRuleSet
            $ruleSet.rules.blockedSoftware.patterns = @('TeamViewer')
            $issue = Get-PCScopeIssue -Inventory (Read-Fixture 'SALES-LT07') -RuleSet $ruleSet -Now $now |
                Where-Object rule -eq 'blockedSoftware'
            $issue.message | Should -Be 'Unapproved software installed: TeamViewer 15.40.8'
        }

        It 'flags an old inventory as stale' {
            $issues = @(Get-PCScopeIssue -Inventory (Read-Fixture 'OFFICE-PC01') -RuleSet (Get-DefaultRuleSet) -Now $now.AddDays(30))
            $issues.rule | Should -Contain 'staleInventory'
        }

        It 'works with a rules file that only defines some rules' {
            $ruleSet = '{ "rules": { "uac": { "level": "critical" } } }' | ConvertFrom-Json
            $issues = @(Get-PCScopeIssue -Inventory (Read-Fixture 'SALES-LT07') -RuleSet $ruleSet -Now $now)
            $issues | Should -HaveCount 0
        }
    }
}

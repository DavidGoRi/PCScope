#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Report.ps1')
    . (Join-Path $root 'src\Alert.ps1')
    $now = [datetime]'2026-11-17T12:00:00'
    $fleet = @(Get-PCScopeFleet -DataPath (Join-Path $PSScriptRoot 'fixtures') -RuleSet (Get-PCScopeRuleSet -Path (Join-Path $root 'rules.json')) -Now $now)
    $config = [pscustomobject]@{
        title = 'Test office'; minLevel = 'critical'; includeNotableChanges = $true
        telegram = [pscustomobject]@{ enabled = $true; chatId = '42' }
        email = [pscustomobject]@{ enabled = $false }
    }
}

Describe 'Get-PCScopeAlert' {
    It 'includes only critical issues by default' {
        $alerts = @(Get-PCScopeAlert -Fleet $fleet)
        $alerts.Count | Should -BeGreaterThan 0
        $alerts.Kind | Sort-Object -Unique | Should -Be 'critical'
        $alerts.Device | Sort-Object -Unique | Should -Be 'SALES-LT07'
    }

    It 'includes warnings with -MinLevel warning' {
        @(Get-PCScopeAlert -Fleet $fleet -MinLevel warning).Kind | Should -Contain 'warning'
    }

    It 'includes notable changes from the latest collection only' {
        $device = [pscustomobject]@{
            Name = 'PC01'; Issues = @(); Inventory = [pscustomobject]@{ collectedAt = '2026-11-17T09:00:00' }
            Changes = @(
                [pscustomobject]@{ date = '2026-11-17T09:00:00'; message = 'New local administrator: X'; notable = $true }
                [pscustomobject]@{ date = '2026-11-10T09:00:00'; message = 'RAM: 8 GB -> 16 GB'; notable = $true }
                [pscustomobject]@{ date = '2026-11-17T09:00:00'; message = 'Installed VLC'; notable = $false }
            )
        }
        (Get-PCScopeAlert -Fleet @($device) -IncludeNotableChanges).Message | Should -Be 'New local administrator: X'
    }
}

Describe 'Select-PCScopeNewAlert' {
    BeforeAll {
        $a = [pscustomobject]@{ Key = 'issue|PC1|uac|x' }
        $b = [pscustomobject]@{ Key = 'issue|PC2|diskSpace|y' }
    }

    It 'returns only alerts not sent before' {
        (Select-PCScopeNewAlert -Alert @($a, $b) -SentKey @('issue|PC1|uac|x')).New.Key | Should -Be 'issue|PC2|diskSpace|y'
    }

    It 'forgets fixed issues so they alert again if they come back' {
        (Select-PCScopeNewAlert -Alert @($b) -SentKey @('issue|PC1|uac|x')).State | Should -Be @('issue|PC2|diskSpace|y')
    }

    It 'remembers change alerts so they are never repeated' {
        (Select-PCScopeNewAlert -Alert @() -SentKey @('change|PC1|2026|RAM')).State | Should -Be @('change|PC1|2026|RAM')
    }
}

Describe 'Invoke-PCScopeAlert' {
    BeforeAll {
        Mock Send-PCScopeTelegram { }
        Mock Send-PCScopeMail { }
        $env:PCSCOPE_TELEGRAM_TOKEN = 'test-token'
        $state = Join-Path $TestDrive 'alerts-state.json'
        $first = @(Invoke-PCScopeAlert -Fleet $fleet -Config $config -StatePath $state)
        $second = @(Invoke-PCScopeAlert -Fleet $fleet -Config $config -StatePath $state)
    }
    AfterAll { Remove-Item Env:\PCSCOPE_TELEGRAM_TOKEN -ErrorAction SilentlyContinue }

    It 'sends the alerts once through Telegram' {
        $first.Count | Should -BeGreaterThan 0
        Should -Invoke Send-PCScopeTelegram -Scope Describe -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq '42' -and $Token -eq 'test-token' -and $Text -like 'Test office - * new alert(s)*SALES-LT07*[CRITICAL]*'
        }
    }

    It 'does not repeat them on the next run' {
        $second | Should -HaveCount 0
    }

    It 'does not use disabled channels' {
        Should -Invoke Send-PCScopeMail -Scope Describe -Times 0 -Exactly
    }

    It 'fails clearly when the Telegram token is missing' {
        Remove-Item Env:\PCSCOPE_TELEGRAM_TOKEN
        { Invoke-PCScopeAlert -Fleet $fleet -Config $config -StatePath (Join-Path $TestDrive 'other.json') } | Should -Throw '*PCSCOPE_TELEGRAM_TOKEN*'
    }
}

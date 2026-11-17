#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $generator = Join-Path $root 'tools\New-DemoFleet.ps1'
    . (Join-Path $root 'src\Report.ps1')
    $now = [datetime]'2026-11-17T12:00:00'

    $first = Join-Path $TestDrive 'first'
    $second = Join-Path $TestDrive 'second'
    & $generator -OutputPath $first -Count 25 -Seed 2026 -Now $now
    & $generator -OutputPath $second -Count 25 -Seed 2026 -Now $now
    $files = @(Get-ChildItem -Path $first -Filter '*.json')
}

Describe 'New-DemoFleet' {
    It 'creates one file per device' {
        $files | Should -HaveCount 25
    }

    It 'is deterministic for the same seed and date' {
        foreach ($file in $files) {
            $copy = Join-Path $second $file.Name
            [IO.File]::ReadAllText($copy) | Should -BeExactly ([IO.File]::ReadAllText($file.FullName))
        }
    }

    It 'follows the same schema as the collector' {
        $expected = @([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\OFFICE-PC01.json')) | ConvertFrom-Json |
            ForEach-Object { $_.PSObject.Properties.Name })
        foreach ($file in $files) {
            $actual = @([IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json | ForEach-Object { $_.PSObject.Properties.Name })
            $actual | Should -Be $expected
        }
    }

    It 'produces a believable mix of healthy and unhealthy devices' {
        $ruleSet = Get-PCScopeRuleSet -Path (Join-Path $root 'rules.json')
        $status = foreach ($file in $files) {
            $inventory = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            Get-PCScopeStatus -Issue @(Get-PCScopeIssue -Inventory $inventory -RuleSet $ruleSet -Now $now)
        }
        @($status | Where-Object { $_ -eq 'ok' }).Count | Should -BeGreaterThan 5
        @($status | Where-Object { $_ -eq 'critical' }).Count | Should -BeGreaterThan 0
    }

    It 'builds a dashboard from the generated data' {
        $report = New-PCScopeReport -DataPath $first -OutputFile (Join-Path $TestDrive 'demo.html') -Now $now
        $report.Length | Should -BeGreaterThan 20KB
    }
}

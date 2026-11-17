#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Task.ps1')
}

Describe 'Get-PCScopeTaskArgument' {
    It 'runs PCScope hidden, without a profile and only collecting' {
        $argument = Get-PCScopeTaskArgument -InstallPath 'C:\ProgramData\PCScope' -OutputPath '\\fileserver\it\pcscope'
        $argument | Should -BeLike '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\PCScope\PCScope.ps1"*'
        $argument | Should -BeLike '*-OutputPath "\\fileserver\it\pcscope" -NoReport'
    }

    It 'rejects paths with quotes, which would break the command line' {
        { Get-PCScopeTaskArgument -InstallPath 'C:\x' -OutputPath 'C:\a" -Evil "b' } | Should -Throw '*quotes*'
    }
}

Describe 'New-PCScopeTaskTrigger' {
    It 'creates a <Schedule> trigger with a <Delay> delay' -ForEach @(
        @{ Schedule = 'Daily'; Class = 'MSFT_TaskDailyTrigger'; Property = 'RandomDelay'; Delay = 'PT30M' }
        @{ Schedule = 'AtStartup'; Class = 'MSFT_TaskBootTrigger'; Property = 'Delay'; Delay = 'PT10M' }
        @{ Schedule = 'AtLogon'; Class = 'MSFT_TaskLogonTrigger'; Property = 'Delay'; Delay = 'PT10M' }
    ) {
        $trigger = New-PCScopeTaskTrigger -Schedule $Schedule
        $trigger.CimClass.CimClassName | Should -Be $Class
        $trigger.$Property | Should -Be $Delay
    }
}

Describe 'Install-PCScopeTask' {
    BeforeAll {
        Mock Register-ScheduledTask { }
        Mock Test-PCScopeElevated { $true }
        $install = Join-Path $TestDrive 'PCScope'
        $result = Install-PCScopeTask -OutputPath '\\fileserver\it\pcscope' -InstallPath $install -At '10:15'
    }

    It 'copies only the files needed to run' {
        foreach ($file in 'PCScope.ps1', 'rules.json', 'src\Collector.ps1', 'src\Rules.ps1', 'src\Report.ps1', 'src\report-template.html') {
            Join-Path $install $file | Should -Exist
        }
        Join-Path $install 'tests' | Should -Not -Exist
        Join-Path $install 'tools' | Should -Not -Exist
    }

    It 'registers the task as SYSTEM with elevated rights' {
        Should -Invoke Register-ScheduledTask -Scope Describe -Times 1 -Exactly -ParameterFilter {
            $TaskPath -eq '\PCScope\' -and $Principal.UserId -like '*SYSTEM' -and $Principal.RunLevel -eq 'Highest'
        }
    }

    It 'points the task at the installed copy and the shared folder' {
        Should -Invoke Register-ScheduledTask -Scope Describe -ParameterFilter {
            $Action.Execute -eq 'powershell.exe' -and
            $Action.Arguments -like "*$install\PCScope.ps1*" -and
            $Action.Arguments -like '*\\fileserver\it\pcscope*'
        }
    }

    It 'limits the run time and never runs twice at once' {
        Should -Invoke Register-ScheduledTask -Scope Describe -ParameterFilter {
            $Settings.ExecutionTimeLimit -eq 'PT15M' -and $Settings.MultipleInstances -eq 'IgnoreNew'
        }
    }

    It 'describes what it installed' {
        $result.Schedule | Should -Be 'Daily at 10:15 (+ up to 30 min)'
        $result.RunsAs | Should -Be 'SYSTEM'
    }

    It 'requires administrator rights' {
        Mock Test-PCScopeElevated { $false }
        { Install-PCScopeTask -OutputPath '\\fileserver\it\pcscope' -InstallPath (Join-Path $TestDrive 'x') } |
            Should -Throw '*elevated*'
    }

    It 'rejects a relative output path' {
        { Install-PCScopeTask -OutputPath 'data' -InstallPath (Join-Path $TestDrive 'y') } | Should -Throw '*absolute path or a UNC share*'
    }

    It 'changes nothing with -WhatIf' {
        $target = Join-Path $TestDrive 'whatif'
        Install-PCScopeTask -OutputPath '\\fileserver\it\pcscope' -InstallPath $target -WhatIf | Out-Null
        $target | Should -Not -Exist
        Should -Invoke Register-ScheduledTask -Scope Describe -Times 1 -Exactly   # still only the call from BeforeAll
    }
}

Describe 'Uninstall-PCScopeTask' {
    BeforeAll {
        Mock Test-PCScopeElevated { $true }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'PCScope inventory' } }
        Mock Unregister-ScheduledTask { }
        $install = Join-Path $TestDrive 'installed'
        New-Item -ItemType Directory -Path $install | Out-Null
        Set-Content -Path (Join-Path $install 'PCScope.ps1') -Value '# placeholder'
        Uninstall-PCScopeTask -InstallPath $install
    }

    It 'removes the task' {
        Should -Invoke Unregister-ScheduledTask -Scope Describe -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\PCScope\' }
    }

    It 'removes the installed files' {
        $install | Should -Not -Exist
    }

    It 'refuses to delete a folder that is not a PCScope installation' {
        $other = Join-Path $TestDrive 'other'
        New-Item -ItemType Directory -Path $other | Out-Null
        Uninstall-PCScopeTask -InstallPath $other
        $other | Should -Exist
    }
}

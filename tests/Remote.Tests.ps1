#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeDiscovery {
    # Real remoting needs WinRM listening on this computer (GitHub's Windows runners have it)
    $winRmAvailable = $false
    try { Test-WSMan -ComputerName localhost -ErrorAction Stop | Out-Null; $winRmAvailable = $true } catch { $winRmAvailable = $false }
}

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Collector.ps1')
    . (Join-Path $root 'src\Remote.ps1')
    $fixtureJson = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\OFFICE-PC01.json'))

    function ConvertTo-RemoteResponse([string] $Text, [string] $Computer) {
        # Invoke-Command tags every result with the computer it came from
        return Add-Member -InputObject $Text -NotePropertyName PSComputerName -NotePropertyValue $Computer -PassThru
    }
}

Describe 'Get-PCScopeComputerList' {
    It 'ignores comments, blank lines and duplicates' {
        $file = Join-Path $TestDrive 'computers.txt'
        Set-Content -Path $file -Value @('# Office', 'PC01', '', '  PC02  # reception', 'PC01', '#PC03')
        Get-PCScopeComputerList -Path $file | Should -Be @('PC01', 'PC02')
    }

    It 'fails clearly when the file does not exist' {
        { Get-PCScopeComputerList -Path (Join-Path $TestDrive 'missing.txt') } | Should -Throw '*not found*'
    }
}

Describe 'ConvertTo-PCScopeFileName' {
    It 'keeps normal names' {
        ConvertTo-PCScopeFileName 'SALES-LT07' | Should -Be 'SALES-LT07'
    }
    It 'replaces characters that are not valid in file names' {
        ConvertTo-PCScopeFileName '..\evil/name:1' | Should -Be '.._evil_name_1'
    }
}

Describe 'Remote script block' {
    It 'loads the collector from source and returns JSON marked as remote' {
        $source = [IO.File]::ReadAllText((Join-Path $root 'src\Collector.ps1'))
        $inventory = & $script:PCScopeRemoteScript $source | ConvertFrom-Json
        $inventory.computerName | Should -Be $env:COMPUTERNAME
        $inventory.collector.method | Should -Be 'remote'
    }
}

Describe 'Invoke-PCScopeRemoteCollection' {
    BeforeAll {
        Mock Invoke-Command {
            ConvertTo-RemoteResponse -Text $fixtureJson -Computer 'pc01.contoso.local'
            ConvertTo-RemoteResponse -Text 'this is not json' -Computer 'PC02'
            Write-Error -Message 'Connecting to remote server PC03 failed: WinRM cannot complete the operation.' -TargetObject 'PC03'
        }
        $data = Join-Path $TestDrive 'data'
        $results = @(Invoke-PCScopeRemoteCollection -ComputerName 'pc01.contoso.local', 'PC02', 'PC03', 'PC04' -DataPath $data)
    }

    It 'returns one result per requested computer, in order' {
        $results.ComputerName | Should -Be @('pc01.contoso.local', 'PC02', 'PC03', 'PC04')
    }

    It 'saves successful inventories named after the device' {
        $results[0].Status | Should -Be 'OK'
        $results[0].Device | Should -Be 'OFFICE-PC01'
        Join-Path $data 'OFFICE-PC01.json' | Should -Exist
    }

    It 'reports invalid responses' {
        $results[1].Status | Should -Be 'Failed'
        $results[1].Message | Should -BeLike 'Invalid response*'
    }

    It 'reports connection errors with their message' {
        $results[2].Status | Should -Be 'Failed'
        $results[2].Message | Should -BeLike '*WinRM cannot complete*'
    }

    It 'reports computers that did not answer at all' {
        $results[3].Message | Should -Be 'No response'
    }

    It 'contacts all computers in one parallel call' {
        Should -Invoke Invoke-Command -Scope Describe -Times 1 -Exactly
    }

    It 'only writes files for valid inventories' {
        @(Get-ChildItem -Path $data -Filter '*.json') | Should -HaveCount 1
    }
}

Describe 'Real remoting against this computer' -Tag 'Remoting' -Skip:(-not $winRmAvailable) {
    It 'collects localhost over WinRM' {
        $result = Invoke-PCScopeRemoteCollection -ComputerName 'localhost' -DataPath (Join-Path $TestDrive 'real')
        $result.Status | Should -Be 'OK' -Because $result.Message
        $result.Device | Should -Be $env:COMPUTERNAME
    }
}

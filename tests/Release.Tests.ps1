#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Variables set in BeforeAll are used inside It blocks, which the analyzer cannot see
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester scoping')]
param()

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $build = & (Join-Path $root 'tools\Build-Release.ps1') -OutputPath (Join-Path $TestDrive 'dist')
    $extracted = Join-Path $TestDrive 'extracted'
    Expand-Archive -Path $build.Zip -DestinationPath $extracted
    $package = Join-Path $extracted "PCScope-$($build.Version)"
}

Describe 'Release package' {
    It 'is named after the version in Collector.ps1' {
        $build.Version | Should -Match '^\d+\.\d+\.\d+$'
        Split-Path -Path $build.Zip -Leaf | Should -Be "PCScope-$($build.Version).zip"
    }

    It 'has a CHANGELOG section for that version' {
        [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md')) | Should -Match ('(?m)^## \[' + [regex]::Escape($build.Version) + '\]')
    }

    It 'publishes a checksum that matches the zip' {
        $line = [IO.File]::ReadAllText("$($build.Zip).sha256")
        $line | Should -BeLike "$((Get-FileHash -Path $build.Zip -Algorithm SHA256).Hash.ToLowerInvariant())  PCScope-*.zip*"
    }

    It 'contains every source file' {
        foreach ($source in Get-ChildItem -Path (Join-Path $root 'src') -File) {
            Join-Path $package "src\$($source.Name)" | Should -Exist
        }
    }

    It 'uses standard "/" separators inside the zip' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($build.Zip)
        try { @($archive.Entries | Where-Object { $_.FullName.Contains('\') }) | Should -HaveCount 0 }
        finally { $archive.Dispose() }
    }

    It 'leaves out tests and screenshots' {
        Join-Path $package 'tests' | Should -Not -Exist
        Join-Path $package 'docs' | Should -Not -Exist
    }

    It 'works once extracted' {
        $out = Join-Path $TestDrive 'run'
        & (Join-Path $package 'tools\New-DemoFleet.ps1') -OutputPath (Join-Path $out 'data') -Count 3 -HistorySnapshots 1
        & (Join-Path $package 'PCScope.ps1') -OutputPath $out -ReportOnly -ExportCsv 6>$null | Out-Null
        Join-Path $out 'report.html' | Should -Exist
        Join-Path $out 'export\devices.csv' | Should -Exist
    }
}

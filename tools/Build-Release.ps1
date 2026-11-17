#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the release zip: PCScope-<version>.zip plus its SHA-256 checksum.

.DESCRIPTION
    The zip contains only what is needed to use PCScope (scripts, rules,
    alert example, tools and documentation), not the tests or screenshots.
    The version is read from src\Collector.ps1. Used by the Release workflow
    and can be run locally.

.EXAMPLE
    .\tools\Build-Release.ps1 -OutputPath .\dist
#>
[CmdletBinding()]
param([string] $OutputPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'dist'))

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent

$match = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'src\Collector.ps1')), "PCScopeVersion = '(\d+\.\d+\.\d+)'")
if (-not $match.Success) { throw 'Version not found in src\Collector.ps1' }
$version = $match.Groups[1].Value

$OutputPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputPath)
$staging = Join-Path $OutputPath "PCScope-$version"
if (Test-Path -Path $staging) { Remove-Item -Path $staging -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $staging 'src'), (Join-Path $staging 'tools') -Force | Out-Null

$files = @('PCScope.ps1', 'rules.json', 'alerts.example.json', 'LICENSE', 'README.md', 'README.es.md', 'CHANGELOG.md',
    'tools\Install-PCScopeTask.ps1', 'tools\New-DemoFleet.ps1')
foreach ($file in $files) { Copy-Item -Path (Join-Path $root $file) -Destination (Join-Path $staging $file) }
Copy-Item -Path (Join-Path $root 'src\*') -Destination (Join-Path $staging 'src')

$zip = Join-Path $OutputPath "PCScope-$version.zip"
if (Test-Path -Path $zip) { Remove-Item -Path $zip -Force }
# Compress-Archive (and ZipFile.CreateFromDirectory, under the compatibility
# settings of powershell.exe) write "\" inside zip paths, which breaks other
# tools. Adding each entry with an explicit "/" name avoids it.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in Get-ChildItem -Path $staging -Recurse -File) {
        $entry = "PCScope-$version/" + $item.FullName.Substring($staging.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $item.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally { $archive.Dispose() }
Remove-Item -Path $staging -Recurse -Force

$hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$hash  PCScope-$version.zip`n", (New-Object Text.UTF8Encoding($false)))

[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash }

#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the self-contained HTML dashboard from the collected JSON files.

.DESCRIPTION
    The dashboard is a single HTML file with the data embedded, so it can be
    opened straight from disk or a network share: no web server, no internet
    connection and no external libraries are needed.
#>

function New-PCScopeReport {
    <#
    .SYNOPSIS
        Creates the dashboard from every *.json inventory found in a folder.

    .EXAMPLE
        New-PCScopeReport -DataPath .\output\data -OutputFile .\output\report.html
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)] [string] $DataPath,
        [Parameter(Mandatory)] [string] $OutputFile,
        [string] $TemplatePath = (Join-Path $PSScriptRoot 'report-template.html'),
        [string] $Title = 'PCScope'
    )

    if (-not (Test-Path -Path $DataPath -PathType Container)) {
        throw "Data folder not found: $DataPath"
    }

    $documents = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -Path $DataPath -Filter '*.json' -File | Sort-Object -Property Name) {
        $raw = [IO.File]::ReadAllText($file.FullName).Trim()
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            if (-not $parsed.computerName) { throw 'missing computerName' }
            $documents.Add($raw)
        }
        catch {
            Write-Warning "Skipping $($file.Name): not a valid PCScope inventory ($($_.Exception.Message))"
        }
    }

    # '<' can only appear inside JSON strings, so replacing it with its JSON
    # unicode escape (backslash + u003c) is always safe and prevents a value
    # such as "</script>" from breaking the page.
    $lessThanEscape = [string][char]92 + 'u003c'
    $json = ('[' + ($documents -join ',') + ']').Replace('<', $lessThanEscape)

    $template = [IO.File]::ReadAllText($TemplatePath)
    $html = $template.
        Replace('/*PCSCOPE_DATA*/[]', $json).
        Replace('{{TITLE}}', [Net.WebUtility]::HtmlEncode($Title)).
        Replace('{{GENERATED_AT}}', (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'))

    # Resolve against the PowerShell location, not the process working directory
    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($OutputFile)
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Write dashboard')) { return }

    $folder = Split-Path -Path $fullPath -Parent
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    [IO.File]::WriteAllText($fullPath, $html, (New-Object Text.UTF8Encoding($false)))

    Write-Verbose "Report created with $($documents.Count) device(s): $fullPath"
    return Get-Item -Path $fullPath
}

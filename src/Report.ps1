#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the self-contained HTML dashboard from the collected JSON files.

.DESCRIPTION
    The dashboard is a single HTML file with the data embedded, so it can be
    opened straight from disk or a network share: no web server, no internet
    connection and no external libraries are needed.

    Health rules (rules.json) are evaluated here, in PowerShell, and only the
    resulting issues are embedded. The page just displays them.
#>

. (Join-Path $PSScriptRoot 'Rules.ps1')

function ConvertTo-PCScopeScriptJson {
    <#
    .SYNOPSIS
        Makes JSON safe to embed inside a <script> element.
    .DESCRIPTION
        '<' can only appear inside JSON strings, so replacing it with its JSON
        unicode escape (backslash + u003c) never changes the data and prevents
        a value such as "</script>" from breaking or injecting into the page.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Json)

    $lessThanEscape = [string][char]92 + 'u003c'
    return $Json.Replace('<', $lessThanEscape)
}

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
        [string] $RulesPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'rules.json'),
        [string] $TemplatePath = (Join-Path $PSScriptRoot 'report-template.html'),
        [string] $Title = 'PCScope',
        [datetime] $Now = (Get-Date)
    )

    if (-not (Test-Path -Path $DataPath -PathType Container)) {
        throw "Data folder not found: $DataPath"
    }
    $ruleSet = Get-PCScopeRuleSet -Path $RulesPath

    $documents = New-Object System.Collections.Generic.List[string]
    $issuesByDevice = [ordered]@{}
    foreach ($file in Get-ChildItem -Path $DataPath -Filter '*.json' -File | Sort-Object -Property Name) {
        $raw = [IO.File]::ReadAllText($file.FullName).Trim()
        try {
            $inventory = $raw | ConvertFrom-Json -ErrorAction Stop
            if (-not $inventory.computerName) { throw 'missing computerName' }
        }
        catch {
            Write-Warning "Skipping $($file.Name): not a valid PCScope inventory ($($_.Exception.Message))"
            continue
        }
        $documents.Add($raw)
        $issuesByDevice[[string]$inventory.computerName] = [object[]]@(Get-PCScopeIssue -Inventory $inventory -RuleSet $ruleSet -Now $Now)
    }

    $devicesJson = ConvertTo-PCScopeScriptJson ('[' + ($documents -join ',') + ']')
    $issuesJson = ConvertTo-PCScopeScriptJson (ConvertTo-Json -InputObject $issuesByDevice -Depth 5 -Compress)

    $template = [IO.File]::ReadAllText($TemplatePath)
    $html = $template.
        Replace('/*PCSCOPE_DATA*/[]', $devicesJson).
        Replace('/*PCSCOPE_ISSUES*/{}', $issuesJson).
        Replace('{{TITLE}}', [Net.WebUtility]::HtmlEncode($Title)).
        Replace('{{GENERATED_AT}}', $Now.ToString('yyyy-MM-ddTHH:mm:ss'))

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

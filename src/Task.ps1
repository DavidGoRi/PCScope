#Requires -Version 5.1
<#
.SYNOPSIS
    Installs PCScope as a scheduled task so each computer reports by itself.

.DESCRIPTION
    The task copies PCScope to a local folder and runs it as SYSTEM, so it
    works even when nobody is logged on and collects the details that need
    administrator rights. Each run writes the computer's JSON to a shared
    folder; the IT team then builds the dashboard with -ReportOnly.

    Running as SYSTEM, the computer accesses the share with its own computer
    account (DOMAIN\NAME$), so the share must allow "Domain Computers" to write.
#>

. (Join-Path $PSScriptRoot 'Collector.ps1')   # Test-PCScopeElevated

$script:PCScopeTaskPath = '\PCScope\'

function Get-PCScopeTaskArgument {
    <#
    .SYNOPSIS
        Builds the powershell.exe command line the task runs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $InstallPath,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    foreach ($value in $InstallPath, $OutputPath) {
        if ($value.Contains('"')) { throw "Paths cannot contain quotes: $value" }
    }
    $script = Join-Path $InstallPath 'PCScope.ps1'
    return ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -OutputPath "{1}" -NoReport' -f $script, $OutputPath)
}

function New-PCScopeTaskTrigger {
    <#
    .SYNOPSIS
        Creates the task trigger. A random delay spreads the runs so that a
        whole office does not write to the share at the same second.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only builds an object')]
    [CmdletBinding()]
    param(
        [ValidateSet('Daily', 'AtStartup', 'AtLogon')] [string] $Schedule = 'Daily',
        [datetime] $At = [datetime]'09:30'
    )

    if ($Schedule -eq 'Daily') {
        return New-ScheduledTaskTrigger -Daily -At $At -RandomDelay (New-TimeSpan -Minutes 30)
    }

    # Boot and logon triggers silently ignore -RandomDelay; their equivalent
    # is the Delay property (ISO 8601 duration), set directly
    $trigger = if ($Schedule -eq 'AtStartup') { New-ScheduledTaskTrigger -AtStartup } else { New-ScheduledTaskTrigger -AtLogOn }
    $trigger.Delay = 'PT10M'
    return $trigger
}

function Install-PCScopeTask {
    <#
    .SYNOPSIS
        Copies PCScope to -InstallPath and registers the scheduled task.

    .EXAMPLE
        Install-PCScopeTask -OutputPath \\fileserver\it\pcscope -Schedule Daily -At 10:00
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $OutputPath,
        [ValidateSet('Daily', 'AtStartup', 'AtLogon')] [string] $Schedule = 'Daily',
        [datetime] $At = [datetime]'09:30',
        [string] $InstallPath = (Join-Path $env:ProgramData 'PCScope'),
        [string] $TaskName = 'PCScope inventory',
        [string] $SourcePath = (Split-Path -Path $PSScriptRoot -Parent)
    )

    if (-not $WhatIfPreference -and -not (Test-PCScopeElevated)) {
        throw 'Installing the scheduled task requires an elevated PowerShell (Run as administrator).'
    }
    if ($OutputPath -notmatch '^\\\\' -and -not [IO.Path]::IsPathRooted($OutputPath)) {
        throw "OutputPath must be an absolute path or a UNC share, not '$OutputPath'."
    }

    # Only what is needed to run: no tests, docs or demo tools
    $files = @('PCScope.ps1', 'rules.json', 'src\Collector.ps1', 'src\History.ps1', 'src\Remote.ps1', 'src\Rules.ps1', 'src\Report.ps1', 'src\report-template.html')
    if ($PSCmdlet.ShouldProcess($InstallPath, 'Copy PCScope files')) {
        New-Item -ItemType Directory -Path (Join-Path $InstallPath 'src') -Force | Out-Null
        foreach ($file in $files) {
            Copy-Item -Path (Join-Path $SourcePath $file) -Destination (Join-Path $InstallPath $file) -Force
        }
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-PCScopeTaskArgument -InstallPath $InstallPath -OutputPath $OutputPath)
    $trigger = New-PCScopeTaskTrigger -Schedule $Schedule -At $At
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew

    if ($PSCmdlet.ShouldProcess("$script:PCScopeTaskPath$TaskName", 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $TaskName -TaskPath $script:PCScopeTaskPath -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force `
            -Description "PCScope read-only inventory. Writes to $OutputPath. https://github.com/DavidGoRi/PCScope" | Out-Null
    }

    [pscustomobject][ordered]@{
        TaskName    = "$script:PCScopeTaskPath$TaskName"
        Schedule    = $(if ($Schedule -eq 'Daily') { 'Daily at {0:HH:mm} (+ up to 30 min)' -f $At } else { $Schedule })
        InstallPath = $InstallPath
        OutputPath  = $OutputPath
        RunsAs      = 'SYSTEM'
    }
}

function Uninstall-PCScopeTask {
    <#
    .SYNOPSIS
        Removes the scheduled task and the local copy of PCScope. Collected
        data in the shared folder is left untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $InstallPath = (Join-Path $env:ProgramData 'PCScope'),
        [string] $TaskName = 'PCScope inventory'
    )

    if (-not $WhatIfPreference -and -not (Test-PCScopeElevated)) {
        throw 'Removing the scheduled task requires an elevated PowerShell (Run as administrator).'
    }

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $script:PCScopeTaskPath -ErrorAction SilentlyContinue
    if ($task -and $PSCmdlet.ShouldProcess("$script:PCScopeTaskPath$TaskName", 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $script:PCScopeTaskPath -Confirm:$false
    }
    if ((Test-Path -Path (Join-Path $InstallPath 'PCScope.ps1')) -and $PSCmdlet.ShouldProcess($InstallPath, 'Delete PCScope files')) {
        Remove-Item -Path $InstallPath -Recurse -Force
    }
}

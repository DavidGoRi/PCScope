#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or removes) the PCScope scheduled task on this computer.

.DESCRIPTION
    Copies PCScope to C:\ProgramData\PCScope and registers a task that runs it
    as SYSTEM and saves this computer's inventory to a shared folder. Run it
    from an elevated PowerShell, or deploy it to many computers with a Group
    Policy startup script or your management tool.

    The share must let the computer accounts write: for example, give
    "Domain Computers" Modify permission on \\fileserver\it\pcscope\data.

.EXAMPLE
    .\tools\Install-PCScopeTask.ps1 -OutputPath \\fileserver\it\pcscope

.EXAMPLE
    .\tools\Install-PCScopeTask.ps1 -OutputPath \\fileserver\it\pcscope -Schedule AtStartup -WhatIf

.EXAMPLE
    .\tools\Install-PCScopeTask.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')]
    [string] $OutputPath,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Daily', 'AtStartup', 'AtLogon')]
    [string] $Schedule = 'Daily',

    [Parameter(ParameterSetName = 'Install')]
    [datetime] $At = [datetime]'09:30',

    [string] $InstallPath = (Join-Path $env:ProgramData 'PCScope'),

    [Parameter(Mandatory, ParameterSetName = 'Uninstall')]
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'src\Task.ps1')

if ($Uninstall) {
    Uninstall-PCScopeTask -InstallPath $InstallPath
    if (-not $WhatIfPreference) {
        Write-Host 'PCScope task removed. Data already collected in the shared folder was not touched.'
    }
    return
}

$result = Install-PCScopeTask -OutputPath $OutputPath -Schedule $Schedule -At $At -InstallPath $InstallPath
if (-not $WhatIfPreference) {
    Write-Host 'PCScope task installed:'
    $result | Format-List | Out-Host
    Write-Host "Run it now with: Start-ScheduledTask -TaskPath '\PCScope\' -TaskName 'PCScope inventory'"
}

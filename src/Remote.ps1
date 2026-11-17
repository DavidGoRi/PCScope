#Requires -Version 5.1
<#
.SYNOPSIS
    Collects inventories from other computers over PowerShell remoting (WinRM).

.DESCRIPTION
    Nothing has to be installed on the target computers: the collector source
    code is sent with the request, run there, and only the resulting JSON comes
    back. Invoke-Command contacts the computers in parallel.

    Requirements on the targets: PowerShell remoting enabled (on by default on
    Windows Server; on clients use Enable-PSRemoting or a Group Policy) and an
    account that is allowed to connect (local Administrators or Remote
    Management Users).
#>

# Runs on the remote computer. Receives the collector code as text, loads it
# and returns the inventory as JSON (a string travels better than a
# deserialized object).
$script:PCScopeRemoteScript = {
    param([Parameter(Mandatory)] [string] $CollectorSource)

    . ([scriptblock]::Create($CollectorSource))
    Get-PCScopeInventory -Method 'remote' | ConvertTo-Json -Depth 8
}

function Get-PCScopeComputerList {
    <#
    .SYNOPSIS
        Reads computer names from a text file: one per line, blank lines and
        lines starting with # are ignored.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $Path)

    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -Path $fullPath -PathType Leaf)) { throw "Computer list not found: $Path" }

    $names = foreach ($line in [IO.File]::ReadAllLines($fullPath)) {
        $name = ($line -replace '#.*$', '').Trim()
        if ($name) { $name }
    }
    return @($names | Select-Object -Unique)
}

function ConvertTo-PCScopeFileName {
    <#
    .SYNOPSIS
        Makes a computer name safe to use as a file name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Name)

    return ($Name -replace '[^\w.-]', '_')
}

function Invoke-PCScopeRemoteCollection {
    <#
    .SYNOPSIS
        Collects the inventory of several computers and saves one JSON per
        computer. Returns one result object per requested computer.

    .EXAMPLE
        Invoke-PCScopeRemoteCollection -ComputerName PC01, PC02 -DataPath .\output\data

    .EXAMPLE
        $cred = Get-Credential CONTOSO\it.admin
        Invoke-PCScopeRemoteCollection -ComputerName (Get-PCScopeComputerList .\computers.txt) -DataPath \\server\it\pcscope\data -Credential $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ComputerName,
        [Parameter(Mandatory)] [string] $DataPath,
        [pscredential] $Credential,
        [ValidateRange(1, 256)] [int] $ThrottleLimit = 32
    )

    $DataPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DataPath)
    if (-not (Test-Path -Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath -Force | Out-Null }

    $collectorSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Collector.ps1'))
    $parameters = @{
        ComputerName  = $ComputerName
        ScriptBlock   = $script:PCScopeRemoteScript
        ArgumentList  = $collectorSource
        ThrottleLimit = $ThrottleLimit
        ErrorAction   = 'SilentlyContinue'
        ErrorVariable = 'remoteErrors'
    }
    if ($Credential) { $parameters.Credential = $Credential }

    $remoteErrors = @()
    $responses = @(Invoke-Command @parameters)

    $results = @{}
    foreach ($response in $responses) {
        $target = [string]$response.PSComputerName
        try {
            $inventory = [string]$response | ConvertFrom-Json -ErrorAction Stop
            if (-not $inventory.computerName) { throw 'missing computerName' }
            $file = Join-Path $DataPath ("{0}.json" -f (ConvertTo-PCScopeFileName $inventory.computerName))
            [IO.File]::WriteAllText($file, [string]$response, (New-Object Text.UTF8Encoding($false)))
            $results[$target] = [pscustomobject][ordered]@{
                ComputerName = $target; Status = 'OK'; Device = $inventory.computerName; File = $file
                Seconds = $inventory.collector.durationSeconds; Message = ''
            }
        }
        catch {
            $results[$target] = [pscustomobject][ordered]@{
                ComputerName = $target; Status = 'Failed'; Device = $null; File = $null; Seconds = $null
                Message = "Invalid response: $($_.Exception.Message)"
            }
        }
    }

    foreach ($problem in $remoteErrors) {
        $target = if ($problem.OriginInfo) { [string]$problem.OriginInfo.PSComputerName }
                  elseif ($problem.TargetObject) { [string]$problem.TargetObject }
                  else { '' }
        if (-not $target -or ($results.ContainsKey($target) -and $results[$target].Status -eq 'OK')) { continue }
        $message = ([string]$problem.Exception.Message -split "`r?`n")[0]
        $results[$target] = [pscustomobject][ordered]@{
            ComputerName = $target; Status = 'Failed'; Device = $null; File = $null; Seconds = $null; Message = $message
        }
    }

    # One result per requested computer, in the order requested
    foreach ($name in $ComputerName) {
        $match = $results.Keys | Where-Object { $_ -eq $name } | Select-Object -First 1
        if ($match) {
            $results[$match]
        }
        else {
            [pscustomobject][ordered]@{
                ComputerName = $name; Status = 'Failed'; Device = $null; File = $null; Seconds = $null
                Message = 'No response'
            }
        }
    }
}

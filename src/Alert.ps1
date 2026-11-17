#Requires -Version 5.1
<#
.SYNOPSIS
    Alerts: sends new critical issues and notable changes by Telegram or email.

.DESCRIPTION
    Only what is new is sent. The keys of alerts already sent are kept in
    <OutputPath>\alerts-state.json; when an issue is fixed it leaves the
    state, so it is reported again if it comes back.

    Secrets are never stored in the configuration file: the Telegram bot token
    and the SMTP password are read from environment variables.
#>

function Get-PCScopeAlertConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -Path $fullPath -PathType Leaf)) {
        throw "Alert configuration not found: $Path (copy alerts.example.json to alerts.json and edit it)"
    }
    return [IO.File]::ReadAllText($fullPath) | ConvertFrom-Json
}

function Get-PCScopeAlert {
    <#
    .SYNOPSIS
        Builds the alert candidates from a fleet (Get-PCScopeFleet): issues at
        or above -MinLevel and, optionally, notable changes detected in the
        latest collection of each device.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Fleet,
        [ValidateSet('critical', 'warning')] [string] $MinLevel = 'critical',
        [switch] $IncludeNotableChanges
    )

    $levels = if ($MinLevel -eq 'warning') { @('critical', 'warning') } else { @('critical') }
    foreach ($device in $Fleet) {
        foreach ($issue in @($device.Issues | Where-Object { $levels -contains $_.level })) {
            [pscustomobject]@{
                Key = "issue|$($device.Name)|$($issue.rule)|$($issue.message)"; Device = $device.Name
                Kind = $issue.level; Message = $issue.message
            }
        }
        if ($IncludeNotableChanges) {
            $latest = $device.Inventory.collectedAt
            foreach ($change in @($device.Changes | Where-Object { $_.notable -and $_.date -eq $latest })) {
                [pscustomobject]@{
                    Key = "change|$($device.Name)|$($change.date)|$($change.message)"; Device = $device.Name
                    Kind = 'change'; Message = $change.message
                }
            }
        }
    }
}

function Select-PCScopeNewAlert {
    <#
    .SYNOPSIS
        Returns the alerts not sent before and the updated state. Issues that
        are no longer present are dropped from the state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Alert,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $SentKey
    )

    $new = @($Alert | Where-Object { $SentKey -notcontains $_.Key })
    $state = @($Alert | ForEach-Object { $_.Key })
    # Change alerts happen once; keep their keys so a rebuild never resends them
    $state += @($SentKey | Where-Object { $_ -like 'change|*' -and $state -notcontains $_ })
    [pscustomobject]@{ New = $new; State = @($state | Select-Object -Unique) }
}

function Format-PCScopeAlert {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object[]] $Alert, [string] $Title = 'PCScope')

    $icon = @{ critical = '[CRITICAL]'; warning = '[WARNING]'; change = '[REVIEW]' }
    $lines = @("$Title - $($Alert.Count) new alert(s)", '')
    foreach ($group in $Alert | Group-Object -Property Device) {
        $lines += $group.Name
        foreach ($item in $group.Group) { $lines += "  $($icon[$item.Kind]) $($item.Message)" }
    }
    return ($lines -join "`n")
}

function Send-PCScopeTelegram {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Token, [Parameter(Mandatory)] [string] $ChatId, [Parameter(Mandatory)] [string] $Text)

    if ($PSCmdlet.ShouldProcess("Telegram chat $ChatId", 'Send alert')) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $body = @{ chat_id = $ChatId; text = $Text; disable_web_page_preview = $true } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$Token/sendMessage" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' | Out-Null
    }
}

function Send-PCScopeMail {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Smtp,
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Text
    )

    if (-not $PSCmdlet.ShouldProcess(($Smtp.to -join ', '), 'Send alert email')) { return }
    $message = New-Object Net.Mail.MailMessage
    $message.From = $Smtp.from
    foreach ($address in @($Smtp.to)) { $message.To.Add($address) }
    $message.Subject = $Subject
    $message.Body = $Text
    $client = New-Object Net.Mail.SmtpClient($Smtp.server, [int]$Smtp.port)
    $client.EnableSsl = ($Smtp.useSsl -ne $false)
    if ($Smtp.user) {
        # The password only lives in an environment variable, never in a file or parameter
        $client.Credentials = New-Object Net.NetworkCredential($Smtp.user, [Environment]::GetEnvironmentVariable('PCSCOPE_SMTP_PASSWORD'))
    }
    try { $client.Send($message) } finally { $message.Dispose(); $client.Dispose() }
}

function Invoke-PCScopeAlert {
    <#
    .SYNOPSIS
        Sends the new alerts of a fleet through the channels enabled in the
        configuration and updates the state file. Returns what was sent.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Fleet,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $StatePath
    )

    $candidates = @(Get-PCScopeAlert -Fleet $Fleet -MinLevel $(if ($Config.minLevel) { $Config.minLevel } else { 'critical' }) `
            -IncludeNotableChanges:($Config.includeNotableChanges -ne $false))
    $statePath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($StatePath)
    $sent = @()
    if (Test-Path -Path $statePath) {
        # In PowerShell 5.1 ConvertFrom-Json emits a JSON array as ONE object: pipe it to unroll
        $sent = @(([IO.File]::ReadAllText($statePath) | ConvertFrom-Json) | ForEach-Object { [string]$_ })
    }
    $selection = Select-PCScopeNewAlert -Alert $candidates -SentKey ([string[]]$sent)

    if ($selection.New.Count) {
        $title = if ($Config.title) { $Config.title } else { 'PCScope' }
        $text = Format-PCScopeAlert -Alert $selection.New -Title $title
        if ($Config.telegram -and $Config.telegram.enabled) {
            $token = [Environment]::GetEnvironmentVariable('PCSCOPE_TELEGRAM_TOKEN')
            if (-not $token) { throw 'Telegram is enabled but the PCSCOPE_TELEGRAM_TOKEN environment variable is not set.' }
            Send-PCScopeTelegram -Token $token -ChatId ([string]$Config.telegram.chatId) -Text $text
        }
        if ($Config.email -and $Config.email.enabled) {
            Send-PCScopeMail -Smtp $Config.email -Subject "$title - $($selection.New.Count) new alert(s)" -Text $text
        }
    }

    if ($PSCmdlet.ShouldProcess($statePath, 'Save alert state')) {
        [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject ([object[]]$selection.State)), (New-Object Text.UTF8Encoding($false)))
    }
    return $selection.New
}

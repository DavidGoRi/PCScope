@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # PCScope.ps1 is an interactive entry point: console output is intended
        'PSAvoidUsingWriteHost'
    )
}

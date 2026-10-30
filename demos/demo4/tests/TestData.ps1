function New-TestCapture {
    param([ValidateSet('cloud', 'local')][string] $Source = 'cloud')
    $prompt = Get-D4Prompt
    $response = @{
        choices = @(@{
            message = @{ content = "TEST FIXTURE ONLY - no model was called. Fictional stale status cards lasted 18 minutes; routing was rolled back; exported reports need review." }
            finish_reason = 'stop'
            content_filter_results = @{ fixture = $true }
        })
        prompt_filter_results = @(@{ fixture = $true })
        usage = @{ total_tokens = 42 }
    }
    return (New-D4Capture -Source $Source -Response $response -Prompt $prompt -Model "TEST-FIXTURE-$Source" -ElapsedMs 1234.5 -Governance @{ fixture = 'TEST ONLY - not real governance evidence' } -AirplaneModeAttested ($Source -eq 'local'))
}

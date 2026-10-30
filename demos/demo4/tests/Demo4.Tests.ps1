BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'scripts\Demo4.psm1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'Matched prompt and honest endpoint captures' {
    It 'has a deterministic fictional prompt and SHA-256 hash' {
        $one = Get-D4Prompt
        $two = Get-D4Prompt
        $one.sha256 | Should -BeExactly $two.sha256
        $one.sha256.Length | Should -Be 64
        $one.text | Should -Match 'FICTIONAL TRAINING DATA'
        $one.text | Should -Match 'Preserve uncertainty'
    }
    It 'retains actual latency, response filters, provenance and explicit attestation' {
        $capture = New-TestCapture local
        $capture.elapsedMs | Should -Be 1234.5
        $capture.filtersReturned.completion.fixture | Should -BeTrue
        $capture.airplaneModeAttested | Should -BeTrue
        $capture.isolationEvidence | Should -Match 'not independently verified'
        { Assert-D4Capture $capture local } | Should -Not -Throw
    }
    It 'rejects empty or blocked responses rather than substituting an answer' {
        $prompt = Get-D4Prompt
        { New-D4Capture -Source cloud -Response @{ choices = @() } -Prompt $prompt -Model test -ElapsedMs 0 -Governance @{} } | Should -Throw '*no answer*'
        $response = @{ choices = @(@{ message = @{ content = 'blocked' }; finish_reason = 'content_filter' }) }
        { New-D4Capture -Source cloud -Response $response -Prompt $prompt -Model test -ElapsedMs 0 -Governance @{} } | Should -Throw '*finish reason*'
    }
    It 'preserves truncation as length rather than claiming a complete response' {
        $response = @{ choices = @(@{ message = @{ content = 'partial' }; finish_reason = 'length' }) }
        $capture = New-D4Capture -Source local -Response $response -Prompt (Get-D4Prompt) -Model test -ElapsedMs 0 -Governance @{}
        $capture.finishReason | Should -Be 'length'
    }
    It 'rejects negative latency, wrong provenance, wrong source and tampered prompt' {
        $capture = New-TestCapture cloud
        $capture.elapsedMs = -1
        { Assert-D4Capture $capture cloud } | Should -Throw '*Invalid*'
        $capture = New-TestCapture cloud
        $capture.provenance = 'sample'
        { Assert-D4Capture $capture cloud } | Should -Throw '*Invalid*'
        $capture = New-TestCapture cloud
        { Assert-D4Capture $capture local } | Should -Throw '*Invalid*'
        $capture.prompt += 'tampered'
        { Assert-D4Capture $capture cloud } | Should -Throw '*hash*'
    }
    It 'rejects altered generation settings' {
        $capture = New-TestCapture cloud
        $capture.generation.temperature = 1
        { Assert-D4Capture $capture cloud } | Should -Throw '*generation settings*'
    }
}

Describe 'Laptop endpoint containment' {
    It 'permits only literal loopback on the expected API path' {
        { Assert-D4LocalEndpoint 'http://127.0.0.1:39839/v1' } | Should -Not -Throw
    }
    It 'rejects remote hosts, localhost DNS, user info, alternate paths and queries' {
        foreach ($url in @('https://example.com/v1', 'http://localhost:39839/v1',
                'http://127.0.0.1:39839/v1?redirect=1', 'http://user@127.0.0.1:39839/v1',
                'http://127.0.0.1:39839/other', 'http://127.0.0.1:39839/v1#fragment')) {
            { Assert-D4LocalEndpoint $url } | Should -Throw
        }
    }
    It 'uses proxy bypass, zero redirects and a bounded request with the exact prompt' {
        Mock Invoke-RestMethod -ModuleName Demo4 {
            return @{ choices = @(@{ message = @{ content = 'TEST FIXTURE' }; finish_reason = 'stop' }) }
        }
        $prompt = Get-D4Prompt
        $result = Invoke-D4Request -Uri 'http://127.0.0.1:39839/v1/chat/completions' -Model test -Prompt $prompt -Local
        $result.elapsedMs | Should -BeGreaterOrEqual 0
        Should -Invoke Invoke-RestMethod -ModuleName Demo4 -Times 1 -Exactly -ParameterFilter {
            $NoProxy -and $MaximumRedirection -eq 0 -and $TimeoutSec -eq 180 -and
            ([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json).messages[0].content -eq (Get-D4Prompt).text
        }
    }
    It 'surfaces endpoint failures without an invented response' {
        Mock Invoke-RestMethod -ModuleName Demo4 { throw 'TEST connection refused' }
        { Invoke-D4Request -Uri 'http://127.0.0.1:39839/v1/chat/completions' -Model test -Prompt (Get-D4Prompt) -Local } | Should -Throw '*connection refused*'
    }
}

Describe 'Cloud governance drift checks' {
    BeforeEach {
        $config = @{
            accountName = 'demo4-test'; deploymentName = 'taste-test'
            subscriptionId = '00000000-0000-0000-0000-000000000001'
            resourceGroup = 'rg-demo4-test'; accountId = '/test/account'
        }
        Mock Invoke-D4Az -ModuleName Demo4 {
            param($Arguments)
            if ($Arguments[0] -eq 'rest') {
                return @{ properties = @{ contentFilters = @(
                    foreach ($source in @('Prompt', 'Completion')) {
                        foreach ($name in @('Hate', 'Sexual', 'Violence', 'Selfharm')) {
                            @{ source = $source; name = $name; enabled = $true; blocking = $true; severityThreshold = 'Medium' }
                        }
                    }
                ) } }
            }
            if ($Arguments[0] -eq 'role') { return @() }
            if ($Arguments -contains 'deployment') {
                return @{ sku = @{ name = 'Standard' }; properties = @{ raiPolicyName = 'demo4-filter'; model = @{ name = 'test'; version = 'test' } } }
            }
            return @{ id = '/test/account'; location = 'canadacentral'; properties = @{ disableLocalAuth = $true } }
        }
    }
    It 'returns actual configured policy and explicit logging/access limitations' {
        $result = Assert-D4CloudState $config
        $result.region | Should -Be 'canadacentral'
        $result.policy.contentFilters.Count | Should -Be 8
        $result.logging | Should -Match 'No Application Insights'
        $result.accessCaveat | Should -Match 'not a complete effective-access audit'
    }
    It 'rejects a changed or malicious account name before CLI or token acquisition' {
        $config.accountName = 'evil.example/path'
        { Assert-D4CloudState $config } | Should -Throw '*Invalid cloud configuration*'
        Should -Invoke Invoke-D4Az -ModuleName Demo4 -Times 0
    }
    It 'rejects GlobalStandard even when the account remains in Canada Central' {
        Mock Invoke-D4Az -ModuleName Demo4 {
            return @{ sku = @{ name = 'GlobalStandard' }; properties = @{ raiPolicyName = 'demo4-filter'; model = @{} } }
        } -ParameterFilter { $Arguments -contains 'deployment' }
        { Assert-D4CloudState $config } | Should -Throw '*governance drift*'
    }
    It 'rejects a policy with disabled or missing filters' {
        Mock Invoke-D4Az -ModuleName Demo4 { return @{ properties = @{ contentFilters = @() } } } -ParameterFilter { $Arguments[0] -eq 'rest' }
        { Assert-D4CloudState $config } | Should -Throw '*Content filter drift*'
    }
}

Describe 'Durable captures and standalone fallback' {
    BeforeEach {
        $state = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        Write-D4Json (Join-Path $state 'cloud.json') (New-TestCapture cloud)
        Write-D4Json (Join-Path $state 'local.json') (New-TestCapture local)
        $output = Join-Path $state 'fallback.html'
    }

    Describe 'Deployment orchestration with an isolated fake Azure CLI' {
        BeforeAll {
            $previousAz = Get-Command az -CommandType Function -ErrorAction SilentlyContinue
            $previousAzBody = if ($previousAz) { $previousAz.ScriptBlock } else { $null }
            function global:az {
                $arguments = @($args)
                $global:D4TestCalls.Add($arguments)
                $global:LASTEXITCODE = 0
                $answer = switch ($arguments[0..2] -join ' ') {
                    'cognitiveservices model list' {
                        @(@{ model = @{ format = 'OpenAI'; name = 'gpt-4.1-mini'; version = '2025-04-14'; skus = @(@{ name = 'Standard' }) } })
                    }
                    'cognitiveservices usage list' {
                        @(@{ name = @{ value = 'OpenAI.Standard.gpt-4.1-mini' }; currentValue = 0; limit = $global:D4TestQuota })
                    }
                    'group exists --subscription' { $global:D4TestGroupExists }
                    'group show --subscription' { @{ tags = @{} } }
                    'group create --subscription' { @{ name = 'rg-brk439-demo4' } }
                    'deployment group validate' { @{ properties = @{ provisioningState = 'Succeeded' } } }
                    'deployment group create' {
                        @{ properties = @{ outputs = @{
                            accountName = @{ value = 'demo4-test' }; accountId = @{ value = '/test/account' }
                            deploymentName = @{ value = 'taste-test' }
                            projectEndpoint = @{ value = 'https://demo4-test.services.ai.azure.com/api/projects/demo4' }
                        } } }
                    }
                    default { throw "FAKE CLI rejected unexpected command: $($arguments -join ' '). Real Azure is never called by these tests." }
                }
                ConvertTo-Json -InputObject $answer -Depth 20 -Compress
            }
        }
        BeforeEach {
            $global:D4TestCalls = [Collections.Generic.List[object]]::new()
            $global:D4TestQuota = 10
            $global:D4TestGroupExists = $false
            $deployArguments = @{
                SubscriptionId = '00000000-0000-0000-0000-000000000001'
                ModelName = 'gpt-4.1-mini'; ModelVersion = '2025-04-14'
                PrincipalObjectId = '00000000-0000-0000-0000-000000000002'
                StateDirectory = (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
            }
        }
        AfterAll {
            if ($previousAzBody) { Set-Item Function:\global:az $previousAzBody }
            else { Remove-Item Function:\global:az }
            Remove-Variable D4TestCalls, D4TestQuota, D4TestGroupExists -Scope Global
        }
        It 'preflights without any group, deployment or role mutation by default' {
            & (Join-Path $root 'Deploy-Demo.ps1') @deployArguments
            $global:D4TestCalls.Count | Should -Be 2
            Test-Path -LiteralPath $deployArguments.StateDirectory | Should -BeFalse
        }
        It 'honors WhatIf without provisioning or writing configuration' {
            & (Join-Path $root 'Deploy-Demo.ps1') @deployArguments -Apply -WhatIf
            $global:D4TestCalls.Count | Should -Be 2
            Test-Path -LiteralPath $deployArguments.StateDirectory | Should -BeFalse
        }
        It 'passes separate exact Bicep parameters and persists non-secret configuration only after success' {
            & (Join-Path $root 'Deploy-Demo.ps1') @deployArguments -Apply -Confirm:$false
            $call = @($global:D4TestCalls | Where-Object { $_[0..2] -join ' ' -eq 'deployment group create' })
            $call.Count | Should -Be 1
            $call[0] | Should -Contain 'modelName=gpt-4.1-mini'
            $call[0] | Should -Contain 'modelVersion=2025-04-14'
            $call[0] | Should -Contain 'capacity=1'
            $call[0] | Should -Contain 'principalType=User'
            $config = Read-D4Json (Join-Path $deployArguments.StateDirectory 'cloud-config.json')
            $config.accountName | Should -Be 'demo4-test'
            $config.deploymentName | Should -Be 'taste-test'
            $config.ContainsKey('token') | Should -BeFalse
        }
        It 'refuses a shared untagged group before template validation or deployment' {
            $global:D4TestGroupExists = $true
            { & (Join-Path $root 'Deploy-Demo.ps1') @deployArguments -Apply -Confirm:$false } | Should -Throw '*not tagged for Demo 4*'
            @($global:D4TestCalls | Where-Object { $_[0] -eq 'deployment' }).Count | Should -Be 0
        }
        It 'refuses zero quota without selecting another region or SKU' {
            $global:D4TestQuota = 0
            { & (Join-Path $root 'Deploy-Demo.ps1') @deployArguments -Apply -Confirm:$false } | Should -Throw '*quota*'
            $global:D4TestCalls.Count | Should -Be 2
        }
        It 'refuses an unavailable model version before quota or provisioning' {
            $deployArguments.ModelVersion = 'unavailable'
            { & (Join-Path $root 'Deploy-Demo.ps1') @deployArguments -Apply -Confirm:$false } | Should -Throw '*does not support regional Standard*'
            $global:D4TestCalls.Count | Should -Be 1
        }
    }
    It 'round-trips JSON without retaining temporary files' {
        $capture = Read-D4Json (Join-Path $state 'cloud.json')
        $capture.answer | Should -Match 'TEST FIXTURE ONLY'
        @(Get-ChildItem -LiteralPath $state -Filter '*.tmp').Count | Should -Be 0
    }
    It 'builds a self-contained offline page with embedded randomized pair and honest mode' {
        New-D4Comparison -StateDirectory $state -OutputPath $output -Mode fallback | Should -Be $output
        $html = Get-Content -LiteralPath $output -Raw
        $html | Should -Not -Match '__DEMO4_PAYLOAD_BASE64__'
        $html | Should -Match 'PRE-CAPTURED FALLBACK'
        $html | Should -Not -Match '<script[^>]+src=|fetch\s*\(|XMLHttpRequest'
        $match = [regex]::Match($html, 'atob\("([^"]+)"\)')
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
        $payload.mode | Should -Be 'fallback'
        @($payload.a.source, $payload.b.source) | Should -Contain 'cloud'
        @($payload.a.source, $payload.b.source) | Should -Contain 'local'
    }
    It 'rejects mismatched prompts and preserves an existing good fallback' {
        [IO.File]::WriteAllText($output, 'GOOD FALLBACK')
        $local = New-TestCapture local
        $local.prompt += 'different'
        $local.promptSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($local.prompt)))
        Write-D4Json (Join-Path $state 'local.json') $local
        { New-D4Comparison -StateDirectory $state -OutputPath $output -Mode fallback } | Should -Throw '*identical prompt*'
        (Get-Content -LiteralPath $output -Raw) | Should -BeExactly 'GOOD FALLBACK'
    }
    It 'rejects an unattested local capture' {
        $local = New-TestCapture local
        $local.airplaneModeAttested = $false
        Write-D4Json (Join-Path $state 'local.json') $local
        { New-D4Comparison -StateDirectory $state -OutputPath $output -Mode stage } | Should -Throw '*attestation*'
    }
    It 'does not synthesize missing captures' {
        Remove-Item -LiteralPath (Join-Path $state 'local.json')
        { New-D4Comparison -StateDirectory $state -OutputPath $output -Mode fallback } | Should -Throw '*missing*'
    }
    It 'encodes rather than executes hostile answer markup in the artifact' {
        $local = New-TestCapture local
        $local.answer = '</script><img src=x onerror=alert(1)>'
        Write-D4Json (Join-Path $state 'local.json') $local
        $null = New-D4Comparison -StateDirectory $state -OutputPath $output -Mode stage
        (Get-Content -LiteralPath $output -Raw) | Should -Not -Match '<img src=x'
    }
}

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../scripts/Demo.Common.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../host/Demo.Worker.psm1') -Force
}

Describe 'Real read transport contract (mocked transport only)' {
    InModuleScope Demo.Worker {
        BeforeEach {
            $script:config = @{
                container = 'demo'; blob = 'synthetic.txt'
                targets = @{ Live = @{ accountName = 'demo2live' }; Twin = @{ accountName = 'demo2twin' } }
            }
            Mock Get-DemoToken { 'mock-token-not-a-credential' }
            Mock Write-DemoEvent {}
            Mock Invoke-DemoHttp {
                @{ status = 200; headers = @{ 'x-ms-request-id' = 'azure-test-request' }; body = 'synthetic plaintext' }
            }
        }
        It 'issues a new GET on every refresh with no conditional or cached content' {
            $first = Read-DemoBlob $script:config 'Live'
            $second = Read-DemoBlob $script:config 'Live'
            $first.clientRequestId | Should -Not -Be $second.clientRequestId
            Should -Invoke Invoke-DemoHttp -Times 2 -ParameterFilter {
                $Uri -eq 'https://demo2live.blob.core.windows.net/demo/synthetic.txt' -and
                $Headers['Cache-Control'] -eq 'no-cache, no-store' -and -not $Headers.ContainsKey('If-None-Match')
            }
        }
        It 'returns actual HTTP and Azure identifiers, never previous plaintext on failure' {
            $null = Read-DemoBlob $script:config 'Live'
            Mock Invoke-DemoHttp {
                @{ status = 403; headers = @{ 'x-ms-request-id' = 'denial-id'; 'x-ms-error-code' = 'KeyVaultAccessForbidden' }; body = '<Error>not plaintext</Error>' }
            }
            $read = Read-DemoBlob $script:config 'Live'
            $read.status | Should -Be 403
            $read.errorCode | Should -Be 'KeyVaultAccessForbidden'
            $read.requestId | Should -Be 'denial-id'
            $read.content | Should -Be ''
        }
        It 'does not misclassify an expired-token error as a CMK error' {
            Mock Invoke-DemoHttp { @{ status = 401; headers = @{ 'x-ms-error-code' = 'AuthenticationFailed' }; body = '' } }
            $read = Read-DemoBlob $script:config 'Live'
            $read.status | Should -Be 401
            $read.errorCode | Should -Be 'AuthenticationFailed'
            $read.content | Should -Be ''
        }
        It 'surfaces transport failure instead of fabricating a 403' {
            Mock Invoke-DemoHttp { throw 'DNS resolution failed' }
            { Read-DemoBlob $script:config 'Live' } | Should -Throw '*DNS*'
        }
        It 'switches accounts only when the requested target is explicitly Twin' {
            $read = Read-DemoBlob $script:config 'Twin'
            $read.target | Should -Be 'Twin'
            Should -Invoke Invoke-DemoHttp -Times 1 -ParameterFilter { $Uri -like 'https://demo2twin.*' }
            Should -Invoke Invoke-DemoHttp -Times 0 -ParameterFilter { $Uri -like 'https://demo2live.*' }
        }
        It 'logs evidence without plaintext or credentials' {
            $null = Read-DemoBlob $script:config 'Live'
            Should -Invoke Write-DemoEvent -Times 1 -ParameterFilter {
                $EventName -eq 'BlobRead' -and -not $Data.ContainsKey('content') -and
                -not $Data.ContainsKey('Authorization') -and $Data.requestId -eq 'azure-test-request'
            }
        }
    }
}

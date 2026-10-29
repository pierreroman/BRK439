BeforeAll {
    . (Join-Path $PSScriptRoot 'TestData.ps1')
    $script:control = Join-Path $PSScriptRoot '../scripts/Invoke-DemoControl.ps1'
}

Describe 'Azure CLI JSON handoff on Windows' {
    It 'passes <Script> configuration through a resolved JSON file, not inline JSON' -ForEach @(
        @{ Script = 'Deploy-Demo.ps1' },
        @{ Script = 'Test-PolicyExamples.ps1' }
    ) {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../scripts/$Script") -Raw
        $source | Should -Match ([regex]::Escape("'config=@' + (Resolve-Path -LiteralPath `$ConfigPath).ProviderPath"))
        $source | Should -Not -Match ([regex]::Escape("'config=' + (`$config | ConvertTo-Json"))
    }
    It 'uses a temporary JSON file for HSM role definitions and removes it in finally' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/Initialize-Hsm.ps1') -Raw
        $source | Should -Match ([regex]::Escape("'--role-definition', ('@' + `$definitionPath.FullName)"))
        $source | Should -Match 'finally\s*\{\s*Remove-Item -LiteralPath \$definitionPath.FullName -Force'
    }
}

Describe 'Operator transport and authorization (SSH mocked, no host contacted)' {
    BeforeEach {
        $config = New-TestConfiguration
        $path = Join-Path $TestDrive 'operator-config.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content $path
        $run = [guid]::NewGuid()
        Mock ssh {
            $global:LASTEXITCODE = 0
            $command = $args -join ' '
            $action = [regex]::Match($command, '-Action (\w+)').Groups[1].Value
            $target = [regex]::Match($command, '-Target (\w+)').Groups[1].Value
            $runId = [regex]::Match($command, '-RunId ([a-fA-F0-9-]+)').Groups[1].Value
            @{ ok = $true; action = $action; target = $target; runId = $runId; state = $null; read = @{ status = 200; content = 'synthetic' }; heartbeatUtc = '2026-01-01T00:00:00Z'; error = '' } | ConvertTo-Json -Depth 5 -Compress
        }
    }
    It 'refuses Disable without explicit live authorization' {
        { & $script:control -ConfigPath $path -Action Disable -Target Live -RunId $run } | Should -Throw
        Should -Invoke ssh -Times 0
    }
    It 'permits an authorized fixed-command request' {
        $reply = & $script:control -ConfigPath $path -Action Arm -Target Live -RunId $run -AuthorizeLiveChanges
        $reply.ok | Should -BeTrue
        Should -Invoke ssh -Times 1
    }
    It 'permits read-only requests without permission to change keys' {
        $reply = & $script:control -ConfigPath $path -Action Read -Target Live -RunId $run
        $reply.read.status | Should -Be 200
    }
    It 'surfaces malformed worker replies' {
        Mock ssh { $global:LASTEXITCODE = 0; 'not json' }
        { & $script:control -ConfigPath $path -Action Status -Target Live -RunId $run } | Should -Throw
    }
    It 'surfaces a failed worker request rather than success-shaped fallback' {
        Mock ssh { $global:LASTEXITCODE = 1; '{"ok":false,"error":"Key outcome uncertain; recovery retained."}' }
        { & $script:control -ConfigPath $path -Action Disable -Target Live -RunId $run -AuthorizeLiveChanges } | Should -Throw
    }
    It 'constructs the native control with Disable unavailable and no network request' -Skip:(-not $IsWindows) {
        $panel = Join-Path $PSScriptRoot '../scripts/Show-ControlPanel.ps1'
        $model = & $panel -ConfigPath $path -SmokeTest
        $model.actions.Count | Should -Be 6
        $model.disableEnabled | Should -BeFalse
        $model.target | Should -Be 'Live'
        $model.document | Should -Be ''
        Should -Invoke ssh -Times 0
    }
}

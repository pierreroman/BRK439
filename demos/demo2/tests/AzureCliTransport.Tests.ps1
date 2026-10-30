BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Common.psm1') -Force
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Common.psm1') -Force
}
Describe 'Real Windows cmd/native argv boundary (fake Azure module, no Azure)' -Skip:(-not $IsWindows) {
    InModuleScope Demo.Common {
        BeforeAll {
            $python=@(Get-Command python -CommandType Application | Where-Object Source -NotLike '*\WindowsApps\*')[0].Source
            $script:fixtureRoot=Join-Path $TestDrive 'fake Azure CLI with spaces'
            & $python -m venv --without-pip $script:fixtureRoot
            if ($LASTEXITCODE -ne 0) { throw 'Synthetic Python CLI fixture creation failed.' }
            $package=Join-Path $script:fixtureRoot 'Lib\site-packages\azure\cli'
            [void][IO.Directory]::CreateDirectory($package)
            [IO.File]::WriteAllText((Join-Path $package '..\__init__.py'),'')
            [IO.File]::WriteAllText((Join-Path $package '__init__.py'),'')
            [IO.File]::WriteAllText((Join-Path $package '__main__.py'),@'
import json, sys
from pathlib import Path
args = sys.argv[1:]
if "--url" in args and "/virtualMachines/offline-vm/runCommands/" in args[args.index("--url")+1]:
    state_file=Path(__file__).with_name("synthetic-arm-state.json")
    method=args[args.index("--method")+1]
    if method=="put":
        body=json.loads(Path(args[args.index("--body")+1][1:]).read_text(encoding="utf-8-sig"))
        body["id"]=args[args.index("--url")+1].split("?")[0].removeprefix("https://management.azure.com")
        body["properties"]["provisioningState"]="Creating"
        state={"command":body,"puts":1,"observed":False}
        state_file.write_text(json.dumps(state),encoding="utf-8")
        print(json.dumps(body))
        sys.exit(0)
    if not state_file.exists():
        print('ERROR: {"code":"ResourceNotFound"}',file=sys.stderr)
        sys.exit(3)
    state=json.loads(state_file.read_text(encoding="utf-8"))
    if not state["observed"]:
        state["observed"]=True
        state_file.write_text(json.dumps(state),encoding="utf-8")
        print(json.dumps(state["command"]))
        print("ERROR: ('Connection aborted.', ConnectionResetError(10054, 'DO_NOT_LOG_NETWORK_BODY'))",file=sys.stderr)
        sys.exit(1)
    command=state["command"]
    command["properties"]["provisioningState"]="Succeeded"
    command["properties"]["instanceView"]={"executionState":"Succeeded","exitCode":0,"output":json.dumps({"operationId":command["tags"]["operationId"],"ok":True})}
    print(json.dumps(command))
    sys.exit(0)
if "--fixture-fail" in args:
    print(json.dumps({"tags":{"operationId":"11111111-1111-1111-1111-111111111111"},"properties":{"provisioningState":"Creating","source":{"script":"DO_NOT_LOG_SCRIPT_OR_CIPHERTEXT"}}}))
    print('ERROR: {"error":{"code":"AuthorizationFailed","statusCode":403,"correlationId":"22222222-2222-2222-2222-222222222222","message":"DO_NOT_LOG_ERROR_BODY"}}',file=sys.stderr)
    sys.exit(23)
if "--fixture-malformed" in args:
    print("DO_NOT_LOG_MALFORMED_CONTENT")
    sys.exit(0)
if "--fixture-notfound" in args:
    print('ERROR: {"error":{"code":"ResourceNotFound","message":"DO_NOT_LOG_ERROR_BODY"}}',file=sys.stderr)
    sys.exit(3)
if "--fixture-plain-arm" in args:
    print('ERROR: (Conflict) DO_NOT_LOG_ERROR_BODY token=DO_NOT_LOG_TOKEN',file=sys.stderr)
    print('Status Code: 409',file=sys.stderr)
    sys.exit(1)
if "--fixture-auth" in args:
    print("ERROR: Please run 'az login' to setup account.",file=sys.stderr)
    sys.exit(1)
if "--fixture-aad" in args:
    print("ERROR: AADSTS700082: DO_NOT_LOG_ACCOUNT_OR_TOKEN",file=sys.stderr)
    sys.exit(1)
if "--fixture-usage" in args:
    print("ERROR: unrecognized arguments: --body DO_NOT_LOG_ARGUMENT",file=sys.stderr)
    sys.exit(2)
if "--fixture-launcher" in args:
    print("python.exe: No module named azure.cli",file=sys.stderr)
    sys.exit(1)
if "--fixture-nested-error" in args:
    print('ERROR: {"error":{"code":"DeploymentFailed","details":[{"code":"ResourceDeploymentFailure","innererror":{"code":"Conflict","message":"DO_NOT_LOG_NESTED_BODY"}}]}}',file=sys.stderr)
    sys.exit(1)
if "--fixture-reset" in args:
    print("ERROR: ('Connection aborted.', ConnectionResetError(10054, 'DO_NOT_LOG_NETWORK_BODY'))",file=sys.stderr)
    sys.exit(1)
print(json.dumps({"argv":args}))
'@)
            $bin=Join-Path $script:fixtureRoot 'Scripts\wbin'
            [void][IO.Directory]::CreateDirectory($bin)
            $script:shim=Join-Path $bin 'az.cmd'
            [IO.File]::WriteAllText($script:shim,('@echo off'+"`r`n"+'"%~dp0..\python.exe" -IBm azure.cli %*'+"`r`n"))
            $script:fakeApplication=Get-Command $script:shim -CommandType Application
            $script:batchApplication=$script:fakeApplication
            $script:nativeApplication=Get-Command (Join-Path $script:fixtureRoot 'Scripts\python.exe') -CommandType Application
        }
        BeforeEach {
            $script:fakeApplication=$script:batchApplication
            Mock Get-Command { $script:fakeApplication } -ParameterFilter { $Name -eq 'az' }
        }
        It 'reproduces cmd splitting literal &$expand with the actual batch/native boundary' {
            $url='https://management.example.invalid/command?api-version=2024-07-01&$expand=instanceView'
            $output=& $script:shim rest --url $url 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match '\$expand'
        }
        It 'preserves URL query, shell characters, literal dollars/percent signs and JSON-file arguments natively' {
            $url='https://management.example.invalid/command?api-version=2024-07-01&$expand=instanceView'
            $body=Join-Path $TestDrive 'request with spaces.json'
            [IO.File]::WriteAllText($body,'{"synthetic":true}')
            $values=@('rest','--url',$url,'--body',"@$body",'--fixture-literal','spaces & $literal %PATH% | < > ^ "quoted"')
            $result=Invoke-AzJson $values
            for ($i=0; $i -lt $values.Count; $i++) { $result.argv[$i] | Should -BeExactly $values[$i] }
        }
        It 'never includes resource scripts or stderr error bodies in nonzero-exit diagnostics' {
            try { Invoke-AzJson @('rest','--fixture-fail'); throw 'Expected failure' }
            catch {
                $_.Exception.Message | Should -Match 'exit 23'
                $_.Exception.ToString() | Should -Not -Match 'DO_NOT_LOG'
                $_.Exception.Data['AzureCliExitCode'] | Should -Be 23
                $_.Exception.Data['ProvisioningState'] | Should -Be 'Creating'
                $_.Exception.Data['OperationId'] | Should -Be '11111111-1111-1111-1111-111111111111'
                $_.Exception.Message | Should -Match 'AuthorizationFailed'
                $_.Exception.Message | Should -Match 'HttpStatus=403'
                $_.Exception.Message | Should -Match 'correlationId=22222222-2222-2222-2222-222222222222'
            }
        }
        It 'retains a root not-found code without dumping the server message' {
            { Invoke-AzJson @('rest','--fixture-notfound') } | Should -Throw '*ResourceNotFound*'
        }
        It 'sanitizes malformed successful output instead of echoing content or returning success' {
            { Invoke-AzJson @('rest','--fixture-malformed') } | Should -Throw '*malformed JSON*'
            try { Invoke-AzJson @('rest','--fixture-malformed') } catch { $_.Exception.ToString() | Should -Not -Match 'DO_NOT_LOG' }
        }
        It 'also preserves argv on the native non-batch application path' {
            $script:fakeApplication=$script:nativeApplication
            $value='native & $literal "quoted" %PATH%'
            $result=Invoke-AzJson @('-IBm','azure.cli','--fixture-literal',$value)
            $result.argv[1] | Should -BeExactly $value
        }
        It 'retains actionable <Kind> stderr without printing raw messages or argument values' -ForEach @(
            @{Kind='ARM code';Flag='--fixture-plain-arm';Expected='Conflict';Classification='AzureErrorCode'},
            @{Kind='login';Flag='--fixture-auth';Expected='requires az login';Classification='Authentication'},
            @{Kind='AADSTS';Flag='--fixture-aad';Expected='AADSTS700082';Classification='Authentication'},
            @{Kind='usage';Flag='--fixture-usage';Expected='Argument: --body';Classification='Usage'},
            @{Kind='launcher';Flag='--fixture-launcher';Expected='cannot import Azure CLI';Classification='Launcher'},
            @{Kind='connection reset';Flag='--fixture-reset';Expected='NativeErrorCode=10054';Classification='ConnectionReset'}
        ) {
            $url='https://management.azure.com/subscriptions/test/resourceGroups/demo2/providers/Microsoft.Compute/virtualMachines/demo2/runCommands/demo2-field-setup?sig=DO_NOT_LOG_QUERY'
            try { Invoke-AzJson @('rest','--method','get','--url',$url,'--body','DO_NOT_LOG_BODY',$Flag); throw 'Expected CLI failure' }
            catch {
                $_.Exception.Message | Should -Match $Expected
                $_.Exception.Message | Should -Match 'Command: rest GET https://management.azure.com/'
                $_.Exception.ToString() | Should -Not -Match 'DO_NOT_LOG'
                $_.Exception.Data['StderrClassification'] | Should -Be $Classification
            }
        }
        It 'omits URL credentials and handles option-only command contexts safely' {
            (Get-DemoCliContext @('--version')) | Should -Be 'az'
            (Get-DemoCliContext @('rest','--method','get','--url','https://DO_NOT_LOG:DO_NOT_LOG@management.azure.com/path?token=DO_NOT_LOG')) | Should -Be 'rest GET'
        }
        It 'retains nested actionable Azure error codes without traversing or printing message bodies' {
            try { Invoke-AzJson @('rest','--fixture-nested-error'); throw 'Expected CLI failure' }
            catch {
                $_.Exception.Data['AzureCliCode'] | Should -Be 'DeploymentFailed'
                $_.Exception.Data['AzureErrorCodes'] | Should -Be 'DeploymentFailed,ResourceDeploymentFailure,Conflict'
                $_.Exception.ToString() | Should -Not -Match 'DO_NOT_LOG'
            }
        }
        It 'reconciles an accepted PUT plus failing local GET through real native processes without replay or payload diagnostics' {
            $transportEntry=Get-Item function:Invoke-AzJson
            Import-Module (Join-Path $PSScriptRoot '..\scripts\Demo.Setup.psm1') -Force
            Mock Invoke-AzJson -ModuleName Demo.Setup { & $transportEntry -Arguments $Arguments }
            $journal=@{installationId=('a'*32);config=@{location='test'};resources=@{vmId='/subscriptions/offline/resourceGroups/offline/providers/Microsoft.Compute/virtualMachines/offline-vm'};pendingAgent=$null}
            $path=Join-Path $TestDrive 'native-agent-journal.json'
            try {
                & (Get-Module Demo.Setup) { param($J,$P) Invoke-DemoAgentScript $J $P 'SYNTHETIC_SCRIPT_DO_NOT_LOG __OPERATION_ID__' } $journal $path
                throw 'Expected initial local failure'
            } catch {
                $_.Exception.Message | Should -Match 'exit 1'
                $_.Exception.ToString() | Should -Not -Match 'SYNTHETIC_SCRIPT_DO_NOT_LOG'
            }
            $operation=$journal.pendingAgent.operationId
            $result=& (Get-Module Demo.Setup) { param($J,$P) Invoke-DemoAgentScript $J $P 'SYNTHETIC_SCRIPT_DO_NOT_LOG __OPERATION_ID__' } $journal $path
            $result.ok | Should -BeTrue
            $journal.pendingAgent | Should -BeNullOrEmpty
            $journal.agentTimings[0].operationId | Should -Be $operation
            $state=Get-Content (Join-Path $script:fixtureRoot 'Lib\site-packages\azure\cli\synthetic-arm-state.json') -Raw | ConvertFrom-Json
            $state.puts | Should -Be 1
        }
    }
}

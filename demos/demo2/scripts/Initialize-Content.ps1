[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$AuthorizeLiveChanges
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase Runtime
$content = Join-Path $PSScriptRoot '..\content\sovereignty-demo.txt'
if (-not (Test-Path -LiteralPath $content -PathType Leaf)) { throw 'Synthetic demo content file is missing.' }
if (-not $AuthorizeLiveChanges) {
    [pscustomobject]@{ Mode = 'OfflinePlan'; Action = 'Upload the same synthetic text to both private accounts using Entra authentication from approved private connectivity. No role grants or SAS.' }
    return
}
Assert-DemoAzureContext -Config $config
foreach ($target in 'Live', 'Twin') {
    $settings = $config.targets[$target]
    if ($PSCmdlet.ShouldProcess("$($settings.accountName)/$($config.container)/$($config.blob)", 'Upload synthetic content with Entra data-plane authorization')) {
        $null = Invoke-AzJson -Arguments @('storage', 'blob', 'upload', '--auth-mode', 'login', '--account-name', $settings.accountName, '--container-name', $config.container, '--name', $config.blob, '--file', $content, '--content-type', 'text/plain; charset=utf-8', '--overwrite', 'true')
        $properties = Invoke-AzJson -Arguments @('storage', 'blob', 'show', '--auth-mode', 'login', '--account-name', $settings.accountName, '--container-name', $config.container, '--name', $config.blob)
        [pscustomobject]@{ Target = $target; Account = $settings.accountName; ETag = $properties.properties.etag; Uploaded = $true }
    }
}

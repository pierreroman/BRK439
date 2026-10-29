[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [switch]$AuthorizeLiveChanges, [switch]$SmokeTest)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -and $PSVersionTable.PSEdition -ne 'Desktop') { throw 'This control requires Windows Forms on Windows.' }
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase Runtime
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Demo2 - native operator control'
$form.Size = New-Object System.Drawing.Size(1000,820)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$selector = New-Object System.Windows.Forms.ComboBox
$selector.DropDownStyle = 'DropDownList'
$selector.Items.AddRange(@('Live','Twin'))
$selector.SetBounds(20,20,180,30)
$label = New-Object System.Windows.Forms.Label
$label.SetBounds(220,20,740,80)
$label.Font = New-Object System.Drawing.Font('Segoe UI',12,[System.Drawing.FontStyle]::Bold)
$status = New-Object System.Windows.Forms.TextBox
$status.SetBounds(20,175,940,250)
$status.Multiline = $true
$status.ReadOnly = $true
$status.ScrollBars = 'Both'
$document = New-Object System.Windows.Forms.TextBox
$document.SetBounds(20,465,940,280)
$document.Multiline = $true
$document.ReadOnly = $true
$document.ScrollBars = 'Both'
$caption = New-Object System.Windows.Forms.Label
$caption.Text = 'Synthetic document - cleared before every fresh read; displayed only for real HTTP 200'
$caption.SetBounds(20,438,940,24)
$script:runs = @{ Live = [guid]::NewGuid(); Twin = [guid]::NewGuid() }
$script:armed = @{ Live = $false; Twin = $false }
$script:busy = $false
$buttons = @{}
$x = 20
foreach ($item in @(@('Arm','Arm new run'),@('Disable','BIG RED BUTTON'),@('Restore','Restore'),@('Read','Refresh Document'),@('Status','Status'),@('Reset','Reset'))) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $item[1]
    $button.Tag = $item[0]
    $button.SetBounds($x,110,150,50)
    if ($item[0] -eq 'Disable') { $button.BackColor = [System.Drawing.Color]::DarkRed; $button.ForeColor = [System.Drawing.Color]::White }
    $buttons[$item[0]] = $button
    $form.Controls.Add($button)
    $x += 158
}
$updateControls = {
    $target = [string]$selector.SelectedItem
    foreach ($name in $buttons.Keys) {
        $buttons[$name].Enabled = -not $script:busy -and ($AuthorizeLiveChanges -or $name -in 'Read','Status')
    }
    $buttons.Disable.Enabled = -not $script:busy -and $AuthorizeLiveChanges -and $script:armed[$target]
    $selector.Enabled = -not $script:busy
}
$selectTarget = {
    $target = [string]$selector.SelectedItem
    $document.Clear()
    $prefix = if ($target -eq 'Twin') { 'PRE-REVOKED FALLBACK ACCOUNT - readiness NOT assumed' } else { 'LIVE ACCOUNT' }
    $label.ForeColor = if ($target -eq 'Twin') { [System.Drawing.Color]::DarkRed } else { [System.Drawing.Color]::Black }
    $label.Text = "$prefix`r`nAccount: $($config.targets.$target.accountName)`r`nKey: $($config.targets.$target.keyName) / $($config.targets.$target.keyVersion)"
    $status.Text = "Selected $target. Run ID: $($script:runs[$target])`r`nNo automatic fallback. Press Status for host state.`r`nLive-change authorization: $AuthorizeLiveChanges"
    & $updateControls
}
$selector.add_SelectedIndexChanged($selectTarget)
$click = {
    param($clickedButton)
    if ($script:busy) { return }
    $action = [string]$clickedButton.Tag
    $target = [string]$selector.SelectedItem
    if ($action -eq 'Read') { $document.Clear() }
    if ($action -eq 'Arm') {
        if ($script:armed[$target]) { $status.Text = 'Already armed locally. Restore/reconcile the existing run before starting another.'; return }
        $script:runs[$target] = [guid]::NewGuid()
    }
    $script:busy = $true
    & $updateControls
    $status.Text = "Submitting $action for $target; run ID $($script:runs[$target]). Waiting for host response..."
    $form.Refresh()
    try {
        $response = & (Join-Path $PSScriptRoot 'Invoke-DemoControl.ps1') -ConfigPath $ConfigPath -Action $action -Target $target -RunId $script:runs[$target] -AuthorizeLiveChanges:$AuthorizeLiveChanges
        if ($action -eq 'Arm') {
            if ($response.state.phase -ne 'Armed' -or [string]$response.state.runId -ne $script:runs[$target].ToString('D')) {
                throw 'Host did not acknowledge Armed state for this run. Disable remains unavailable.'
            }
            $script:armed[$target] = $true
        }
        if ($action -eq 'Status' -and $response.state.runId) {
            $observedRun = [guid]::Parse([string]$response.state.runId)
            if ($observedRun -eq [guid]::Empty) { throw 'Host returned an invalid persisted run ID.' }
            $script:runs[$target] = $observedRun
            if ($response.state.phase -ne 'Armed') { $script:armed[$target] = $false }
        }
        if ($action -in 'Disable','Restore','Reset') { $script:armed[$target] = $false }
        $evidence = [ordered]@{
            action = $response.action; target = $response.target; account = $config.targets.$target.accountName
            requestedRunId = [string]$script:runs[$target]; state = $response.state
            heartbeatUtc = $response.heartbeatUtc; error = $response.error
        }
        if ($response.read) {
            $evidence.read = [ordered]@{
                status = $response.read.status; errorCode = $response.read.errorCode
                requestId = $response.read.requestId; clientRequestId = $response.read.clientRequestId
                utc = $response.read.utc; account = $response.read.account; target = $response.read.target
            }
        }
        $status.Text = $evidence | ConvertTo-Json -Depth 10
        if ($action -eq 'Read' -and $response.read -and [string]$response.read.status -ceq '200' -and
            $response.read.target -eq $target -and $response.read.account -eq $config.targets.$target.accountName) {
            $document.Text = [string]$response.read.content
        } elseif ($action -eq 'Read') { $status.AppendText("`r`nNo verified HTTP 200 for the selected account. No plaintext displayed.") }
    } catch {
        if ($action -eq 'Read') { $document.Clear() }
        $status.Text = "ERROR: $($_.Exception.Message)`r`nTarget: $target; requested run: $($script:runs[$target]). No automatic retry or target switch. Reconcile with Status / Restore."
    } finally {
        $script:busy = $false
        & $updateControls
    }
}
foreach ($button in $buttons.Values) { $button.add_Click($click) }
$form.Controls.AddRange(@($selector,$label,$status,$caption,$document))
$selector.SelectedIndex = 0
if ($SmokeTest) {
    $result = [pscustomobject]@{
        title = $form.Text
        actions = @($buttons.Keys | Sort-Object)
        disableEnabled = $buttons.Disable.Enabled
        target = [string]$selector.SelectedItem
        document = $document.Text
    }
    $form.Dispose()
    return $result
}
[void]$form.ShowDialog()
$form.Dispose()
# Closing the window intentionally does not stop, reset or disarm the host watchdog.

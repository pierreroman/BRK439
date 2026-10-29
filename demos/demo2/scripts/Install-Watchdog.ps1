[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-z_][a-z0-9_-]{0,31}$')][string]$AdminSshUser,
    [Parameter(Mandatory)][string]$OperatorPublicKeyPath,
    [string]$AdminIdentityFile,
    [switch]$AuthorizeHostChanges
)
$ErrorActionPreference = 'Stop'
if (-not $AuthorizeHostChanges) { throw 'Installation requires -AuthorizeHostChanges. No host operation was attempted.' }
Import-Module (Join-Path $PSScriptRoot 'Demo.Common.psm1') -Force
$config = Import-DemoConfig -Path $ConfigPath -Phase Runtime
if ($config.sshUser -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $config.sshUser -in 'root','demo2' -or $config.sshUser -eq $AdminSshUser) { throw 'Use a separate restricted operator account, not root, demo2, or the administrator.' }
if ([string]$config.sshHost -cnotmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') { throw 'Invalid SSH host.' }
$port = 0
if (-not [int]::TryParse([string]$config.sshPort,[ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Invalid SSH port.' }
$publicKey = (Get-Content -LiteralPath $OperatorPublicKeyPath -Raw).Trim()
if ($publicKey -cnotmatch '^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/]+={0,3}(?: [^\r\n]*)?$') { throw 'Expected one bare OpenSSH public key, without authorized_keys options.' }
$demoRoot = Split-Path $PSScriptRoot -Parent
$files = @(
    (Join-Path $demoRoot 'config.schema.json'),
    (Join-Path $PSScriptRoot 'Demo.Common.psm1'),
    (Join-Path $demoRoot 'host\Demo.Worker.psm1'),
    (Join-Path $demoRoot 'host\Start-Watchdog.ps1'),
    (Join-Path $demoRoot 'host\Submit-Request.ps1')
)
foreach ($file in $files) { if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing reviewed host artifact: $file" } }
$destination = "$AdminSshUser@$($config.sshHost)"
$sshArgs = @('-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10','-p',"$port")
$scpArgs = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10','-P',"$port")
if ($AdminIdentityFile) { $sshArgs += @('-i',$AdminIdentityFile); $scpArgs += @('-i',$AdminIdentityFile) }
function Invoke-Admin([string]$RemoteCommand) {
    & ssh @sshArgs $destination $RemoteCommand
    if ($LASTEXITCODE -ne 0) { throw "Administrator SSH command failed (exit $LASTEXITCODE)." }
}
function Copy-HostFile([string]$LocalPath,[string]$RemotePath) {
    & scp @scpArgs $LocalPath "${destination}:$RemotePath"
    if ($LASTEXITCODE -ne 0) { throw "SCP failed for $LocalPath (exit $LASTEXITCODE)." }
}
if (-not $PSCmdlet.ShouldProcess("$destination via port $port", 'Install reviewed watchdog, protected configuration, restricted operator SSH and systemd service')) { return }
$stage = ".demo2-install-$([guid]::NewGuid().ToString('N'))"
$localStage = Join-Path $demoRoot $stage
$remoteStage = "/var/lib/$stage"
$remoteCreated = $false
try {
    # Dependencies must already exist; this never installs packages from the network.
    Invoke-Admin 'test -x /usr/bin/pwsh && command -v logger && command -v systemctl && command -v sshd && command -v python3 && command -v useradd && command -v sudo && command -v sync'
    Invoke-Admin '/usr/bin/pwsh -NoProfile -NonInteractive -Command ''if ($PSVersionTable.PSVersion -lt [version]"7.4") { exit 1 }; $PSVersionTable.PSVersion.ToString()'''
    Invoke-Admin "sudo -n install -d -m 0700 -o $AdminSshUser $remoteStage"
    $remoteCreated = $true
    New-Item -ItemType Directory -Path $localStage | Out-Null
    $wrapper = @'
#!/usr/bin/python3
import os
import re
import sys
pattern = r"pwsh -NoProfile -File /opt/demo2/host/Submit-Request\.ps1 -Action (Arm|Disable|Restore|Read|Status|Reset) -Target (Live|Twin) -RunId ([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"
match = re.fullmatch(pattern, os.environ.get("SSH_ORIGINAL_COMMAND", ""))
if not match or match.group(3).replace("-", "") == "0" * 32:
    sys.stderr.write("demo2: only exact allowlisted Submit-Request commands are accepted\n")
    sys.exit(64)
os.umask(0o007)
os.execv("/usr/bin/pwsh", ["/usr/bin/pwsh", "-NoProfile", "-File", "/opt/demo2/host/Submit-Request.ps1", "-Action", match.group(1), "-Target", match.group(2), "-RunId", match.group(3)])
'@
    $service = @'
[Unit]
Description=Demo2 persistent key recovery watchdog
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=demo2
Group=demo2
SupplementaryGroups=demo2-operators
UMask=0027
WorkingDirectory=/opt/demo2
ExecStart=/usr/bin/pwsh -NoProfile -File /opt/demo2/host/Start-Watchdog.ps1 -ConfigPath /etc/demo2/config.json -AuthorizeLiveChanges
Restart=always
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/demo2 /var/spool/demo2
StandardOutput=journal
StandardError=journal
SyslogIdentifier=demo2

[Install]
WantedBy=multi-user.target
'@
    $operator = [string]$config.sshUser
    $sshdConfig = @"
Match User $operator
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthorizedKeysFile /etc/demo2/operator_authorized_keys
    ForceCommand /opt/demo2/submit-operator
    DisableForwarding yes
    PermitTTY no
    PermitUserRC no
Match all
"@
    $install = @'
#!/bin/sh
set -eu
stage="$1"
operator="$2"
test -x /usr/bin/pwsh
if systemctl is-active --quiet demo2-watchdog.service; then
    echo 'Existing watchdog is active: refuse in-place reinstall. Verify all keys restored, close runs and stop the service explicitly first.' >&2
    exit 1
fi
if test -d /var/lib/demo2; then
    /usr/bin/pwsh -NoProfile -Command '$ErrorActionPreference="Stop"; foreach ($name in "Live","Twin") { $p="/var/lib/demo2/$name.json"; if (Test-Path $p) { $s=Get-Content $p -Raw|ConvertFrom-Json; if ($s.phase -ne "Closed") { throw "A persisted run is not closed; manual recovery/reconciliation is required before reinstall." } } }'
fi
getent group demo2 >/dev/null || groupadd --system demo2
getent group demo2-operators >/dev/null || groupadd --system demo2-operators
if ! id demo2 >/dev/null 2>&1; then useradd --system --gid demo2 --home-dir /var/lib/demo2 --shell /usr/sbin/nologin demo2; fi
test "$(id -u demo2)" -ne 0
test "$(id -gn demo2)" = demo2
if ! id "$operator" >/dev/null 2>&1; then useradd --create-home --shell /bin/sh "$operator"; fi
test "$(id -u "$operator")" -ne 0
# Refuse unexpected supplementary groups; never repurpose an administrative user.
for group in $(id -Gn "$operator"); do
    case "$group" in "$operator"|demo2-operators) ;; *) echo "Operator has unexpected group: $group" >&2; exit 1 ;; esac
done
usermod -a -G demo2-operators "$operator"
install -d -m 0755 -o root -g root /opt/demo2 /opt/demo2/scripts /opt/demo2/host
install -m 0644 -o root -g root "$stage/config.schema.json" /opt/demo2/config.schema.json
install -m 0644 -o root -g root "$stage/Demo.Common.psm1" /opt/demo2/scripts/Demo.Common.psm1
for file in Demo.Worker.psm1 Start-Watchdog.ps1 Submit-Request.ps1; do
    install -m 0644 -o root -g root "$stage/$file" "/opt/demo2/host/$file"
done
install -m 0755 -o root -g root "$stage/submit-operator" /opt/demo2/submit-operator
install -d -m 0750 -o root -g demo2 /etc/demo2
# The operator needs traversal to the public-key file, not access to runtime config.
chmod 0755 /etc/demo2
install -m 0640 -o root -g demo2 "$stage/config.json" /etc/demo2/config.json
install -m 0644 -o root -g root "$stage/operator_authorized_keys" /etc/demo2/operator_authorized_keys
install -d -m 0700 -o demo2 -g demo2 /var/lib/demo2
install -d -m 0751 -o root -g root /var/spool/demo2
install -d -m 3770 -o demo2 -g demo2-operators /var/spool/demo2/requests
install -d -m 2750 -o demo2 -g demo2-operators /var/spool/demo2/responses
test -d /etc/ssh/sshd_config.d
grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config
test ! -L /etc/ssh/sshd_config.d/00-demo2-operator.conf
if test -e /etc/ssh/sshd_config.d/00-demo2-operator.conf; then
    cp /etc/ssh/sshd_config.d/00-demo2-operator.conf "$stage/previous-sshd.conf"
fi
install -m 0644 -o root -g root "$stage/sshd.conf" /etc/ssh/sshd_config.d/00-demo2-operator.conf
if ! sshd -t; then
    if test -e "$stage/previous-sshd.conf"; then
        cp "$stage/previous-sshd.conf" /etc/ssh/sshd_config.d/00-demo2-operator.conf
    else
        rm /etc/ssh/sshd_config.d/00-demo2-operator.conf
    fi
    exit 1
fi
sshd -T -C "user=$operator,host=localhost,addr=127.0.0.1" > "$stage/effective-sshd"
grep -Fx 'forcecommand /opt/demo2/submit-operator' "$stage/effective-sshd"
grep -Fx 'disableforwarding yes' "$stage/effective-sshd"
grep -Fx 'permittty no' "$stage/effective-sshd"
grep -Fx 'authorizedkeysfile /etc/demo2/operator_authorized_keys' "$stage/effective-sshd"
grep -Fx 'authenticationmethods publickey' "$stage/effective-sshd"
install -m 0644 -o root -g root "$stage/demo2-watchdog.service" /etc/systemd/system/demo2-watchdog.service
systemctl daemon-reload
systemctl enable --now demo2-watchdog.service
systemctl is-active --quiet demo2-watchdog.service
ready=false
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if python3 -c 'import datetime,json; p="/var/spool/demo2/responses/heartbeat.json"; h=json.load(open(p)); t=datetime.datetime.fromisoformat(h["utc"]); age=(datetime.datetime.now(datetime.timezone.utc)-t).total_seconds(); raise SystemExit(0 if 0 <= age < 30 else 1)' 2>/dev/null; then ready=true; break; fi
    sleep 5
done
if test "$ready" != true; then echo 'Watchdog did not produce a fresh heartbeat; inspect journal and do not arm.' >&2; exit 1; fi
if systemctl is-active --quiet ssh.service; then systemctl reload ssh.service; else systemctl reload sshd.service; fi
logger -p user.notice -t demo2 'watchdog installed; verify heartbeat and recovery evidence before arming'
systemctl --no-pager status demo2-watchdog.service
'@
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $generated = @{
        'submit-operator' = $wrapper; 'demo2-watchdog.service' = $service
        'sshd.conf' = $sshdConfig; 'install.sh' = $install
        'operator_authorized_keys' = "restrict,command=`"/opt/demo2/submit-operator`" $publicKey`n"
    }
    foreach ($entry in $generated.GetEnumerator()) {
        [System.IO.File]::WriteAllText((Join-Path $localStage $entry.Key),($entry.Value -replace "`r`n","`n"),$utf8)
    }
    foreach ($file in $files) { Copy-HostFile $file "$remoteStage/$(Split-Path $file -Leaf)" }
    Copy-HostFile (Resolve-Path -LiteralPath $ConfigPath).Path "$remoteStage/config.json"
    foreach ($name in $generated.Keys) { Copy-HostFile (Join-Path $localStage $name) "$remoteStage/$name" }
    Invoke-Admin "sudo -n /bin/sh $remoteStage/install.sh $remoteStage $operator"
    Write-Output 'Host installation completed. No live readiness is implied: verify restricted login, independent heartbeat, read and recovery behavior in an authorized rehearsal.'
} finally {
    if ($remoteCreated) {
        & ssh @sshArgs $destination "sudo -n rm -rf -- $remoteStage"
        if ($LASTEXITCODE -ne 0) { Write-Error "Remote staging cleanup failed (exit $LASTEXITCODE): $remoteStage" }
    }
    if (Test-Path -LiteralPath $localStage) { Remove-Item -LiteralPath $localStage -Recurse -Force }
}

#!/bin/bash
set -Eeuo pipefail
umask 077
phase=Platform
trap 'rc=$?; printf "DEMO2_PREPARE_ERROR phase=%s line=%s exit=%s\n" "$phase" "$LINENO" "$rc" >&2; exit "$rc"' ERR
test "$(id -u)" = 0
. /etc/os-release
test "$ID" = ubuntu
test "$VERSION_ID" = 22.04
test "$(dpkg --print-architecture)" = amd64
id="$1"
subscription="$2"
vm="$3"
disk="$4"
[[ "$id" =~ ^[a-f0-9]{32}$ ]]
stage="/var/lib/demo2-setup/$id"
install -d -m 0700 "$stage"
phase=Identity
python3 - "$subscription" "$vm" "$disk" <<'PY'
import json,sys,urllib.request
r=urllib.request.Request('http://169.254.169.254/metadata/instance?api-version=2021-02-01',headers={'Metadata':'true'})
with urllib.request.urlopen(r,timeout=10) as response:
    m=json.load(response)['compute']
assert m['subscriptionId'].lower()==sys.argv[1].lower() and m['name']==sys.argv[2], 'Unexpected VM identity'
disks=[d for d in m['storageProfile']['dataDisks'] if str(d['lun'])=='0']
assert len(disks)==1 and disks[0]['managedDisk']['id'].lower()==sys.argv[3].lower(), 'Unexpected managed custody disk'
PY
phase=Device
device=""
for candidate in /dev/disk/azure/scsi1/lun0 /dev/disk/azure/data/by-lun/0; do
    if test -b "$candidate"; then device="$(readlink -f "$candidate")"; break; fi
done
test -n "$device"
test "$(blockdev --getsize64 "$device")" = 34359738368
phase=DiskInspect
if test "${DEMO2_REQUIRE_EXISTING_DISK:-0}" = 1; then
    test -f "$stage/disk.json"
    mountpoint -q /mnt/dispo-keys
fi
if test -f "$stage/disk.json"; then
    uuid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uuid"])' "$stage/disk.json")"
    test "$(blkid -s UUID -o value "$device")" = "$uuid"
    test "$(blkid -s TYPE -o value "$device")" = ext4
else
    test "$(lsblk -nr -o NAME "$device" | wc -l)" = 1
    test -z "$(lsblk -nr -o MOUNTPOINTS "$device")"
    test -z "$(wipefs --no-act "$device")"
    phase=DiskFormat
    mkfs.ext4 -q "$device"
    uuid="$(blkid -s UUID -o value "$device")"
    python3 - "$stage/disk.json" "$uuid" <<'PY'
import json,os,sys
with open(sys.argv[1]+'.tmp','x') as f:
    json.dump({'uuid':sys.argv[2]},f);f.flush();os.fsync(f.fileno())
os.replace(sys.argv[1]+'.tmp',sys.argv[1])
PY
fi
phase=Mount
if mountpoint -q /mnt/dispo-keys; then
    test "$(findmnt -n -o UUID --target /mnt/dispo-keys)" = "$uuid"
else
    if test -e /mnt/dispo-keys; then
        test -d /mnt/dispo-keys
        test -z "$(ls -A /mnt/dispo-keys)"
    fi
    install -d -m 0700 /mnt/dispo-keys
    mount -o nodev,nosuid,noexec "UUID=$uuid" /mnt/dispo-keys
fi
chmod 0700 /mnt/dispo-keys
if ! grep -Fq "UUID=$uuid /mnt/dispo-keys " /etc/fstab; then
    ! grep -Eq '^[^#].*[[:space:]]/mnt/dispo-keys[[:space:]]' /etc/fstab
    printf 'UUID=%s /mnt/dispo-keys ext4 defaults,nodev,nosuid,noexec,nofail 0 2\n' "$uuid" >> /etc/fstab
fi
phase=Repositories
# Retire only byte-identical files written by the preceding field-host script.
install -d -m 0700 "$stage/legacy-repositories"
for product in powershell azure-cli; do
    old="/etc/apt/sources.list.d/demo2-$product.list"
    repository=https://packages.microsoft.com/ubuntu/22.04/prod
    if test "$product" = azure-cli; then repository=https://packages.microsoft.com/repos/azure-cli/; fi
    expected="$stage/legacy-repositories/expected-$product"
    printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/demo2-microsoft.gpg] %s jammy main\n' "$repository" > "$expected"
    if test -e "$old" || test -L "$old"; then
        test ! -L "$old"
        cmp -s "$old" "$expected"
        saved="$stage/legacy-repositories/demo2-$product.list.disabled"
        if test -e "$saved"; then
            cmp -s "$old" "$saved"
            rm -- "$old"
        else
            mv -- "$old" "$saved"
        fi
    fi
done
if ! command -v pwsh >/dev/null || ! command -v az >/dev/null; then
    apt_directory="/etc/apt/demo2/$id"
    apt_lists="/var/lib/apt/demo2/$id/lists"
    install -d -m 0755 "$apt_directory" "$apt_lists"
    test -f /usr/share/keyrings/ubuntu-archive-keyring.gpg
    sources="$apt_directory/sources.list"
    printf '%s\n' \
        'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse' \
        'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse' \
        'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse' > "$sources"
    chmod 0644 "$sources"
    apt_options=(-o "Dir::Etc::sourcelist=$sources" -o 'Dir::Etc::sourceparts=-' -o "Dir::State::lists=$apt_lists")
    phase=Dependencies
    apt-get "${apt_options[@]}" update -qq
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y -qq ca-certificates curl gnupg
    phase=SigningKey
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --silent --show-error https://packages.microsoft.com/keys/microsoft.asc -o "$stage/microsoft.asc"
    fingerprint="$(gpg --show-keys --with-colons "$stage/microsoft.asc" | awk -F: '$1=="fpr"{print $10;exit}')"
    test "$fingerprint" = BC528686B50D79E339D3721CEB3E94ADBE1229CF
    gpg --dearmor --yes --output /etc/apt/keyrings/demo2-microsoft.gpg "$stage/microsoft.asc"
    chmod 0644 /etc/apt/keyrings/demo2-microsoft.gpg
    printf '%s\n' \
        'deb [arch=amd64 signed-by=/etc/apt/keyrings/demo2-microsoft.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main' \
        'deb [arch=amd64 signed-by=/etc/apt/keyrings/demo2-microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ jammy main' >> "$sources"
    phase=Packages
    apt-get "${apt_options[@]}" update -qq
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y -qq powershell azure-cli
fi
phase=PowerShell
pwsh -NoProfile -NonInteractive -Command 'if ($PSVersionTable.PSVersion -lt [version]"7.4") { throw "Guest PowerShell 7.4+ required" }'
phase=TimeSync
timedatectl show -p NTPSynchronized --value | grep -Fx yes
printf 'FIELD_HOST_PREPARED\n'

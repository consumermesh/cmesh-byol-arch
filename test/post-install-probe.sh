#!/bin/bash
# READ-ONLY post-install diagnostic for the cmesh-byol-arch encrypted install.
#
# Run from the OVHcloud rescue system. Every mount is read-only, or a targeted
# `cryptsetup open` that only creates a device-mapper node. Nothing on the target is
# modified.
#
#   curl -fsSL https://raw.githubusercontent.com/consumermesh/cmesh-byol-arch/main/test/post-install-probe.sh | bash
#
# It answers, in order:
#   1. Did the installer RUN at all?          (the marker + its log)
#   2. Did it get as far as LUKS + RAID?      (the partition layout)
#   3. Did it COMPLETE?                       (the marker is written last)
#   4. If it completed, why is SSH dead?      (sshd enabled? key present?)

set -u

hdr() { printf '\n===== %s =====\n' "$*"; }

hdr "0. tools present in rescue?"
for t in cryptsetup mdadm blkid lsblk sgdisk; do
    printf '  %-12s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
done

hdr "1. current partition layout"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>&1

hdr "2. what is on each partition"
for p in /dev/nvme0n1p1 /dev/nvme0n1p2 /dev/nvme0n1p3 \
         /dev/nvme1n1p1 /dev/nvme1n1p2 /dev/nvme1n1p3; do
    [ -b "$p" ] || continue
    printf '  %-18s %-12s ' "$p" "$(blkid -o value -s TYPE "$p" 2>/dev/null)"
    cryptsetup isLuks "$p" >/dev/null 2>&1 && echo "LUKS" || echo ""
done

hdr "3. arrays"
cat /proc/mdstat 2>&1

# ---------------------------------------------------------------------------
# Rebuild the stack the installer creates, READ-ONLY where possible.
#
#   p2  ->  md2            (/boot, unencrypted ext4)
#   p3  ->  cryptroot0/1   ->  md3   (/ ,  ext4 inside LUKS)
# ---------------------------------------------------------------------------
hdr "4. unlocking the encrypted root"
echo "If prompted, enter the LUKS passphrase (from configDriveUserData)."
echo "If it is NOT prompted for, that itself is the finding: no LUKS container exists."
echo

unlocked=0
if cryptsetup isLuks /dev/nvme0n1p3 2>/dev/null; then
    cryptsetup open /dev/nvme0n1p3 cryptroot0 && unlocked=$((unlocked + 1))
    cryptsetup open /dev/nvme1n1p3 cryptroot1 && unlocked=$((unlocked + 1))
else
    echo ">>> /dev/nvme0n1p3 is NOT a LUKS device -> the installer never reached LUKS."
    echo ">>> Everything below will be skipped; the finding is already conclusive."
fi

if [ "$unlocked" -eq 2 ]; then
    mdadm --assemble /dev/md3 /dev/mapper/cryptroot0 /dev/mapper/cryptroot1 2>&1
fi
mdadm --assemble /dev/md2 /dev/nvme0n1p2 /dev/nvme1n1p2 2>&1

hdr "5. did the install COMPLETE?  (marker is written last, just before reboot)"
M=/mnt/probe
mkdir -p "$M"
ROOTMNT=""
if [ -b /dev/md3 ] && mount -o ro /dev/md3 "$M" 2>/dev/null; then
    ROOTMNT="$M"
elif mount -o ro /dev/nvme0n1p3 "$M" 2>/dev/null; then
    ROOTMNT="$M"
    echo "!!! mounted the RAW partition: this is NOT an encrypted install."
fi

if [ -n "$ROOTMNT" ]; then
    echo "mounted root read-only at $M"
    echo -n "  os-release   : "; head -2 "$M/etc/os-release" 2>&1 | tr '\n' ' '; echo
    echo -n "  INSTALL MARKER: "
    if [ -f "$M/var/lib/cmesh-byol/installed" ]; then
        echo "PRESENT -> install completed  (contents: $(cat "$M/var/lib/cmesh-byol/installed" 2>/dev/null))"
    else
        echo "ABSENT -> the install did NOT finish"
    fi

    hdr "5a. installer log (exists only once the installer starts)"
    if [ -f "$M/var/log/cmesh-byol-install.log" ]; then
        echo "--- last 40 lines ---"
        tail -40 "$M/var/log/cmesh-byol-install.log"
    else
        echo ">>> ABSENT — the installer still never ran, or died before its first write."
    fi

    hdr "5b. why is SSH dead?"
    echo -n "  sshd enabled?  "
    if [ -e "$M/etc/systemd/system/multi-user.target.wants/sshd.service" ] \
       || [ -e "$M/etc/systemd/system/multi-user.target.wants/ssh.service" ]; then
        echo "YES"
    else
        echo "NO  <-- this is the problem"
    fi
    echo -n "  authorized_keys: "
    if [ -s "$M/root/.ssh/authorized_keys" ]; then
        echo "present ($(grep -c . "$M/root/.ssh/authorized_keys") key(s))"
        sed 's/\(.\{40\}\).*/\1.../' "$M/root/.ssh/authorized_keys" | sed 's/^/      /'
    else
        echo "MISSING or empty  <-- no way in even with sshd running"
    fi
    echo "  --- perms ---"
    ls -la "$M/root/.ssh/" 2>&1 | sed 's/^/      /'

    hdr "5c. network config on the installed system"
    cat "$M/etc/systemd/network/20-wired.network" 2>&1 | sed 's/^/      /'
    echo "  --- networkd enabled? ---"
    for u in systemd-networkd systemd-resolved; do
        printf '      %-20s %s\n' "$u" \
            "$([ -e "$M/etc/systemd/system/dbus-org.freedesktop.network1.service" ] && echo enabled || echo 'check symlinks')"
    done
    ls -la "$M/etc/systemd/system/multi-user.target.wants/" 2>&1 | grep -Ei 'network|resolve|ssh' | sed 's/^/      /'

    hdr "5d. finalize unit + LUKS key (post-TPM state)"
    ls -la "$M/boot/cmesh-luks.key" 2>&1 | sed 's/^/      /'
    ls -la "$M/var/lib/cmesh-byol/" 2>&1 | sed 's/^/      /'

    hdr "5e. journal from the installed system"
    ls -la "$M/var/log/journal/" 2>&1 | sed 's/^/      /'

    umount "$M" 2>&1
else
    echo "could not mount any root filesystem — the disks may never have been partitioned"
fi

hdr "6. /boot array (initramfs + kernel present?)"
B=/mnt/probe-boot
mkdir -p "$B"
if mount -o ro /dev/md2 "$B" 2>/dev/null; then
    ls -la "$B" 2>&1 | sed 's/^/      /'
    echo "  --- crypttab inside the initramfs? (sd-encrypt needs it) ---"
    for img in "$B"/initramfs-linux*.img; do
        [ -f "$img" ] || continue
        printf '      %s: ' "$(basename "$img")"
        zstd -dc "$img" 2>/dev/null | grep -aq 'cryptroot' && echo "contains cryptroot" || echo "NO cryptroot reference"
    done
    umount "$B" 2>&1
else
    echo "could not mount /dev/md2"
fi

hdr "done"
echo "Send everything above verbatim."

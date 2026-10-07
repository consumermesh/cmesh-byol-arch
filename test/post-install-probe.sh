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
#   1. Did the installer RUN at all?          (the marker + its log on the bootstrap root)
#   2. Did it get as far as LUKS + RAID?      (crypto_LUKS on the payload members)
#   3. Did it COMPLETE?                       (the marker is written last, on both roots)
#   4. If it completed, why is SSH dead?      (sshd enabled? key present?)
#
# Layout it expects (all created by OVHcloud's partitioner; see README):
#   /boot      raid1 ext4   shared by the bootstrap and the installed system
#   /          raid1 ext4   the BOOTSTRAP root -- stays on disk, holds the installer log
#   /data      raid1        the PAYLOAD: its members become LUKS2 -> md/cmeshroot -> /
# Nothing is addressed by partition number here; everything is found by signature.

set -u

hdr() { printf '\n===== %s =====\n' "$*"; }

hdr "0. tools present in rescue?"
for t in cryptsetup mdadm blkid lsblk findmnt; do
    printf '  %-12s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
done

hdr "1. current layout"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>&1

hdr "2. what is on each partition"
blkid 2>&1 | sed 's/^/  /'

# Bring up the plain arrays (/boot and the bootstrap root). The encrypted one cannot
# assemble until its members are unlocked below.
hdr "3. assembling the unencrypted arrays"
mdadm --assemble --scan 2>&1 || true
cat /proc/mdstat 2>&1

# ---------------------------------------------------------------------------
# Find things by signature, not by partition number.
# ---------------------------------------------------------------------------
mapfile -t LUKS_DEVS < <(blkid -o device -t TYPE=crypto_LUKS 2>/dev/null | sort)
hdr "4. LUKS containers found: ${#LUKS_DEVS[@]} (${LUKS_DEVS[*]:-none})"
if [ "${#LUKS_DEVS[@]}" -eq 0 ]; then
    echo ">>> no crypto_LUKS signature anywhere -> the installer never reached luksFormat."
    echo ">>> The decisive artefact is its log on the bootstrap root; see section 6."
elif [ "${#LUKS_DEVS[@]}" -ne 2 ]; then
    echo ">>> expected exactly 2 (one per disk); the install was interrupted mid-format."
fi

unlocked=0
if [ "${#LUKS_DEVS[@]}" -gt 0 ]; then
    echo "If prompted, enter the LUKS passphrase (from configDriveUserData)."
    i=0
    for d in "${LUKS_DEVS[@]}"; do
        if cryptsetup open "$d" "cryptroot${i}" 2>&1; then
            unlocked=$((unlocked + 1))
        fi
        i=$((i + 1))
    done
    if [ "$unlocked" -ge 1 ]; then
        hdr "4a. assembling the encrypted root"
        mdadm --assemble --scan 2>&1 || true
        mdadm --assemble /dev/md/cmeshroot /dev/mapper/cryptroot* 2>&1 || true
        cat /proc/mdstat 2>&1
    fi
fi

# ---------------------------------------------------------------------------
# Mount every ext4 array read-only and classify it by what it contains.
# ---------------------------------------------------------------------------
hdr "5. classifying the ext4 arrays"
ROOT_ENC=""; ROOT_BOOTSTRAP=""; BOOT_DEV=""
for md in /dev/md/* /dev/md[0-9]*; do
    [ -b "$md" ] || continue
    real=$(readlink -f "$md")
    [ "$(blkid -o value -s TYPE "$real" 2>/dev/null)" = "ext4" ] || continue
    m=$(mktemp -d)
    if mount -o ro "$real" "$m" 2>/dev/null; then
        kind="?"
        if [ -f "$m/grub/grub.cfg" ] || [ -f "$m/vmlinuz-linux" ]; then
            kind="/boot"; BOOT_DEV="$real"
        elif [ -f "$m/etc/crypttab.initramfs" ] && grep -q cryptroot "$m/etc/crypttab.initramfs" 2>/dev/null; then
            kind="encrypted root"; ROOT_ENC="$real"
        elif [ -f "$m/etc/arch-release" ]; then
            kind="bootstrap root"; ROOT_BOOTSTRAP="$real"
        fi
        printf '  %-14s %-18s label=%s\n' "$real" "$kind" "$(blkid -o value -s LABEL "$real" 2>/dev/null)"
        umount "$m"
    else
        printf '  %-14s could not mount read-only\n' "$real"
    fi
    rmdir "$m"
done
# Avoid double-counting the same array reached via two names.
echo "  boot=${BOOT_DEV:-none}  bootstrap-root=${ROOT_BOOTSTRAP:-none}  encrypted-root=${ROOT_ENC:-none}"

show_root() { # show_root <device> <title>
    local dev=$1 title=$2 M
    M=$(mktemp -d)
    hdr "$title ($dev)"
    if ! mount -o ro "$dev" "$M" 2>&1; then
        echo "could not mount"; rmdir "$M"; return
    fi
    echo -n "  INSTALL MARKER: "
    if [ -f "$M/var/lib/cmesh-byol/installed" ]; then
        echo "PRESENT ($(cat "$M/var/lib/cmesh-byol/installed" 2>/dev/null))"
    else
        echo "ABSENT"
    fi
    echo "  --- installer log (last 40 lines) ---"
    if [ -f "$M/var/log/cmesh-byol-install.log" ]; then
        tail -40 "$M/var/log/cmesh-byol-install.log" | sed 's/^/      /'
    else
        echo "      ABSENT (the installer never started here, or this is not where it logs)"
    fi
    echo "  --- deploy hook log present? ---"
    ls -la "$M/var/log/ovh-make-bootable.log" 2>&1 | sed 's/^/      /'
    echo "  --- installer unit enabled here? ---"
    ls -la "$M/etc/systemd/system/multi-user.target.wants/" 2>&1 | grep -i cmesh | sed 's/^/      /' || echo "      (no cmesh unit enabled)"
    echo "  --- sshd enabled? ---"
    if [ -e "$M/etc/systemd/system/multi-user.target.wants/sshd.service" ]; then echo "      YES"; else echo "      NO"; fi
    echo "  --- root authorized_keys ---"
    if [ -s "$M/root/.ssh/authorized_keys" ]; then
        sed 's/\(.\{40\}\).*/\1.../' "$M/root/.ssh/authorized_keys" | sed 's/^/      /'
    else
        echo "      MISSING or empty"
    fi
    echo "  --- fstab ---"
    cat "$M/etc/fstab" 2>&1 | sed 's/^/      /'
    echo "  --- crypttab.initramfs ---"
    cat "$M/etc/crypttab.initramfs" 2>&1 | sed 's/^/      /'
    echo "  --- mdadm.conf ---"
    cat "$M/etc/mdadm.conf" 2>&1 | sed 's/^/      /'
    echo "  --- network ---"
    cat "$M/etc/systemd/network/20-wired.network" 2>&1 | sed 's/^/      /'
    umount "$M"; rmdir "$M"
}

[ -n "$ROOT_BOOTSTRAP" ] && show_root "$ROOT_BOOTSTRAP" "6. BOOTSTRAP root — where the installer logs"
[ -n "$ROOT_ENC" ]       && show_root "$ROOT_ENC"       "7. ENCRYPTED root — the installed system"
[ -z "$ROOT_BOOTSTRAP$ROOT_ENC" ] && { hdr "6/7"; echo "no root filesystem could be mounted"; }

hdr "8. /boot (shared): kernel, initramfs, grub.cfg, keyfile"
if [ -n "$BOOT_DEV" ]; then
    B=$(mktemp -d)
    if mount -o ro "$BOOT_DEV" "$B" 2>/dev/null; then
        ls -la "$B" 2>&1 | sed 's/^/      /'
        echo "  --- grub.cfg root= ---"
        grep -o 'root=[^ ]*' "$B/grub/grub.cfg" 2>/dev/null | sort -u | sed 's/^/      /'
        echo "  --- does the initramfs carry the crypttab and keyfile? ---"
        for img in "$B"/initramfs-linux*.img; do
            [ -f "$img" ] || continue
            printf '      %s: ' "$(basename "$img")"
            if command -v lsinitcpio >/dev/null 2>&1; then
                lsinitcpio "$img" 2>/dev/null | grep -E 'etc/crypttab|cmesh-luks.key' | tr '\n' ' '; echo
            else
                zstd -dc "$img" 2>/dev/null | grep -aq 'cryptroot' && echo "contains cryptroot" || echo "NO cryptroot reference"
            fi
        done
        umount "$B"
    else
        echo "could not mount $BOOT_DEV"
    fi
    rmdir "$B"
else
    echo "no /boot array identified"
fi

hdr "9. ESPs: is the removable loader present?"
for esp in $(blkid -o device -t PARTTYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b 2>/dev/null); do
    E=$(mktemp -d)
    if mount -o ro "$esp" "$E" 2>/dev/null; then
        if [ -f "$E/EFI/BOOT/BOOTX64.EFI" ]; then
            echo "  $esp: BOOTX64.EFI present ($(stat -c %s "$E/EFI/BOOT/BOOTX64.EFI") bytes)"
        else
            echo "  $esp: BOOTX64.EFI ABSENT"
        fi
        umount "$E"
    else
        echo "  $esp: could not mount"
    fi
    rmdir "$E"
done

hdr "done"
echo "Send everything above verbatim."

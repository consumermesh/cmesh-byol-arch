#!/bin/bash
# READ-ONLY diagnostic for the ns5004419 BYOLinux deploy failure.
#
# Run this from the OVHcloud rescue system (Debian). It mounts disks READ-ONLY and
# changes nothing on them. Paste as one command:
#
#   curl -fsSL https://raw.githubusercontent.com/consumermesh/cmesh-byol-arch/main/test/rescue-probe.sh | bash
#
# The question it answers first: did the v13 hook even run? If /var/log/ovh-make-bootable.log
# exists on the deployed root, it did, and the log says exactly which step failed and what
# the disk layout looked like. If it does not exist, the image that was deployed predates
# the logging, and nothing about the hook can be diagnosed from here.

set -u

hdr() { printf '\n===== %s =====\n' "$*"; }

hdr "disks"
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL,MOUNTPOINT 2>&1

hdr "partition type GUIDs"
for d in /dev/nvme0n1 /dev/nvme1n1 /dev/sda /dev/sdb; do
    [ -b "$d" ] || continue
    echo "--- $d ---"
    lsblk -rpnlo NAME,SIZE,PARTTYPE,PARTLABEL "$d" 2>&1
done

hdr "already mounted?"
cat /proc/mounts 2>&1 | grep -Ei 'nvme|md[0-9]|mapper|sd[a-z]' || echo "(no target devices mounted)"

# Bring up any md array so its members can be inspected. Assemble is refused unless every
# member is present, so a clean mirror will assemble; a half-written one will not, and
# that is itself the finding.
hdr "md arrays"
mdadm --assemble --scan 2>&1 || true
cat /proc/mdstat 2>&1

# The deployed root is the qcow2 image's single ext4 partition, rsynced onto nvme0n1p2.
ROOT_DEV=""
for cand in /dev/md2 /dev/md1 /dev/md0 /dev/nvme0n1p2 /dev/nvme0n1p3 /dev/nvme0n1p1; do
    [ -b "$cand" ] || continue
    if blkid -o value -s TYPE "$cand" 2>/dev/null | grep -q '^ext4$'; then
        ROOT_DEV="$cand"
        break
    fi
done
echo "candidate root device: ${ROOT_DEV:-none found}"

if [ -n "$ROOT_DEV" ]; then
    MNT=/mnt/cmeshprobe
    mkdir -p "$MNT"
    if mount -o ro "$ROOT_DEV" "$MNT" 2>&1; then
        hdr "HOOK LOG — the decisive artefact"
        if [ -f "$MNT/var/log/ovh-make-bootable.log" ]; then
            echo ">>> FOUND: the v13 logging hook ran."
            echo ">>> mtime: $(stat -c '%y' "$MNT/var/log/ovh-make-bootable.log" 2>/dev/null)"
            echo "--- full log ---"
            cat "$MNT/var/log/ovh-make-bootable.log"
            echo "--- end log ---"
        else
            echo ">>> ABSENT: /var/log/ovh-make-bootable.log does not exist."
            echo ">>> If v13 was deployed this means the hook died before its first write,"
            echo ">>> or an older image was deployed."
            echo "--- any 'ovh' / 'bootable' files anywhere on the root? ---"
            find "$MNT" -maxdepth 4 \( -iname '*ovh*' -o -iname '*bootable*' \) 2>/dev/null | head -20
            echo "--- /var/log contents ---"
            ls -la "$MNT/var/log" 2>&1 | head -30
        fi

        hdr "was the hook shipped in the image?"
        ls -la "$MNT/root/.ovh/" 2>&1
        echo "--- first lines of the shipped hook ---"
        head -5 "$MNT/root/.ovh/make_image_bootable.sh" 2>&1

        hdr "does the image carry the v13 log_path marker?"
        grep -c 'log_path' "$MNT/root/.ovh/make_image_bootable.sh" 2>/dev/null \
            && echo "(1+ means v13's hook; 0 means an older hook)" \
            || echo "0 occurrences (older hook, or file unreadable)"

        hdr "bootstrap kernel / initramfs timestamps (image build time)"
        stat -c '%n  %y' "$MNT/boot/vmlinuz-linux" "$MNT/boot/initramfs-linux.img" 2>&1

        hdr "does the shipped initramfs carry nvme + raid1?"
        if [ -f "$MNT/boot/initramfs-linux.img" ]; then
            for mod in nvme raid1; do
                if zstd -dc "$MNT/boot/initramfs-linux.img" 2>/dev/null | grep -aq "$mod"; then
                    echo "  $mod: present"
                else
                    echo "  $mod: ABSENT"
                fi
            done
        fi

        hdr "did the first-boot installer ever run?"
        ls -la "$MNT/var/lib/cmesh-byol/" 2>&1
        echo "--- installer unit enabled? ---"
        ls -la "$MNT/etc/systemd/system/multi-user.target.wants/" 2>&1 | grep -i cmesh || echo "(no cmesh unit enabled)"
        echo "--- any journal from the bootstrap boot? ---"
        ls -la "$MNT/var/log/journal/" 2>&1 | head -10

        umount "$MNT" 2>&1
    else
        echo "could not mount $ROOT_DEV read-only"
    fi
fi

# The ESP is what the hook has to write to. Read it directly: OVH formats it at deploy
# time, so anything here was written by the hook.
hdr "EFI System Partitions — did the hook write a loader?"
for esp in /dev/nvme0n1p1 /dev/nvme1n1p1 /dev/md0; do
    [ -b "$esp" ] || continue
    fstype=$(blkid -o value -s TYPE "$esp" 2>/dev/null)
    [ "$fstype" = "vfat" ] || continue
    EM=/mnt/cmesp
    mkdir -p "$EM"
    if mount -o ro "$esp" "$EM" 2>/dev/null; then
        echo "--- $esp (vfat) ---"
        find "$EM" -maxdepth 3 2>&1 | sed 's/^/  /'
        if [ -f "$EM/EFI/BOOT/BOOTX64.EFI" ]; then
            echo "  >>> BOOTX64.EFI PRESENT ($(stat -c %s "$EM/EFI/BOOT/BOOTX64.EFI") bytes, $(stat -c %y "$EM/EFI/BOOT/BOOTX64.EFI"))"
        else
            echo "  >>> BOOTX64.EFI ABSENT — this is why it does not boot"
        fi
        umount "$EM" 2>&1
    else
        echo "--- $esp: could not mount ---"
    fi
done

hdr "done"
echo "Send everything above back verbatim."

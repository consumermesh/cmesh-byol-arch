#!/bin/bash
# Guards the installer's contract with the disks: it must never touch a partition that the
# running system depends on, and everything it writes for the installed system must be
# stable across reboots.
#
# WHY THIS EXISTS
#
# The installer originally wiped both disks and re-created every partition from a system
# whose root was on those very disks. The kernel does not reload a partition table while a
# partition is held open, so every step after the wipe ran against the OLD, busy
# partitions and failed -- after the signatures were already gone. The fix is structural:
# OVHcloud's partitioner creates the final layout, and the installer only ever destroys the
# one partition that nothing runs from (the payload, mounted at /data). These assertions
# keep that structure from drifting back.
#
# Usage: test/installer-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALLER="$REPO/build_archlinux/files/cmesh-byol-install"

[ -f "$INSTALLER" ] || { echo "FATAL: $INSTALLER not found" >&2; exit 1; }

PASS=0
FAIL=0
check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok    %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}
# Comment lines are dropped first: the header explains what the old design did, and a
# test that fails on a word in a comment is a test that cannot explain itself.
#
# Stripped once into a file rather than piped per check: under `pipefail`, `grep -q`
# exiting on its first match can SIGPIPE the producer and turn a hit into a "no".
CODE="$(mktemp)"
trap 'rm -f "$CODE"' EXIT
grep -v '^[[:space:]]*#' "$INSTALLER" > "$CODE"
has()   { grep -q -- "$1" "$CODE" && echo yes || echo no; }
count() { grep -c -- "$1" "$CODE" || true; }
# Line number of the first match, or empty.
line_of() { grep -n -- "$1" "$INSTALLER" | head -1 | cut -d: -f1; }
# Body of a shell function.
fn() { awk "/^$1\\(\\)/,/^}/" "$INSTALLER"; }
# Order of two calls inside main().
main_order() { # main_order <first> <second> -> yes if <first> precedes <second> in main()
    local a b
    a=$(awk '/^main\(\)/,/^}/' "$INSTALLER" | grep -n "^[[:space:]]*$1\b" | head -1 | cut -d: -f1)
    b=$(awk '/^main\(\)/,/^}/' "$INSTALLER" | grep -n "^[[:space:]]*$2\b" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo yes || echo no
}

echo "(1) the partition table is never rewritten"
check "no sgdisk" "0" "$(count 'sgdisk')"
check "no partprobe / rereadpt" "0" "$(count 'rereadpt\|partprobe')"
check "no wipefs of a whole disk" "0" "$(count 'wipefs -a "\$d"')"
check "no partition_disks function" "0" "$(count '^partition_disks')"
check "no mkfs.vfat (the deployer's ESPs are reused)" "0" "$(count 'mkfs.vfat')"
check "no grub-install (the deploy hook owns the ESP)" "0" "$(count 'grub-install')"

echo
echo "(2) the payload is found through its mount, and only it is destroyed"
check "DATA_MOUNT is defined" "yes" "$(has '^readonly DATA_MOUNT=/data')"
check "payload resolved with findmnt on DATA_MOUNT" \
    "yes" "$(fn check_layout | grep -q 'findmnt -no SOURCE "\$DATA_MOUNT"' && echo yes || echo no)"
check "refuses unless the payload is a raid1 array" \
    "yes" "$(fn check_layout | grep -q 'raid1) ;;' && echo yes || echo no)"
check "refuses if / is on the payload" \
    "yes" "$(fn check_layout | grep -q 'is on the payload array' && echo yes || echo no)"
check "refuses if a member has another holder" \
    "yes" "$(fn check_layout | grep -q 'holders' && echo yes || echo no)"
check "requires /boot to be a separate filesystem" \
    "yes" "$(fn check_layout | grep -q 'is not a separate filesystem' && echo yes || echo no)"
check "requires the ESP to be mounted" \
    "yes" "$(fn check_layout | grep -q 'mountpoint -q /boot/efi' && echo yes || echo no)"
check "luksFormat targets the members, never a hardcoded p3" \
    "yes" "$(fn create_encrypted_root | grep -q 'luksFormat' && echo yes || echo no)"
check "no hardcoded partition suffix anywhere" "0" "$(count '}p[0-9]\|"p[0-9]')"

echo
echo "(3) destruction is ordered: unmount, stop, zero, then format"
umount_l=$(line_of 'umount "\$DATA_MOUNT"')
stop_l=$(line_of 'mdadm --stop "\$PAYLOAD_MD"')
zero_l=$(line_of 'mdadm --zero-superblock "\$m"')
luks_l=$(line_of 'cryptsetup luksFormat')
check "umount precedes mdadm --stop" \
    "yes" "$([ -n "$umount_l" ] && [ -n "$stop_l" ] && [ "$umount_l" -lt "$stop_l" ] && echo yes || echo no)"
check "mdadm --stop precedes zero-superblock" \
    "yes" "$([ -n "$stop_l" ] && [ -n "$zero_l" ] && [ "$stop_l" -lt "$zero_l" ] && echo yes || echo no)"
check "zero-superblock precedes luksFormat" \
    "yes" "$([ -n "$zero_l" ] && [ -n "$luks_l" ] && [ "$zero_l" -lt "$luks_l" ] && echo yes || echo no)"
check "the payload mount is removed from the bootstrap fstab" \
    "yes" "$(fn release_payload | grep -q "awk -v m=\"\$DATA_MOUNT\" '\$2 != m' /etc/fstab" && echo yes || echo no)"
check "members are proven free before formatting" \
    "yes" "$(fn release_payload | grep -q 'still has a holder' && echo yes || echo no)"
check "check_layout runs before release_payload in main" "yes" "$(main_order check_layout release_payload)"
check "read_passphrase runs before release_payload in main" "yes" "$(main_order read_passphrase release_payload)"

echo
echo "(4) the encrypted root is RAID over dm-crypt, named not numbered"
check "array created over /dev/mapper/cryptroot0 and cryptroot1" \
    "yes" "$(fn create_encrypted_root | grep -q '/dev/mapper/cryptroot0 /dev/mapper/cryptroot1' && echo yes || echo no)"
check "array is created by name (/dev/md/...)" "yes" "$(has '^readonly ROOT_MD=/dev/md/')"
check "no /dev/mdN device path anywhere" "0" "$(count '/dev/md[0-9]')"
check "passphrase keyslot is added from the keyfile-unlocked header" \
    "yes" "$(fn create_encrypted_root | grep -q 'luksAddKey --key-file "\$keyfile"' && echo yes || echo no)"

echo
echo "(5) /boot and the ESP are shared with the bootstrap, not re-created"
check "/boot is bound into the target" \
    "yes" "$(fn mount_target | grep -q 'mount --rbind /boot "\$MNT/boot"' && echo yes || echo no)"
check "kernel presence is asserted on the shared /boot" \
    "yes" "$(fn mount_target | grep -q 'vmlinuz-linux' && echo yes || echo no)"
check "rootfs copy stays on one filesystem (rsync -x)" \
    "yes" "$(fn copy_rootfs | grep -q 'rsync -aAXH --numeric-ids -x' && echo yes || echo no)"
check "no tmpfs staging tarball" "0" "$(count 'ROOTFS_TAR')"

echo
echo "(6) everything the installed system boots from is by UUID"
fstab_block=$(awk '/cat > "\$MNT\/etc\/fstab"/,/^EOF$/' "$INSTALLER")
check "root entry is by UUID" "yes" "$(printf '%s' "$fstab_block" | grep -q 'UUID=\${ROOT_UUID}' && echo yes || echo no)"
check "boot entry is by UUID" "yes" "$(printf '%s' "$fstab_block" | grep -q 'UUID=\${boot_uuid}' && echo yes || echo no)"
check "esp entry is by UUID"  "yes" "$(printf '%s' "$fstab_block" | grep -q 'UUID=\${esp_uuid}' && echo yes || echo no)"
check "no device path in fstab" "0" "$(printf '%s' "$fstab_block" | grep -c '/dev/' || true)"
check "an unreadable UUID is fatal" "yes" "$(has 'could not read the UUID of')"
check "fstab is written before the swap line is appended" "yes" "$(main_order write_system_config create_swap)"
check "the target gets an mdadm.conf" "yes" "$(has 'MNT/etc/mdadm.conf')"
check "target mdadm.conf pins the homehost" "yes" "$(has 'HOMEHOST <system>')"
check "target mdadm.conf must name the new root array" "yes" "$(has 'missing from mdadm --detail --scan')"
check "grub.cfg is checked for root=UUID of the new root" "yes" "$(has 'root=UUID=\${ROOT_UUID}')"
check "both cryptroot entries carry tpm2-device=auto" "2" "$(count 'luks,discard,tpm2-device=auto')"

echo
echo "(7) the installed system must not install itself again, and finalize must run"
check "installer unit is disabled in the target" \
    "yes" "$(has 'rm -f "\$MNT/etc/systemd/system/multi-user.target.wants/cmesh-byol-install.service"')"
check "marker is written inside the target" "yes" "$(has 'date -Is > "\$MNT\$MARKER"')"
check "finalize unit is enabled in the target" \
    "yes" "$(has 'multi-user.target.wants/cmesh-byol-finalize.service')"

echo
echo "(8) the shared /boot is rewritten last, and verified"
check "generate_initramfs after configure_target_system" "yes" "$(main_order configure_target_system generate_initramfs)"
check "update_bootloader after generate_initramfs" "yes" "$(main_order generate_initramfs update_bootloader)"
check "initramfs is checked for the crypttab" "yes" "$(has "lsinitcpio \"\$img\" | grep -q 'etc/crypttab'")"
check "initramfs is checked for the keyfile" "yes" "$(has "lsinitcpio \"\$img\" | grep -q 'cmesh-luks.key'")"
check "removable loader is asserted on the ESP" "yes" "$(has '/boot/efi/EFI/BOOT/BOOTX64.EFI')"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

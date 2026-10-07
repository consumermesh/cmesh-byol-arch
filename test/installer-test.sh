#!/bin/bash
# Guards the four installer defects that were verifiable in the source and would each have
# stopped the install on hardware.
#
# WHY THIS EXISTS
#
# Every one of these was found by reading the code against what the machine needs, not by a
# failing test, and each has the same property: it does not announce itself. The install
# gets most of the way, then fails somewhere else entirely, on disks that have already been
# wiped. So they are asserted here.
#
#   1. The kernel was never copied into the target /boot. The rootfs tarball excludes
#      ./boot/* by design (/boot is a separate filesystem in the target), so nothing carried
#      vmlinuz across, and mkinitcpio -P later failed on a missing /boot/vmlinuz-linux.
#
#   2. Only DISKS[1]p1 was ever mkfs.vfat'd. DISKS[0]p1 was left with no filesystem, so
#      grub-install was pointed at it and the /boot/efi fstab UUID came out empty.
#
#   3. fstab named /dev/md2 and /dev/md3 by path. md array numbers are not stable -- an
#      array without a matching mdadm.conf entry can come up as md126 -- so /boot could
#      silently fail to mount.
#
#   4. crypttab had no tpm2-device=auto, so an enrolled TPM token would never be used and
#      the machine would prompt for a passphrase at every boot despite having one.
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
has() { grep -q "$1" "$INSTALLER" && echo yes || echo no; }
count() { grep -c "$1" "$INSTALLER" || true; }

echo "(1) the kernel must reach the target /boot"
check "rootfs tarball still excludes /boot (so a copy is required)" \
    "yes" "$(has 'exclude=\./boot/\*')"
check "a copy step exists" \
    "yes" "$(has 'copy_kernel_to_target')"
check "it is called from extract_rootfs" \
    "yes" "$(awk '/^extract_rootfs\(\)/,/^}/' "$INSTALLER" | grep -q 'copy_kernel_to_target' && echo yes || echo no)"
check "it copies vmlinuz-linux" \
    "yes" "$(has 'vmlinuz-linux')"
check "it refuses to continue without a kernel" \
    "yes" "$(has 'no kernel at \$MNT/boot/vmlinuz-linux')"

echo
echo "(2) both ESPs must be formatted"
# The loop must cover every disk, not a single one.
esp_loop=$(awk '/formatted ESP/,0' "$INSTALLER" | head -5)
check "a mkfs.vfat loop over the disks exists" \
    "yes" "$(has 'for d in "\${DISKS\[@\]}"; do')"
check "the ESP is formatted inside that loop" \
    "yes" "$(awk '/^create_boot_array\(\)/,/^}/' "$INSTALLER" | grep -q 'mkfs.vfat' && echo yes || echo no)"
check "no hardcoded single-disk ESP format remains" \
    "0" "$(count 'mkfs.vfat -F32 -n ESP2')"

echo
echo "(3) fstab must use UUIDs, never /dev/mdN"
fstab_block=$(awk '/cat > "\$MNT\/etc\/fstab"/,/^EOF$/' "$INSTALLER")
check "root entry is by UUID"  "yes" "$(printf '%s' "$fstab_block" | grep -q 'UUID=\${root_uuid}' && echo yes || echo no)"
check "boot entry is by UUID"  "yes" "$(printf '%s' "$fstab_block" | grep -q 'UUID=\${boot_uuid}' && echo yes || echo no)"
check "esp entry is by UUID"   "yes" "$(printf '%s' "$fstab_block" | grep -q 'UUID=\${esp_uuid}' && echo yes || echo no)"
check "no /dev/mdN path in fstab" "0" "$(printf '%s' "$fstab_block" | grep -c '/dev/md' || true)"
check "an unreadable UUID is fatal, not written blank" \
    "yes" "$(has 'was the ESP formatted')"
check "the target gets an mdadm.conf" \
    "yes" "$(has 'MNT/etc/mdadm.conf')"
check "target mdadm.conf pins the homehost" \
    "yes" "$(has 'HOMEHOST <system>')"
check "HOMEHOST is spelled correctly (not HOMEURL)" \
    "0" "$(count 'HOMEURL')"

echo
echo "(4) crypttab must actually use an enrolled TPM"
check "both cryptroot entries carry tpm2-device=auto" \
    "2" "$(count 'luks,discard,tpm2-device=auto')"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

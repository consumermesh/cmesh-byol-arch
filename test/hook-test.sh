#!/bin/bash
# Tests the OVHcloud deploy hook (build_archlinux/provision.sh, Phase 4b).
#
# WHY THIS EXISTS
#
# The hook's failure modes are silent. OVHcloud runs it chrooted on the target and reports
# only "the script did not end properly" when it exits non-zero -- no line, no message, no
# output. The first version of this hook combined `set -euo pipefail` with several
# assertions that were individually reasonable and collectively fatal, and one of them
# fired: the deployment aborted at step 14/17, the ESP had already been formatted, and the
# only way to see why was to boot rescue and read the disk. Debugging it that way costs a
# full image upload and a reinstall per attempt.
#
# So the hook is exercised here instead. The subject under test is EXTRACTED FROM
# provision.sh rather than kept as a duplicate, because a copy would drift from what ships
# and the drift would be invisible until a deploy failed.
#
# HOW IT WORKS
#
# Absolute paths are rewritten into a sandbox directory and every command that inspects
# the machine (lsblk, findmnt, mount, grub-install, mkinitcpio) is stubbed, so the test
# asserts CONTROL FLOW:
#
#   * a bootloader on the ESP is the only thing that may fail the deployment
#   * everything else -- initramfs rebuild, grub.cfg, module injection -- is logged, and
#     a failure there leaves the deploy successful
#   * the log lands on the deployed root, because that is the only diagnostic that
#     survives the reboot and is readable from rescue mode
#
# The stubs deliberately can fail on demand (STUB_*_FAIL) so the failure paths are
# tested, not just the happy path.
#
# Usage: test/hook-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PROVISION="$REPO/build_archlinux/provision.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SB="$WORK/sandbox"
BIN="$WORK/bin"
mkdir -p "$SB"/{boot/efi,var/log,etc,proc,mnt} "$BIN"

PASS=0
FAIL=0
check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok    %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

### Extract the hook from provision.sh ###

# The hook is a quoted heredoc, so it is reproduced verbatim in the built image.
awk "/^cat > \/root\/\.ovh\/make_image_bootable\.sh <</{f=1;next} /^HOOK\$/{f=0} f" \
    "$PROVISION" > "$WORK/hook.sh"

if [ ! -s "$WORK/hook.sh" ]; then
    echo "FATAL: could not extract the deploy hook from $PROVISION" >&2
    exit 1
fi
if ! bash -n "$WORK/hook.sh"; then
    echo "FATAL: the extracted hook is not valid bash" >&2
    exit 1
fi
echo "extracted $(wc -l < "$WORK/hook.sh") lines of hook from $(basename "$PROVISION")"

# Rewrite absolute paths into the sandbox. Order matters: longer paths first, so
# /boot/ovh-make-bootable.log is not mangled by the /boot rule.
sed \
    -e "s#/boot/ovh-make-bootable.log#$SB/boot/ovh-make-bootable.log#g" \
    -e "s#/var/log#$SB/var/log#g" \
    -e "s#/proc/partitions#$SB/proc/partitions#g" \
    -e "s#/sys/firmware/efi#$SB/sys-firmware-efi#g" \
    -e "s#/etc/mkinitcpio.conf#$SB/etc/mkinitcpio.conf#g" \
    -e "s#/etc/fstab#$SB/etc/fstab#g" \
    -e "s#/mnt/cmesh-esp#$SB/mnt/cmesh-esp#g" \
    -e "s#/boot#$SB/boot#g" \
    "$WORK/hook.sh" > "$WORK/hook-sandboxed.sh"

### Stubs ###

cat > "$BIN/lsblk" <<EOF
#!/bin/bash
case "\$*" in
  *PARTTYPE*) printf '/dev/nvme0n1p1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n/dev/nvme0n1p2 4f68bce3-e8cd-4db1-96e7-fbcaf984b709\n' ;;
  *FSTYPE*)   printf '/dev/nvme0n1p1 vfat\n' ;;
  *) echo "lsblk(stub)" ;;
esac
exit 0
EOF

cat > "$BIN/findmnt" <<EOF
#!/bin/bash
if [ "\$1" = "-rn" ] && [ "\$2" = "-S" ]; then echo "$SB/root"; exit 0; fi
echo "$SB/root ext4 rw"
exit 0
EOF

# Nothing is mounted in the sandbox; mount itself is a no-op that reports success so the
# hook's bind-mount fallback path is exercised.
cat > "$BIN/mountpoint" <<'EOF'
#!/bin/bash
exit 1
EOF
printf '#!/bin/bash\necho "mount(stub): $*"\nexit 0\n' > "$BIN/mount"
printf '#!/bin/bash\necho "umount(stub): $*"\nexit 0\n' > "$BIN/umount"

cat > "$BIN/grub-install" <<EOF
#!/bin/bash
echo "grub-install(stub): \$*"
[ -n "\${STUB_GRUB_FAIL:-}" ] && { echo "grub-install: error: stub failure" >&2; exit 1; }
mkdir -p $SB/boot/efi/EFI/BOOT $SB/boot/efi/EFI/cmesh
: > $SB/boot/efi/EFI/BOOT/BOOTX64.EFI
: > $SB/boot/efi/EFI/cmesh/grubx64.efi
exit 0
EOF

cat > "$BIN/grub-mkconfig" <<EOF
#!/bin/bash
echo "grub-mkconfig(stub): \$*"
[ -n "\${STUB_MKCONFIG_FAIL:-}" ] && exit 1
mkdir -p $SB/boot/grub; : > $SB/boot/grub/grub.cfg
exit 0
EOF

cat > "$BIN/mkinitcpio" <<EOF
#!/bin/bash
echo "mkinitcpio(stub): \$*"
[ -n "\${STUB_MKINITCPIO_FAIL:-}" ] && exit 1
if [ -n "\${STUB_MKINITCPIO_EMPTY:-}" ]; then
    printf 'fake cpio with no storage modules' > $SB/boot/initramfs-linux.img
else
    printf 'fake cpio nvme raid1' > $SB/boot/initramfs-linux.img
fi
exit 0
EOF
chmod +x "$BIN"/*

### Harness ###

reset_env() {
    rm -rf "$SB/boot" "$SB/var/log" "$SB/mnt"
    mkdir -p "$SB/boot/efi" "$SB/var/log" "$SB/mnt"
    printf 'MODULES=()\nHOOKS=(base systemd)\n' > "$SB/etc/mkinitcpio.conf"
}

RC=0
OUT=""
LOG=""

run() { # run <label> [KEY=VALUE ...]
    local label="$1"; shift
    reset_env
    OUT="$WORK/$label.out"
    env "$@" PATH="$BIN:$PATH" bash "$WORK/hook-sandboxed.sh" > "$OUT" 2>&1
    RC=$?
    LOG="$SB/var/log/ovh-make-bootable.log"
}

echo
echo "the bootloader is the only fatal step"
run grubfail STUB_GRUB_FAIL=1
check "exits non-zero"                1 "$RC"
check "names the missing loader"      1 "$(grep -q 'no boot path' "$OUT" && echo 1 || echo 0)"
check "records the failed step"       1 "$(grep -q 'FAIL grub-install' "$LOG" && echo 1 || echo 0)"

echo
echo "nothing else may fail the deployment"
run mkconfigfail STUB_MKCONFIG_FAIL=1
check "grub-mkconfig failure: exit 0" 0 "$RC"
check "  loader still written"        1 "$([ -f "$SB/boot/efi/EFI/BOOT/BOOTX64.EFI" ] && echo 1 || echo 0)"
check "  failure recorded"            1 "$(grep -q 'FAIL grub-mkconfig' "$LOG" && echo 1 || echo 0)"

run mkinitfail STUB_MKINITCPIO_FAIL=1
check "mkinitcpio failure: exit 0"    0 "$RC"
check "  failure recorded"            1 "$(grep -q 'FAIL mkinitcpio -P' "$LOG" && echo 1 || echo 0)"
check "  still reports success"       1 "$(grep -q 'bootloader installed' "$OUT" && echo 1 || echo 0)"

run nowarncheck STUB_MKINITCPIO_EMPTY=1
check "initramfs without modules"     1 "$(grep -qE 'does not contain:.*nvme' "$OUT" && echo 1 || echo 0)"
check "  warns, does not fail"        0 "$RC"

echo
echo "the happy path"
run happy
check "exits zero"                    0 "$RC"
check "loader at the removable path"  1 "$([ -f "$SB/boot/efi/EFI/BOOT/BOOTX64.EFI" ] && echo 1 || echo 0)"
check "loader at the bootloader id"   1 "$([ -f "$SB/boot/efi/EFI/cmesh/grubx64.efi" ] && echo 1 || echo 0)"
check "grub.cfg generated"            1 "$([ -f "$SB/boot/grub/grub.cfg" ] && echo 1 || echo 0)"
check "storage modules forced in"     1 "$(grep -q '^MODULES=(nvme raid1)' "$SB/etc/mkinitcpio.conf" && echo 1 || echo 0)"
check "log written to deployed root"  1 "$([ -s "$LOG" ] && echo 1 || echo 0)"
check "log survives as a summary"     1 "$(grep -q 'OK   grub-install' "$LOG" && echo 1 || echo 0)"

echo
echo "the mount table and partition layout are recorded for rescue-mode diagnosis"
run happy2
check "lsblk output captured"         1 "$(grep -q 'PARTTYPENAME\|c12a7328' "$LOG" && echo 1 || echo 0)"
check "mount table captured"          1 "$(grep -q 'mount table' "$LOG" && echo 1 || echo 0)"
check "fstab captured"                1 "$(grep -q 'fstab' "$LOG" && echo 1 || echo 0)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

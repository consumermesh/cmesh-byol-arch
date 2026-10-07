#!/bin/bash
# Tests the OVHcloud deploy hook (build_archlinux/provision.sh, Phase 4b).
#
# WHY THIS EXISTS
#
# The hook's failure modes are silent. OVHcloud runs it chrooted on the target and reports
# only "the script did not end properly" when it exits non-zero -- no line, no message, no
# output. Diagnosing it from there costs a full image upload and a reinstall per attempt,
# and has done so four times.
#
# So the hook is exercised here. The subject under test is EXTRACTED FROM provision.sh
# rather than kept as a duplicate, because a copy would drift from what ships and the drift
# would be invisible until a deploy failed.
#
# HOW IT WORKS
#
# Absolute paths are rewritten into a sandbox and every command that inspects the machine
# is stubbed, so the test asserts CONTROL FLOW. The stubs can fail on demand, and each
# ESP-detection strategy can be disabled independently, so the fallback chain is tested
# rather than the happy path alone.
#
# Regression this guards: the second hook detected the ESP itself with
# `lsblk -rpnlo NAME,PARTTYPE` and matched the type GUID. That returned nothing on the
# target, the fallback returned nothing either, grub-install was skipped and the deploy
# aborted -- while the ESP sat mounted at /boot/efi the entire time. STUB_LSBLK_EMPTY
# reproduces exactly that, and the first detection tests assert the hook finds the ESP
# anyway.
#
# Usage: test/hook-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PROVISION="$REPO/build_archlinux/provision.sh"
# HOOK_TEST_WORKDIR keeps the sandbox around for inspection after a failure.
WORK="$(mktemp -d ${HOOK_TEST_WORKDIR:+-p "$HOOK_TEST_WORKDIR"} 2>/dev/null || mktemp -d)"
if [ -z "${HOOK_TEST_KEEP:-}" ]; then
    trap 'rm -rf "$WORK"' EXIT
else
    trap 'echo "workdir kept: $WORK"' EXIT
fi

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
    -e "s#/proc/mounts#$SB/proc/mounts#g" \
    -e "s#/proc/partitions#$SB/proc/partitions#g" \
    -e "s#/proc/cmdline#$SB/proc/cmdline#g" \
    -e "s#/etc/default/grub#$SB/etc/default/grub#g" \
    -e "s#/sys/firmware/efi#$SB/sys-firmware-efi#g" \
    -e "s#/etc/mkinitcpio.conf#$SB/etc/mkinitcpio.conf#g" \
    -e "s#/etc/fstab#$SB/etc/fstab#g" \
    -e "s#/mnt/cmesh-esp#$SB/mnt/cmesh-esp#g" \
    -e "s#/boot/efi#$SB/boot/efi#g" \
    -e "s#/boot/grub#$SB/boot/grub#g" \
    -e "s#/boot/initramfs-linux.img#$SB/boot/initramfs-linux.img#g" \
    "$WORK/hook.sh" > "$WORK/hook-sandboxed.sh"

### Stubs ###

# lsblk: STUB_LSBLK_EMPTY reproduces the real failure -- the PARTTYPE column returns
# nothing even though the ESP exists and is mounted.
cat > "$BIN/lsblk" <<EOF
#!/bin/bash
if [ -n "\${STUB_LSBLK_EMPTY:-}" ]; then exit 0; fi
case "\$*" in
  *PARTTYPE*) printf '/dev/nvme0n1p1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n/dev/nvme0n1p2 4f68bce3-e8cd-4db1-96e7-fbcaf984b709\n' ;;
  *FSTYPE*)   printf '/dev/nvme0n1p1 vfat\n' ;;
  *) echo "lsblk(stub)" ;;
esac
exit 0
EOF

# blkid: "-o value -s TYPE <dev>" is the ESP validation; "-o device -t ..." is a discovery
# strategy. STUB_BLKID_NONE disables both, forcing the hook to declare it found nothing.
cat > "$BIN/blkid" <<EOF
#!/bin/bash
[ -n "\${STUB_BLKID_NONE:-}" ] && exit 2
mode=""; field=""; query=""; arg=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; mode="\$1" ;;
    -s) shift; field="\$1" ;;
    -t) shift; query="\$1" ;;
    *)  arg="\$1" ;;
  esac
  shift
done
if [ "\$mode" = "value" ] && [ "\$field" = "TYPE" ]; then
  echo "\${STUB_BLKID_TYPE:-vfat}"; exit 0
fi
if [ "\$mode" = "device" ]; then
  [ -n "\${STUB_BLKID_DEV:-}" ] && echo "\$STUB_BLKID_DEV"
  exit 0
fi
exit 2
EOF

# findmnt answers both "what is mounted at X" and "is device D mounted".
cat > "$BIN/findmnt" <<EOF
#!/bin/bash
[ -n "\${STUB_FINDMNT_EMPTY:-}" ] && exit 1
if [ "\$1" = "-rn" ] && [ "\$2" = "-o" ] && [ "\$3" = "SOURCE" ]; then
  echo "\${STUB_FINDMNT_SOURCE:-/dev/nvme1n1p1}"; exit 0
fi
if [ "\$1" = "-rn" ] && [ "\$2" = "-S" ]; then echo "$SB/boot/efi"; exit 0; fi
echo "$SB/root ext4 rw"
exit 0
EOF

# mountpoint: STUB_NO_MOUNTPOINT makes /boot/efi report as not mounted, forcing the hook
# past strategy 1 and onto the fallbacks.
cat > "$BIN/mountpoint" <<'EOF'
#!/bin/bash
[ -n "${STUB_NO_MOUNTPOINT:-}" ] && exit 1
exit 0
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
printf 'fake cpio nvme raid1' > $SB/boot/initramfs-linux.img
exit 0
EOF
chmod +x "$BIN"/*

### Harness ###

# The hook cannot be given real block devices here -- mknod is refused even inside a user
# namespace on this host -- so this flag relaxes is_esp()'s [ -b ] check and nothing else.
# It is unset in production.
export CMESH_BYOL_TEST_NONBLOCK=1

reset_env() {
    rm -rf "$SB/boot" "$SB/var/log" "$SB/mnt"
    mkdir -p "$SB/boot/efi" "$SB/var/log" "$SB/mnt"
    printf 'MODULES=()\nHOOKS=(base systemd)\n' > "$SB/etc/mkinitcpio.conf"
    # Default world: the ESP is mounted at /boot/efi, and lsblk is as unhelpful as it was
    # on the real target.
    printf '/dev/nvme1n1p1 %s/boot/efi vfat rw,relatime 0 0\n' "$SB" > "$SB/proc/mounts"
    printf 'LABEL=EFI_SYSPART %s/boot/efi vfat defaults 0 1\n' "$SB" > "$SB/etc/fstab"
    # The deployer's kernel runs on a serial console; the OVHcloud reference hooks copy
    # its console= parameters into GRUB. run() overrides the whole line via STUB_CMDLINE.
    printf 'BOOT_IMAGE=/vmlinuz ro console=tty0 console=ttyS1,115200n8 quiet\n' > "$SB/proc/cmdline"
    # /etc/default/grub exactly as provision.sh leaves it in the image: the cloud image's
    # serial terminal survives, the kernel cmdline does not carry a console.
    mkdir -p "$SB/etc/default"
    cat > "$SB/etc/default/grub" <<'GRUBDEF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="nomodeset iommu=pt"
GRUB_GFXPAYLOAD_LINUX="text"
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200"
GRUBDEF
}

RC=0
OUT=""
LOG=""

run() { # run <label> [KEY=VALUE ...]
    local label="$1" kv; shift
    reset_env
    # STUB_CMDLINE is a file the hook reads, not an environment variable it sees.
    for kv in "$@"; do
        case "$kv" in STUB_CMDLINE=*) printf '%s\n' "${kv#STUB_CMDLINE=}" > "$SB/proc/cmdline" ;; esac
    done
    OUT="$WORK/$label.out"
    env "$@" PATH="$BIN:$PATH" bash "$WORK/hook-sandboxed.sh" > "$OUT" 2>&1
    RC=$?
    LOG="$SB/var/log/ovh-make-bootable.log"
}

echo
echo "finding the ESP -- the regression that cost a deployment"
echo "(in every case below lsblk's PARTTYPE column is empty, exactly as on the target)"
run esp_mounted STUB_LSBLK_EMPTY=1
check "strategy 1 (/boot/efi mounted): exit 0"  0 "$RC"
check "  loader written"                        1 "$([ -f "$SB/boot/efi/EFI/BOOT/BOOTX64.EFI" ] && echo 1 || echo 0)"
check "  log names the method"                  1 "$(grep -q 'is mounted on /dev/nvme1n1p1' "$LOG" && echo 1 || echo 0)"
check "  no bogus 'not found' warning"          0 "$(grep -c 'no EFI System Partition found' "$LOG")"

run esp_blkid STUB_LSBLK_EMPTY=1 STUB_NO_MOUNTPOINT=1 STUB_FINDMNT_SOURCE= STUB_BLKID_DEV=/dev/nvme1n1p1
check "strategy 2/3 (blkid): exit 0"            0 "$RC"
check "  loader written"                        1 "$([ -f "$SB/boot/efi/EFI/BOOT/BOOTX64.EFI" ] && echo 1 || echo 0)"
check "  log names a method"                    1 "$(grep -qE 'ESP candidates \((vfat partitions in|blkid|fstab)' "$LOG" && echo 1 || echo 0)"
check "  log names the device"                  1 "$(grep -q 'candidates.*: /dev/nvme1n1p1' "$LOG" && echo 1 || echo 0)"

run esp_none STUB_LSBLK_EMPTY=1 STUB_NO_MOUNTPOINT=1 STUB_FINDMNT_EMPTY=1 STUB_BLKID_NONE=1
check "no ESP by any method: exit 1"            1 "$RC"
check "  says all five were tried"              1 "$(grep -q 'no EFI System Partition found by ANY of five methods' "$LOG" && echo 1 || echo 0)"
check "  names the detection method as none"    1 "$(grep -q 'detection method: none' "$OUT" && echo 1 || echo 0)"

echo
echo "the bootloader is the only fatal step"
run grubfail STUB_GRUB_FAIL=1
check "exits non-zero"                          1 "$RC"
check "names the missing loader"                1 "$(grep -q 'No boot path' "$OUT" && echo 1 || echo 0)"
check "records the failed step"                 1 "$(grep -q 'FAIL grub-install' "$LOG" && echo 1 || echo 0)"

echo
echo "nothing else may fail the deployment"
run mkconfigfail STUB_MKCONFIG_FAIL=1
check "grub-mkconfig failure: exit 0"           0 "$RC"
check "  loader still written"                  1 "$([ -f "$SB/boot/efi/EFI/BOOT/BOOTX64.EFI" ] && echo 1 || echo 0)"
check "  failure recorded"                      1 "$(grep -q 'FAIL grub-mkconfig' "$LOG" && echo 1 || echo 0)"

run mkinitfail STUB_MKINITCPIO_FAIL=1
check "mkinitcpio failure: exit 0"              0 "$RC"
check "  failure recorded"                      1 "$(grep -q 'FAIL mkinitcpio -P' "$LOG" && echo 1 || echo 0)"
check "  still reports success"                 1 "$(grep -q 'bootloader installed' "$OUT" && echo 1 || echo 0)"

echo
echo "the happy path"
run happy
check "exits zero"                              0 "$RC"
check "loader at the removable path"            1 "$([ -f "$SB/boot/efi/EFI/BOOT/BOOTX64.EFI" ] && echo 1 || echo 0)"
check "loader at the bootloader id"             1 "$([ -f "$SB/boot/efi/EFI/cmesh/grubx64.efi" ] && echo 1 || echo 0)"
check "grub.cfg generated"                      1 "$([ -f "$SB/boot/grub/grub.cfg" ] && echo 1 || echo 0)"
check "storage modules forced in"               1 "$(grep -q '^MODULES=(nvme raid1)' "$SB/etc/mkinitcpio.conf" && echo 1 || echo 0)"
check "log written to deployed root"            1 "$([ -s "$LOG" ] && echo 1 || echo 0)"
check "log carries a per-step summary"          1 "$(grep -q 'OK   grub-install' "$LOG" && echo 1 || echo 0)"

echo
echo "rescue-mode diagnostic material is captured"
run diag
check "raw blkid output logged"                 1 "$(grep -q 'blkid (raw)' "$LOG" && echo 1 || echo 0)"
check "vfat mounts logged"                      1 "$(grep -q 'mounts (vfat)' "$LOG" && echo 1 || echo 0)"
check "fstab logged"                            1 "$(grep -q 'fstab' "$LOG" && echo 1 || echo 0)"
check "mount table logged"                      1 "$(grep -q 'mount table' "$LOG" && echo 1 || echo 0)"
check "deployer cmdline logged"                 1 "$(grep -q 'deployer cmdline' "$LOG" && echo 1 || echo 0)"

echo
echo "the kernel is put on the console the operator watches (OVHcloud reference behaviour)"
run console
GRUBDEF="$SB/etc/default/grub"
cmdline_now() { sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"/\1/p' "$GRUBDEF"; }
check "exits zero"                              0 "$RC"
check "console=tty0 carried into GRUB_CMDLINE_LINUX" \
    1 "$(cmdline_now | grep -q 'console=tty0' && echo 1 || echo 0)"
check "console=ttyS1,115200n8 carried into GRUB_CMDLINE_LINUX" \
    1 "$(cmdline_now | grep -q 'console=ttyS1,115200n8' && echo 1 || echo 0)"
check "existing parameters kept" \
    1 "$(cmdline_now | grep -q '^nomodeset iommu=pt ' && echo 1 || echo 0)"
check "serial console is LAST, so /dev/console is the serial line" \
    1 "$(cmdline_now | grep -qE 'console=ttyS1,115200n8$' && echo 1 || echo 0)"
check "GRUB terminal switched to console serial" \
    1 "$(grep -q '^GRUB_TERMINAL="console serial"$' "$GRUBDEF" && echo 1 || echo 0)"
check "GRUB serial command follows the deployer (unit 1, 115200, no parity, 8 bits)" \
    1 "$(grep -q '^GRUB_SERIAL_COMMAND="serial --unit=1 --speed=115200 --parity=no --word=8"$' "$GRUBDEF" && echo 1 || echo 0)"
check "console configured BEFORE grub-mkconfig" \
    1 "$(awk '/OK   configure console/{c=NR} /grub-mkconfig\(stub\)/{m=NR} END{exit !(c && m && c < m)}' "$OUT" && echo 1 || echo 0)"
check "step recorded in the log"                1 "$(grep -q 'OK   configure console' "$LOG" && echo 1 || echo 0)"

# A second run on the same /etc/default/grub must not grow the cmdline.
env PATH="$BIN:$PATH" bash "$WORK/hook-sandboxed.sh" > "$WORK/console2.out" 2>&1
check "idempotent: console= appears once each after a second run" \
    "1 1" "$(printf '%s %s' "$(cmdline_now | grep -o 'console=tty0' | wc -l)" "$(cmdline_now | grep -o 'console=ttyS1,115200n8' | wc -l)")"

run console_none STUB_CMDLINE="BOOT_IMAGE=/vmlinuz ro quiet"
check "no console= in the deployer: exit 0"     0 "$RC"
check "  GRUB_CMDLINE_LINUX untouched" \
    1 "$(grep -q '^GRUB_CMDLINE_LINUX="nomodeset iommu=pt"$' "$GRUBDEF" && echo 1 || echo 0)"
check "  GRUB terminal untouched" \
    1 "$(grep -q '^GRUB_TERMINAL="serial console"$' "$GRUBDEF" && echo 1 || echo 0)"
check "  says so in the log" \
    1 "$(grep -q 'no console= parameter' "$LOG" && echo 1 || echo 0)"

run console_vga_only STUB_CMDLINE="BOOT_IMAGE=/vmlinuz ro console=tty0"
check "VGA-only console: kernel cmdline gets console=tty0" \
    1 "$(cmdline_now | grep -q 'console=tty0' && echo 1 || echo 0)"
check "  GRUB serial command left as built" \
    1 "$(grep -q '^GRUB_SERIAL_COMMAND="serial --speed=115200"$' "$GRUBDEF" && echo 1 || echo 0)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

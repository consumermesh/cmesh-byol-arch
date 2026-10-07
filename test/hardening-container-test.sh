#!/bin/bash
# Runs cmesh-byol-harden --build for real inside an Arch container, then validates the
# result with the tools the host may not have: sshd -t, nft -c, visudo, augenrules,
# systemd-analyze verify, and a cmesh-integrity init/check round trip with pacman.
#
# This is the closest thing to a build-VM run that takes seconds-to-minutes instead of
# an image build. It pulls docker.io/library/archlinux and installs the hardening
# packages, so it is opt-in from run-all: CMESH_CONTAINER_TESTS=1 test/run-all.sh
#
# Usage: test/hardening-container-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
command -v podman >/dev/null 2>&1 || { echo "SKIP: podman not installed"; exit 0; }

STAGE="$(mktemp -d /tmp/cmesh-harden-ct.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$REPO/build_archlinux/files/cmesh-byol-harden" "$REPO/build_archlinux/files/hardening" "$STAGE/"

cat > "$STAGE/inside.sh" <<'INSIDE'
set -uo pipefail
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

pacman -Sy --noconfirm >/dev/null 2>&1 || { echo "FATAL: pacman -Sy failed (network?)"; exit 1; }
# The script needs grub's config file to exist to edit the cmdline, and sshd -t needs
# host keys. Both exist in the real image; fake them here.
pacman -S --noconfirm --needed openssh grub >/dev/null 2>&1
ssh-keygen -A >/dev/null 2>&1
printf 'GRUB_CMDLINE_LINUX_DEFAULT=""\nGRUB_CMDLINE_LINUX="nomodeset iommu=pt"\n' > /etc/default/grub
: > /etc/mdadm.conf

# nft -c validates against the kernel, and a rootless container cannot load
# nf_conntrack; if the host has not loaded it, every `ct` rule fails with "Could not
# process rule". Syntax is what this test is after, so a wrapper retries the check with
# the ct lines removed when -- and only when -- those are the sole errors. The real
# script and the real image are untouched; the build VM has a kernel of its own.
cat > /usr/local/bin/nft <<'WRAP'
#!/bin/bash
# Retries `nft -c -f FILE` with the lines the container kernel cannot process removed
# (missing nf_conntrack / nft_limit modules), as long as those are the ONLY errors.
# Any syntax error still fails. Prints which lines were skipped.
real=/usr/bin/nft
if [ "$1" = "-c" ] && [ "$2" = "-f" ] && [ -n "${3:-}" ]; then
    tmp=$(mktemp); cp "$3" "$tmp"; skipped=0
    for _ in 1 2 3 4 5 6 7 8; do
        err=$("$real" -c -f "$tmp" 2>&1) && { [ "$skipped" -gt 0 ] && echo "nft wrapper: ${skipped} rule(s) skipped (kernel modules unavailable in container)" >&2; rm -f "$tmp"; exit 0; }
        if printf '%s' "$err" | grep -E '^/.*Error:' | grep -vq 'Could not process rule: No such file or directory'; then
            printf '%s\n' "$err" >&2; rm -f "$tmp"; exit 1
        fi
        lines=$(printf '%s' "$err" | sed -nE 's|^/[^:]*:([0-9]+):.*Could not process rule.*|\1|p' | sort -rnu)
        [ -n "$lines" ] || { printf '%s\n' "$err" >&2; rm -f "$tmp"; exit 1; }
        for n in $lines; do sed -i "${n}s/.*/# skipped by test wrapper/" "$tmp"; skipped=$((skipped+1)); done
    done
    printf '%s\n' "$err" >&2; rm -f "$tmp"; exit 1
fi
exec "$real" "$@"
WRAP
chmod +x /usr/local/bin/nft

echo "(1) cmesh-byol-harden --build"
/w/cmesh-byol-harden --build --files /w/hardening > /tmp/harden.out 2>&1
rc=$?
check "exit status 0 (no warnings)" 0 "$rc"
[ "$rc" -ne 0 ] && { echo "--- output ---"; tail -40 /tmp/harden.out; }
check "no WARN lines" 0 "$(grep -c '^  WARN' /tmp/harden.out)"
check "log written" yes "$([ -s /var/log/cmesh-byol-harden.log ] && echo yes || echo no)"

echo
echo "(2) what sshd, nft, sudo and audit think of the result"
sshd -t 2>/tmp/sshd-t; check "sshd -t accepts the config" 0 $?
[ -s /tmp/sshd-t ] && cat /tmp/sshd-t
eff=$(sshd -T 2>/tmp/sshd-T)
[ -n "$eff" ] || { echo "sshd -T produced nothing:"; cat /tmp/sshd-T; }
for kv in "passwordauthentication no" "kbdinteractiveauthentication no" "authenticationmethods publickey" \
          "maxauthtries 3" "clientaliveinterval 300" "clientalivecountmax 2" "x11forwarding no" \
          "allowtcpforwarding no" "banner /etc/issue.net" "loglevel VERBOSE" "permitrootlogin prohibit-password"; do
    check "sshd -T: $kv" yes "$(printf '%s\n' "$eff" | grep -qix "$kv" && echo yes || echo no)"
done
check "sshd -T: no AllowUsers at build time" no "$(printf '%s\n' "$eff" | grep -qi '^allowusers' && echo yes || echo no)"
check "sshd -T: every Kex is one we asked for (none rejected)" yes "$(printf '%s\n' "$eff" | grep -qi '^kexalgorithms mlkem768x25519-sha256,' && echo yes || echo no)"
nft -c -f /etc/nftables.conf 2>/tmp/nft-c; check "nft -c accepts the ruleset" 0 $?
[ -s /tmp/nft-c ] && cat /tmp/nft-c
visudo -cf /etc/sudoers.d/10-cmesh-wheel >/dev/null 2>&1; check "visudo accepts the wheel drop-in" 0 $?
visudo -c >/dev/null 2>&1; check "visudo accepts the whole sudoers tree" 0 $?
augenrules --check >/dev/null 2>&1 || augenrules >/dev/null 2>&1
check "augenrules merged the rules" yes "$([ -s /etc/audit/audit.rules ] && echo yes || echo no)"
check "merged rules end with -e 2" "-e 2" "$(grep -v '^#' /etc/audit/audit.rules | grep -v '^$' | tail -1)"
# auditctl needs the audit netlink socket of the init user namespace, which a rootless
# container never has, so the merged file is checked for completeness instead.
want=$(cat /w/hardening/audit-*.rules | grep -cE '^-(a|w) '); got=$(grep -cE '^-(a|w) ' /etc/audit/audit.rules)
check "merged file carries every -a/-w rule from the three sources (${want})" "$want" "$got"
sysctl -p /etc/sysctl.d/90-cmesh-hardening.conf >/dev/null 2>/tmp/sysctl; rc=$?
check "sysctl file parses (keys may be read-only in a container)" 0 "$(grep -cE 'syntax|invalid' /tmp/sysctl)"
systemd-analyze verify /etc/systemd/system/cmesh-*.service /etc/systemd/system/cmesh-*.timer 2>/tmp/verify
check "systemd-analyze verify: cmesh units" "" "$(grep -vE 'Unit .* is not loaded|cannot be verified|Failed to (create|load)' /tmp/verify | head -3 | tr '\n' ' ')"
check "mdmonitor override: unit still loads" yes "$(systemd-analyze verify /usr/lib/systemd/system/mdmonitor.service 2>&1 | grep -q 'ExecStart' && echo no || echo yes)"
check "grub cmdline carries lsm= and audit=1" yes "$(grep -q 'GRUB_CMDLINE_LINUX="nomodeset iommu=pt lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1 audit_backlog_limit=8192"' /etc/default/grub && echo yes || echo no)"
check "mdadm.conf has PROGRAM cmesh-alert exactly once" 1 "$(grep -c '^PROGRAM /usr/local/sbin/cmesh-alert$' /etc/mdadm.conf)"
check "auditd.conf: max_log_file = 50" yes "$(grep -q '^max_log_file = 50$' /etc/audit/auditd.conf && echo yes || echo no)"
check "20-cmesh-users.conf NOT written at build (no keys)" no "$([ -f /etc/ssh/sshd_config.d/20-cmesh-users.conf ] && echo yes || echo no)"
for u in nftables auditd sshguard smartd apparmor systemd-timesyncd cmesh-arch-audit.timer cmesh-integrity.timer cmesh-integrity-init; do
    check "enabled: $u" enabled "$(systemctl is-enabled "$u" 2>/dev/null)"
done
check "copy kept for re-runs" yes "$([ -f /usr/share/cmesh-byol/hardening/nftables.conf ] && [ -x /usr/local/sbin/cmesh-byol-harden ] && echo yes || echo no)"

echo
echo "(3) idempotent: a second run changes nothing and warns about nothing"
/w/cmesh-byol-harden --build --files /w/hardening > /tmp/harden2.out 2>&1; check "second run exit 0" 0 $?
check "second run installed nothing new" 0 "$(grep -c '^  ok    installed ' /tmp/harden2.out)"
check "grub cmdline not duplicated" 1 "$(grep -o 'audit=1' /etc/default/grub | wc -l)"
check "PROGRAM line not duplicated" 1 "$(grep -c '^PROGRAM' /etc/mdadm.conf)"

echo
echo "(4) the re-run path with no --files uses the installed copy"
/usr/local/sbin/cmesh-byol-harden --build > /tmp/harden3.out 2>&1; check "run from /usr/local/sbin without --files" 0 $?
check "it found /usr/share/cmesh-byol/hardening" yes "$(grep -q 'files from /usr/share/cmesh-byol/hardening' /tmp/harden3.out && echo yes || echo no)"

echo
echo "(5) cmesh-integrity with a real pacman database"
mkdir -p /var/lib/cmesh-byol
/usr/local/sbin/cmesh-integrity init >/tmp/int.out 2>&1; check "init" 0 $?
/usr/local/sbin/cmesh-integrity check >/dev/null 2>&1; check "check clean" 0 $?
echo "# tamper" >> /usr/bin/nft.tamper 2>/dev/null; printf '\n' >> /etc/nftables.conf
/usr/local/sbin/cmesh-integrity check >/tmp/int2.out 2>&1; check "check detects an edited /etc/nftables.conf" 1 $?
check "alert landed in /var/log/cmesh-alerts.log" yes "$(grep -q 'integrity check FAILED' /var/log/cmesh-alerts.log && echo yes || echo no)"
cp /usr/bin/nft /tmp/nft.bak; printf '\0' >> /usr/bin/nft
/usr/local/sbin/cmesh-integrity accept >/dev/null 2>&1   # /etc change accepted...
/usr/local/sbin/cmesh-integrity check >/tmp/int3.out 2>&1
check "...but accept re-baselines pacman warnings too (documented limitation: a re-baseline after tampering hides it)" 0 $?
cp /tmp/nft.bak /usr/bin/nft
/usr/local/sbin/cmesh-integrity accept >/dev/null 2>&1
printf '\0' >> /usr/bin/nft
/usr/local/sbin/cmesh-integrity check >/tmp/int4.out 2>&1; check "a modified package binary is detected via pacman -Qkk" 1 $?
check "pacman warning names the file" yes "$(grep -q 'package: .*/usr/bin/nft' /tmp/int4.out && echo yes || echo no)"

echo
echo "(6) Secure Boot pipeline: mkinitcpio builds a UKI, sbctl's post hook signs it, cmesh-esp-sync sees the signature"
pacman -S --noconfirm --needed linux >/dev/null 2>&1 || echo "  (linux install failed)"
kver=$(ls /usr/lib/modules | head -1)
printf 'root=UUID=0000-test rw console=ttyS1,115200n8 lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1\n' > /etc/kernel/cmdline
mkdir -p /boot/efi/EFI/Linux
sed -i -E 's|^#?default_uki=.*|default_uki="/boot/efi/EFI/Linux/cmesh-linux.efi"|' /etc/mkinitcpio.d/linux.preset
grep -q '^default_uki="/boot/efi/EFI/Linux/cmesh-linux.efi"$' /etc/mkinitcpio.d/linux.preset || echo 'default_uki="/boot/efi/EFI/Linux/cmesh-linux.efi"' >> /etc/mkinitcpio.d/linux.preset
sbctl create-keys >/dev/null 2>&1; check "sbctl create-keys" 0 $?
mkinitcpio -P >/tmp/mk.out 2>&1; rc=$?
check "mkinitcpio -P with default_uki" 0 "$rc"; [ "$rc" -ne 0 ] && tail -20 /tmp/mk.out
check "UKI produced" yes "$([ -s /boot/efi/EFI/Linux/cmesh-linux.efi ] && echo yes || echo no)"
check "UKI larger than the kernel" yes "$([ "$(stat -c %s /boot/efi/EFI/Linux/cmesh-linux.efi 2>/dev/null || echo 0)" -gt "$(stat -c %s /boot/vmlinuz-linux)" ] && echo yes || echo no)"
check "sbctl's post hook signed it during mkinitcpio" yes "$(grep -q 'Signing /boot/efi/EFI/Linux/cmesh-linux.efi' /tmp/mk.out && echo yes || echo no)"
/usr/local/sbin/cmesh-esp-sync check /boot/efi/EFI/Linux/cmesh-linux.efi; check "cmesh-esp-sync check: signed" 0 $?
/usr/local/sbin/cmesh-esp-sync check /boot/vmlinuz-linux; check "cmesh-esp-sync check: the raw kernel is an unsigned PE (1)" 1 $?
check "our post hook ran after sbctl's (order in /etc + /usr/lib)" yes "$(grep -q 'cmesh-esp-sync: not prepared for Secure Boot' /tmp/mk.out && echo yes || echo no)"
check "cmdline embedded in the UKI" yes "$(grep -aq 'console=ttyS1,115200n8 lsm=' /boot/efi/EFI/Linux/cmesh-linux.efi && echo yes || echo no)"
/usr/local/sbin/cmesh-byol-secureboot status >/tmp/sb.out 2>&1; check "secureboot status runs (no UEFI here)" 0 $?
check "status reports NOT UEFI" yes "$(grep -q 'NOT UEFI' /tmp/sb.out && echo yes || echo no)"
/usr/local/sbin/cmesh-byol-secureboot prepare >/tmp/sbp.out 2>&1; check "prepare refuses without UEFI (exit 1)" 1 $?
check "prepare said why" yes "$(grep -q 'not booted via UEFI' /tmp/sbp.out && echo yes || echo no)"

echo
echo "(7) --status runs without root-only state"
/usr/local/sbin/cmesh-byol-harden --status >/tmp/status.out 2>&1; check "--status exit 0" 0 $?
check "--status lists units" yes "$(grep -q 'nftables.service' /tmp/status.out && echo yes || echo no)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
INSIDE

# NET_ADMIN: nft needs netlink even for -c (check-only), and rootless podman grants it
# inside the container's own network namespace.
podman run --rm --cap-add=NET_ADMIN -v "$STAGE:/w:z" docker.io/library/archlinux:base-devel bash /w/inside.sh

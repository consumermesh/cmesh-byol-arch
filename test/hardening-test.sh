#!/bin/bash
# Tests build_archlinux/files/cmesh-byol-harden and the files under hardening/.
#
# WHY THIS EXISTS
#
# Hardening is the one change that can lock the operator out of a machine that is
# otherwise working: a bad sshd directive, a firewall loaded before the established-
# connections rule, root login turned off before any other account has a key. None of
# that is visible until the next login fails. The script's safety ordering is asserted
# here, every shipped file is checked for the directives it exists to set, and the two
# tools that can run anywhere (cmesh-integrity, cmesh-alert) are exercised for real on a
# scratch tree. Syntax checks that need sshd/nft/auditctl run in
# test/hardening-container-test.sh.
#
# Usage: test/hardening-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HARDEN="$REPO/build_archlinux/files/cmesh-byol-harden"
H="$REPO/build_archlinux/files/hardening"
PROVISION="$REPO/build_archlinux/provision.sh"
INSTALLER="$REPO/build_archlinux/files/cmesh-byol-install"
POLLER="$REPO/scripts/cmesh-alert-poller"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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
has()  { grep -qE -- "$2" "$1" && echo yes || echo no; }       # has <file> <regex>
code() { grep -v '^[[:space:]]*#' "$1"; }
line_of() { code "$1" | grep -n -- "$2" | head -1 | cut -d: -f1; }
before() { # before <file> <pattern-a> <pattern-b>
    local a b; a=$(line_of "$1" "$2"); b=$(line_of "$1" "$3")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo yes || echo no
}

echo "(1) scripts parse"
for f in "$HARDEN" "$H/cmesh-alert" "$H/cmesh-integrity" "$H/cmesh-arch-audit" \
         "$H/cmesh-logwatch" "$H/cmesh-unit-failed" "$POLLER"; do
    bash -n "$f" 2>/dev/null; check "bash -n $(basename "$f")" 0 $?
    check "$(basename "$f") is executable" yes "$([ -x "$f" ] && echo yes || echo no)"
done

echo
echo "(2) every file the script installs is shipped, and every shipped file is installed"
code "$HARDEN" | grep -E '^put ' | awk '{print $2}' | sort > "$WORK/put"
ls "$H" | sort > "$WORK/shipped"
check "put sources all exist in hardening/" "" "$(comm -23 "$WORK/put" "$WORK/shipped" | tr '\n' ' ')"
check "nothing in hardening/ is left uninstalled" "" "$(comm -13 "$WORK/put" "$WORK/shipped" | tr '\n' ' ')"
check "put refuses a missing source" yes "$(has "$HARDEN" 'missing hardening file')"

echo
echo "(3) the script cannot lock the operator out"
check "--status exits before the root check" yes "$(before "$HARDEN" 'STATUS" -eq 1 \]; then status; exit 0' 'must run as root')"
check "sshd -t runs before sshd is reloaded" yes "$(before "$HARDEN" 'sshd -t 2>' 'systemctl reload sshd')"
check "a rejected sshd config removes the hardening drop-in" yes "$(has "$HARDEN" 'rm -f /etc/ssh/sshd_config.d/10-cmesh-hardening.conf "\$users_conf"')"
check "a rejected sshd config is fatal (no reload)" yes "$(has "$HARDEN" 'die "sshd rejected the hardened config')"
check "nft -c runs before nft -f" yes "$(before "$HARDEN" 'nft -c -f /etc/nftables.conf' 'nft -f /etc/nftables.conf')"
check "an invalid ruleset is never loaded" yes "$(has "$HARDEN" 'die "nftables.conf failed nft -c')"
check "root login is disabled only with keys AND wheel" yes "$(has "$HARDEN" '-s "\$home/.ssh/authorized_keys" \] && id -nG "\$ADMIN_USER" \| grep -qw wheel')"
check "otherwise the users drop-in is removed, not left stale" yes "$(has "$HARDEN" 'rm -f "\$users_conf"')"
check "and a live run says root is still open" yes "$(has "$HARDEN" 'root SSH login LEFT ENABLED')"
check "PermitRootLogin no lives only in the guarded drop-in" 1 "$(code "$HARDEN" | grep -c 'PermitRootLogin no')"
check "the static sshd file never sets PermitRootLogin" no "$(has "$H/sshd-10-cmesh-hardening.conf" '^PermitRootLogin')"
check "the static sshd file never sets AllowUsers" no "$(has "$H/sshd-10-cmesh-hardening.conf" '^AllowUsers')"
check "sudoers drop-in is visudo-checked and removed on failure" yes "$(has "$HARDEN" 'visudo -cf /etc/sudoers.d/10-cmesh-wheel')"
check "--build never creates the admin user" yes "$(has "$HARDEN" 'not created at build time')"
# Every command that changes the RUNNING system must be on a line guarded by `live &&`
# or inside an `if live` / `elif live` block (matched by indentation to its `fi`).
unguarded=$(awk '
    function apply(l) { return l ~ /systemctl (reload|restart)|nft -f \/etc|sysctl -q --system|augenrules --load|grub-mkconfig -o|useradd -m|cmesh-integrity init/ }
    /^[[:space:]]*#/ { next }
    { match($0, /^[[:space:]]*/); ind = RLENGTH }
    $0 ~ /^[[:space:]]*(if|elif) live/ { depth++; stack[depth] = ind; next }
    depth > 0 && $0 ~ /^[[:space:]]*fi$/ && ind == stack[depth] { depth--; next }
    apply($0) && depth == 0 && $0 !~ /live &&/ { print NR": "$0 }
' "$HARDEN")
check "--build never applies anything live (every apply is behind live)" "" "$unguarded"
check "immutable audit rules (-e 2) are detected, not fought" yes "$(has "$HARDEN" "grep -qE '\^enabled 2'")"
check "integrity baseline only after finalize" yes "$(has "$HARDEN" '-f /var/lib/cmesh-byol/finalized \] && \[ ! -f /var/lib/cmesh-byol/integrity/manifest.sha256')"
check "live run ends by telling the operator to test a second session" yes "$(has "$HARDEN" 'SECOND ssh session')"
check "exit status reflects warnings" yes "$(has "$HARDEN" '^\[ "\$WARNINGS" -eq 0 \]')"

echo
echo "(4) sshd drop-in sets what it exists to set"
S="$H/sshd-10-cmesh-hardening.conf"
for kv in "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitEmptyPasswords no" \
          "AuthenticationMethods publickey" "MaxAuthTries 3" "LoginGraceTime 30" \
          "ClientAliveInterval 300" "ClientAliveCountMax 2" "X11Forwarding no" \
          "AllowTcpForwarding no" "AllowAgentForwarding no" "PermitTunnel no" \
          "Banner /etc/issue.net" "LogLevel VERBOSE" "PermitUserEnvironment no"; do
    check "$kv" yes "$(has "$S" "^${kv}$")"
done
check "ecdsa host keys stay accepted (the operator key is ecdsa)" yes "$(has "$S" '^HostKeyAlgorithms .*ecdsa-sha2-nistp521')"
check "PubkeyAcceptedAlgorithms is NOT narrowed" no "$(has "$S" '^PubkeyAcceptedAlgorithms')"
check "no CBC ciphers" no "$(has "$S" '^Ciphers .*-cbc')"
check "no sha1 MACs" no "$(has "$S" '^MACs .*sha1')"
check "issue.net is a pre-auth notice (no logo, mentions monitoring)" yes "$(has "$H/issue.net" '[Mm]onitor')"

echo
echo "(5) firewall"
N="$H/nftables.conf"
check "input policy drop" yes "$(has "$N" 'hook input priority filter; policy drop;')"
check "forward policy drop" yes "$(has "$N" 'hook forward priority filter; policy drop;')"
check "established/related accepted BEFORE the ssh rules" yes "$(before "$N" 'established, related' 'tcp dport 22')"
check "invalid dropped first" yes "$(before "$N" 'ct state invalid drop' 'established, related')"
check "only table inet filter is destroyed (sshguard's survive)" "1" "$(code "$N" | grep -c '^destroy table')"
check "destroy targets inet filter" yes "$(has "$N" '^destroy table inet filter$')"
check "ssh v4 source is a define the operator can narrow" yes "$(has "$N" '^define ssh_allowed_v4 = ')"
check "ssh over IPv6 is off by default (no live v6 ssh rule)" 0 "$(code "$N" | grep -c 'dport 22 ip6')"
check "ssh over IPv6 is documented as a commented define" yes "$(has "$N" '^# define ssh_allowed_v6 = ')"
check "no live rule references the commented v6 define" 0 "$(code "$N" | grep -c 'ssh_allowed_v6')"
check "ssh is rate limited" yes "$(has "$N" 'tcp dport 22 .*limit rate over')"
check "icmpv6 allowed (neighbour discovery)" yes "$(has "$N" 'ipv6-icmp accept')"
check "no other inbound service port" 0 "$(code "$N" | grep -E 'dport' | grep -vc 'dport 22')"

echo
echo "(6) sysctl"
Y="$H/sysctl-90-cmesh-hardening.conf"
for kv in "kernel.kptr_restrict = 2" "kernel.dmesg_restrict = 1" "kernel.yama.ptrace_scope = 1" \
          "kernel.unprivileged_bpf_disabled = 1" "kernel.sysrq = 0" "fs.suid_dumpable = 0" \
          "net.ipv4.ip_forward = 0" "net.ipv4.conf.all.rp_filter = 1" \
          "net.ipv4.conf.all.accept_redirects = 0" "net.ipv4.conf.all.send_redirects = 0" \
          "net.ipv4.conf.all.log_martians = 1" "net.ipv4.tcp_syncookies = 1" \
          "net.ipv6.conf.all.accept_redirects = 0"; do
    check "$kv" yes "$(has "$Y" "^${kv//./\\.}$")"
done
check "every line is key = value or comment" 0 "$(grep -vcE '^(#.*|[a-z0-9_.*]+ = [0-9]+)?$' "$Y")"
check "IPv6 router advertisements are NOT disabled (OVH may route v6 via RA)" no "$(has "$Y" 'accept_ra')"

echo
echo "(7) audit rules"
A50="$H/audit-50-cmesh-hipaa.rules"
check "50- starts by flushing (-D) and sets a buffer" yes "$([ "$(before "$A50" '^-D$' '^-b ')" = yes ] && echo yes || echo no)"
check "failure mode is printk (-f 1), never panic (-f 2)" yes "$(has "$A50" '^-f 1$')"
check "no -f 2 anywhere" no "$(cat "$H"/audit-*.rules | grep -qE '^-f 2' && echo yes || echo no)"
for k in identity pam sshd priv rootcmd logins session bootpath luks raid systemd firewall \
         time modules mounts access perm_mod delete auditconfig packages; do
    check "key: $k" yes "$(has "$A50" " -k ${k}\$")"
done
check "root commands by logged-in users are recorded (auid filter)" yes "$(has "$A50" 'execve -F euid=0 -F auid>=1000 -F auid!=unset -k rootcmd')"
check "both arch=b64 and arch=b32 for execve" 2 "$(grep -cE '^-a always,exit -F arch=b(64|32) -S execve -F euid=0' "$A50")"
check "no unsupported path=~ shorthand" no "$(has "$A50" 'path=~')"
check "every rule line is -w, -a, -D, -b, -f, or --backlog" 0 "$(code "$A50" | grep -v '^$' | grep -vcE '^(-w |-a |-D$|-b |-f |--backlog)')"
check "60- watches a PHI location and says how to extend it" yes "$(has "$H/audit-60-cmesh-phi.rules" '^-w /srv/ -p wa -k phi$')"
check "99- is exactly -e 2" "-e 2" "$(code "$H/audit-99-cmesh-immutable.rules" | grep -v '^$')"
check "99- sorts last among shipped rules" "audit-99-cmesh-immutable.rules" "$(ls "$H" | grep '^audit-' | sort | tail -1)"

echo
echo "(8) the rest of the drop-ins"
check "journald persistent" yes "$(has "$H/journald-50-cmesh.conf" '^Storage=persistent$')"
check "journald sealed" yes "$(has "$H/journald-50-cmesh.conf" '^Seal=yes$')"
check "journald bounded (SystemMaxUse) on an 8 GiB root" yes "$(has "$H/journald-50-cmesh.conf" '^SystemMaxUse=')"
check "coredump storage none" yes "$(has "$H/coredump-50-cmesh.conf" '^Storage=none$')"
check "coredump ProcessSizeMax 0" yes "$(has "$H/coredump-50-cmesh.conf" '^ProcessSizeMax=0$')"
check "hard core limit 0 for all" yes "$(has "$H/limits-50-cmesh-core.conf" '^\*\s+hard\s+core\s+0$')"
check "shell TMOUT set and readonly" yes "$([ "$(has "$H/profile-cmesh-tmout.sh" 'TMOUT=900')" = yes ] && [ "$(has "$H/profile-cmesh-tmout.sh" 'readonly TMOUT')" = yes ] && echo yes || echo no)"
check "sudoers: wheel NOPASSWD (no passwords exist)" yes "$(has "$H/sudoers-10-cmesh-wheel" '^%wheel ALL=\(ALL:ALL\) NOPASSWD: ALL$')"
check "sudoers: I/O logging" yes "$(has "$H/sudoers-10-cmesh-wheel" '^Defaults log_input, log_output$')"
check "sudoers: no syntax trap (no trailing spaces, no tabs)" 0 "$(grep -cP '[ \t]$|\t' "$H/sudoers-10-cmesh-wheel")"
check "sshguard uses the nftables backend" yes "$(has "$H/sshguard.conf" '^BACKEND="/usr/lib/sshguard/sshg-fw-nft-sets"$')"
check "sshguard reads sshd-session too (OpenSSH 9.8+ tag)" yes "$(has "$H/sshguard.conf" '\-t sshd-session')"
check "smartd alerts via cmesh-alert, not mail" yes "$(has "$H/smartd.conf" '^DEVICESCAN .*-m <nomailer> -M exec /usr/local/sbin/cmesh-alert')"
check "mdmonitor override resets then sets ExecStart with --syslog" yes "$([ "$(grep -c '^ExecStart=' "$H/mdmonitor-override.conf")" = 2 ] && [ "$(has "$H/mdmonitor-override.conf" '^ExecStart=/usr/bin/mdadm --monitor --scan --syslog$')" = yes ] && echo yes || echo no)"
check "mdadm.conf gets PROGRAM cmesh-alert, idempotently" yes "$(has "$HARDEN" "grep -qE '\^PROGRAM\\\\s\+/usr/local/sbin/cmesh-alert'")"
check "mdmonitor is not 'enabled' (no [Install]; udev pulls it in)" no "$(code "$HARDEN" | sed -n '/^UNITS=(/,/)/p' | grep -q mdmonitor && echo yes || echo no)"
check "pacman hook re-baselines after transactions" yes "$(has "$H/pacman-cmesh-integrity.hook" '^Exec = /usr/local/sbin/cmesh-integrity accept$')"
check "pacman hook is PostTransaction" yes "$(has "$H/pacman-cmesh-integrity.hook" '^When = PostTransaction$')"
for t in cmesh-integrity.timer cmesh-arch-audit.timer; do
    check "$t has OnCalendar and Persistent and an [Install]" yes "$([ "$(has "$H/$t" '^OnCalendar=')" = yes ] && [ "$(has "$H/$t" '^Persistent=true')" = yes ] && [ "$(has "$H/$t" '^WantedBy=timers.target')" = yes ] && echo yes || echo no)"
done
check "integrity-init waits for finalize and runs once" yes "$([ "$(has "$H/cmesh-integrity-init.service" '^After=cmesh-byol-finalize.service')" = yes ] && [ "$(has "$H/cmesh-integrity-init.service" '^ConditionPathExists=!/var/lib/cmesh-byol/integrity/manifest.sha256')" = yes ] && echo yes || echo no)"
check "every unit ExecStart points at an installed path" "" "$(grep -h '^ExecStart=' "$H"/*.service | sed 's/^ExecStart=//; s/ .*//' | sort -u | while read -r x; do grep -q " ${x} " "$WORK/put.dest" 2>/dev/null || { code "$HARDEN" | grep -qE "^put \S+\s+${x}\s" || echo "$x"; }; done | tr '\n' ' ')"
check "kernel cmdline gets apparmor LSM and audit=1" yes "$([ "$(has "$HARDEN" "'lsm=landlock,lockdown,yama,integrity,apparmor,bpf'")" = yes ] && [ "$(has "$HARDEN" "'audit=1'")" = yes ] && echo yes || echo no)"
check "cmdline edit is idempotent (checks for the key first)" yes "$(has "$HARDEN" 'case " \$new " in \*" \${p%%=\*}="\*\)')"
check "auditd never suspends when the disk fills" yes "$([ "$(has "$HARDEN" '^auditconf disk_full_action ROTATE')" = yes ] && [ "$(has "$HARDEN" '^auditconf admin_space_left_action SYSLOG')" = yes ] && echo yes || echo no)"

echo
echo "(9) cmesh-integrity really detects change (scratch tree)"
T="$WORK/tree"; mkdir -p "$T/etc/ssh" "$T/boot" "$WORK/state"
echo "PermitRootLogin no" > "$T/etc/ssh/20.conf"; echo "kernel" > "$T/boot/vmlinuz"; ln -s 20.conf "$T/etc/ssh/link"
cat > "$WORK/alert" <<'ALERT'
#!/bin/bash
# Mirrors cmesh-alert's contract: message in the arguments, or on stdin if only the
# source is given. Never read stdin when a message was passed, or this blocks.
if [ $# -gt 1 ]; then shift; echo "$*" >> "$ALERT_OUT"; else cat >> "$ALERT_OUT"; fi
echo "src=$1" >> "$ALERT_OUT"
ALERT
chmod +x "$WORK/alert"
export ALERT_OUT="$WORK/alert.out"
export CMESH_INTEGRITY_STATE="$WORK/state" CMESH_INTEGRITY_WATCH="$T/etc $T/boot $T/missing" CMESH_INTEGRITY_ALERT="$WORK/alert"
out=$("$H/cmesh-integrity" init 2>&1); check "init writes a baseline" 0 $?
check "manifest has the 3 entries" 3 "$(wc -l < "$WORK/state/manifest.sha256")"
"$H/cmesh-integrity" check >/dev/null 2>&1; check "check passes with no change" 0 $?
check "no alert on a clean check" no "$([ -s "$ALERT_OUT" ] && echo yes || echo no)"
echo "PermitRootLogin yes" > "$T/etc/ssh/20.conf"
echo "x" > "$T/etc/ssh/new.conf"
rm "$T/boot/vmlinuz"
ln -sfn new.conf "$T/etc/ssh/link"
out=$("$H/cmesh-integrity" check 2>&1); check "check fails after changes" 1 $?
check "changed file reported" yes "$(printf '%s' "$out" | grep -q 'changed: .*/etc/ssh/20.conf' && echo yes || echo no)"
check "new file reported" yes "$(printf '%s' "$out" | grep -q 'new: .*/etc/ssh/new.conf' && echo yes || echo no)"
check "removed file reported" yes "$(printf '%s' "$out" | grep -q 'removed: .*/boot/vmlinuz' && echo yes || echo no)"
check "retargeted symlink reported" yes "$(printf '%s' "$out" | grep -q 'changed: .*/etc/ssh/link' && echo yes || echo no)"
check "alert sink was called with source 'integrity'" yes "$(grep -q '^src=integrity$' "$ALERT_OUT" && echo yes || echo no)"
"$H/cmesh-integrity" accept >/dev/null 2>&1
"$H/cmesh-integrity" check >/dev/null 2>&1; check "accept re-baselines; check passes again" 0 $?
"$H/cmesh-integrity" bogus >/dev/null 2>&1; check "unknown verb exits 64" 64 $?
rm -f "$WORK/state/manifest.sha256"
"$H/cmesh-integrity" check >/dev/null 2>&1; check "missing baseline exits 2 (and alerts)" 2 $?

echo
echo "(10) cmesh-alert routes every caller to one log"
# CMESH_ALERT_CONFIG pins the delivery config away from whatever this machine has:
# without it, a developer box with /etc/cmesh-byol/alert.env would have the suite
# uploading objects to a bucket.
export CMESH_ALERT_LOG="$WORK/alerts.log" CMESH_ALERT_CONFIG=/dev/null
"$H/cmesh-alert" integrity "manual message" >/dev/null 2>&1
check "generic: [source] message" yes "$(grep -q '\[integrity\] manual message$' "$CMESH_ALERT_LOG" && echo yes || echo no)"
"$H/cmesh-alert" DegradedArray /dev/md127 >/dev/null 2>&1
check "mdadm PROGRAM call shape is recognised" yes "$(grep -q '\[mdadm\] DegradedArray /dev/md127$' "$CMESH_ALERT_LOG" && echo yes || echo no)"
SMARTD_MESSAGE="Device: /dev/nvme0, 5 Currently unreadable sectors" SMARTD_DEVICE=/dev/nvme0 SMARTD_FAILTYPE=CurrentPendingSector "$H/cmesh-alert" >/dev/null 2>&1
check "smartd -M exec environment is recognised" yes "$(grep -q '\[smartd\] Device: /dev/nvme0.*CurrentPendingSector' "$CMESH_ALERT_LOG" && echo yes || echo no)"
printf 'line1\nline2\n' | "$H/cmesh-alert" arch-audit >/dev/null 2>&1
check "stdin message accepted" yes "$(grep -q '\[arch-audit\] line1' "$CMESH_ALERT_LOG" && echo yes || echo no)"
check "always exits 0 (a failing alert must not fail its caller)" 0 "$("$H/cmesh-alert" x y >/dev/null 2>&1; echo $?)"

echo
echo "(11) provision.sh runs it at build, in the right place"
check "Phase 4a calls harden --build" yes "$(has "$PROVISION" 'cmesh-byol-harden" --build --files "\$FILES_SRC/hardening"')"
check "a missing harden script fails the build" yes "$(has "$PROVISION" 'FATAL: \$\{FILES_SRC\}/cmesh-byol-harden or hardening/ was not delivered')"
check "a failed harden run fails the build" yes "$(has "$PROVISION" 'FATAL: cmesh-byol-harden --build failed')"
check "after the installer is in place" yes "$(before "$PROVISION" 'install -Dm755 "\$FILES_SRC/cmesh-byol-install"' 'cmesh-byol-harden" --build')"
check "before the deploy hook / bootloader phase" yes "$(before "$PROVISION" 'cmesh-byol-harden" --build' 'make_image_bootable.sh')"

echo
echo "(12) the installer creates the admin account and only then closes root"
check "install_admin_user exists" yes "$(has "$INSTALLER" '^install_admin_user\(\)')"
check "it is called from install_ssh_keys after root's keys" yes "$(before "$INSTALLER" 'printf .%s.n. "\$CMESH_SSH_KEYS" > "\$MNT/root/.ssh/authorized_keys"' '^        install_admin_user$')"
check "useradd into wheel with a shell, no password" yes "$(has "$INSTALLER" 'useradd -m -G wheel -s /bin/bash "\$u"')"
check "useradd failure leaves root open (return, not die)" yes "$(has "$INSTALLER" 'could not create admin user \$\{u\}; root SSH login stays enabled"; return 0')"
check "keys written to the admin before root is closed" yes "$(before "$INSTALLER" 'printf .%s.n. "\$CMESH_SSH_KEYS" > "\$MNT\$home/.ssh/authorized_keys"' 'sshd_config.d/20-cmesh-users.conf')"
check "empty key file leaves root open" yes "$(before "$INSTALLER" 'has no keys; root SSH login stays enabled' 'sshd_config.d/20-cmesh-users.conf')"
check "drop-in is 20-cmesh-users.conf with PermitRootLogin no + AllowUsers" yes "$([ "$(has "$INSTALLER" '20-cmesh-users.conf')" = yes ] && [ "$(has "$INSTALLER" '^PermitRootLogin no$')" = yes ] && [ "$(has "$INSTALLER" '^AllowUsers \$\{u\}$')" = yes ] && echo yes || echo no)"
check "cmesh_admin_user is read from user data" yes "$(has "$INSTALLER" "cmesh_admin_user:' \"\\\$ud\"")"
check "defaults to admin" yes "$(has "$INSTALLER" 'CMESH_ADMIN_USER="\$\{CMESH_ADMIN_USER:-admin\}"')"
check "name is validated" yes "$(has "$INSTALLER" "grep -Eq '\^\[a-z_\]\[a-z0-9_-\]\{0,31\}\\$'")"
check "root is refused as the admin name" yes "$(has "$INSTALLER" 'cmesh_admin_user must not be root')"
check "the harden script's default admin name matches the installer's" "admin" "$(sed -nE 's/^ADMIN_USER="\$\{CMESH_ADMIN_USER:-([a-z]+)\}"$/\1/p' "$HARDEN")"

echo
echo "(13) Secure Boot: cmesh-byol-secureboot cannot brick the box"
SB="$H/cmesh-byol-secureboot"
bash -n "$SB" 2>/dev/null; check "bash -n cmesh-byol-secureboot" 0 $?
check "status needs no root and runs no preflight" 0 "$(code "$SB" | sed -n '/^status()/,/^}/p' | grep -c 'preflight\|id -u')"
check "prepare: refuses outside the finalized system" yes "$(has "$SB" 'finalized" \] \|\| die')"
check "prepare: refuses without UEFI" yes "$(has "$SB" '/sys/firmware/efi \] \|\| die "not booted via UEFI"')"
check "prepare: cmdline is root=UUID + GRUB_CMDLINE_LINUX" yes "$(has "$SB" 'new="root=UUID=\$\{root_uuid\} rw\$\{grub_cl:\+ \$grub_cl\}"')"
check "prepare: warns when console= is missing" yes "$(has "$SB" 'no console= on the command line')"
check "prepare: default_image is kept (GRUB fallback)" no "$(has "$SB" "sed -i.*default_image=.*/d")"
check "prepare: UKI must be larger than the kernel" yes "$(has "$SB" 'is smaller than the kernel; not a UKI')"
check "prepare: signs with -s (registered for sbctl sign-all)" yes "$(has "$SB" 'sbctl sign -s "\$UKI"')"
check "prepare: signature verified after signing" yes "$(before "$SB" 'sbctl sign -s "\$UKI"' 'carries no signature after sbctl sign')"
check "prepare: GRUB saved before BOOTX64.EFI is replaced" yes "$(before "$SB" 'grub-fallback.efi" && sync' 'cmesh-esp-sync sync || die')"
check "prepare: never overwrites an existing fallback" yes "$(has "$SB" '\[ ! -f "\$mnt/EFI/cmesh/grub-fallback.efi" \]')"
check "prepare: marker written before sync (sync refuses without it)" yes "$(before "$SB" 'date -Is > "\$P_MARK"' 'cmesh-esp-sync sync || die')"
check "prepare: does NOT touch the TPM token" 0 "$(code "$SB" | sed -n '/^prepare()/,/^}/p' | grep -c cryptenroll)"
check "prepare: does NOT enrol keys" 0 "$(code "$SB" | sed -n '/^prepare()/,/^}/p' | grep -c enroll-keys)"
check "enroll: requires prepare" yes "$(has "$SB" '\[ -f "\$P_MARK" \] \|\| die "run prepare first')"
check "enroll: requires Setup Mode with KVM instructions" yes "$(has "$SB" 'setup_mode \|\| die "firmware is not in Setup Mode. Over the OVHcloud KVM')"
check "enroll: every ESP must hold the current UKI before keys go in" yes "$(before "$SB" 'is not the current signed UKI; run prepare again' 'sbctl enroll-keys -m')"
check "enroll: PCR-less token before enroll-keys" yes "$(before "$SB" 'reseal "\$dev" ""' 'sbctl enroll-keys -m')"
check "enroll: passphrase slot required before touching the token" yes "$(before "$SB" 'has no passphrase slot; refusing to touch its TPM token' 'reseal "\$dev" ""')"
check "reseal: tries the existing TPM token first" yes "$(has "$SB" 'systemd-cryptenroll --unlock-tpm2-device=auto --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="\$pcrs" "\$dev"')"
check "reseal: passphrase fallback only with a terminal (never blocks the finish unit)" yes "$(before "$SB" '\[ -t 0 \] || { warn' 'systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="\$pcrs" "\$dev" || return 1')"
check "enroll and finish both go through reseal" 2 "$(code "$SB" | grep -c '^        reseal "\$dev" ')"
check "no cryptenroll call outside reseal" 0 "$(code "$SB" | sed '/^reseal()/,/^}/d' | grep -c 'systemd-cryptenroll --')"
check "reseal prunes stale tokens after both the TPM and the passphrase path" 2 "$(code "$SB" | sed -n '/^reseal()/,/^}/p' | grep -c 'prune_stale_tokens "\$dev"')"
check "prune: only tokens bound to no keyslot" yes "$(has "$SB" 'cryptsetup token export --token-id "\$id" "\$dev" 2>/dev/null | grep -q .*keyslots.*\\\[')"
check "prune: only systemd-tpm2 tokens are candidates" yes "$(has "$SB" ': systemd-tpm2\$/ \{sub')"
check "prune: removal is per token id, never luksKillSlot" 0 "$(code "$SB" | grep -c luksKillSlot)"
check "enroll: Microsoft certs kept (-m) for option ROMs and rescue" yes "$(has "$SB" 'sbctl enroll-keys -m -t .*|| sbctl enroll-keys -m ')"
check "enroll: failure after re-seal alerts and says how to recover" yes "$(has "$SB" 'TPM token is PCR-less — run finish after fixing')"
check "enroll: finish unit enabled only after enrolment" yes "$(before "$SB" 'date -Is > "\$E_MARK"' 'systemctl enable cmesh-byol-secureboot-finish.service >/dev/null 2>&1 && ok')"
check "finish: refuses while Secure Boot is off, alerts, retries next boot" yes "$([ "$(has "$SB" 'Secure Boot is NOT enforcing on this boot')" = yes ] && [ "$(has "$SB" 'die "Secure Boot is off; not binding the TPM to it"')" = yes ] && echo yes || echo no)"
check "finish: binds to PCR 7" yes "$([ "$(has "$SB" '^PCRS=7$')" = yes ] && [ "$(has "$SB" 'reseal "\$dev" "\$PCRS"')" = yes ] && echo yes || echo no)"
check "finish: SB check before the re-seal" yes "$(before "$SB" 'ok "Secure Boot: enforcing"' 'reseal "\$dev" "\$PCRS"')"
check "finish: marker only after every device is sealed" yes "$(before "$SB" 'reseal "\$dev" "\$PCRS"' 'date -Is > "\$F_MARK"')"
check "unit: runs only between enrolled and finished" yes "$([ "$(has "$H/cmesh-byol-secureboot-finish.service" '^ConditionPathExists=/var/lib/cmesh-byol/secureboot-enrolled$')" = yes ] && [ "$(has "$H/cmesh-byol-secureboot-finish.service" '^ConditionPathExists=!/var/lib/cmesh-byol/secureboot-finished$')" = yes ] && echo yes || echo no)"
check "harden installs sbctl" yes "$(code "$HARDEN" | grep -q '^PKGS=.* sbctl)' && echo yes || echo no)"
check "harden enables the finish unit (inert until enroll)" yes "$(code "$HARDEN" | sed -n '/^UNITS=(/,/)/p' | grep -q 'cmesh-byol-secureboot-finish.service' && echo yes || echo no)"
check "initcpio post hook sorts after sbctl's" yes "$([[ "zz-cmesh-esp-sync" > "sbctl" ]] && echo yes || echo no)"
check "pacman hook sorts after zz-sbctl.hook" yes "$([[ "zzz-cmesh-esp-sync.hook" > "zz-sbctl.hook" ]] && echo yes || echo no)"
check "esp-sync refuses an unsigned image (alerts, keeps the old one)" yes "$(has "$H/cmesh-esp-sync" 'is NOT signed and could not be signed; BOOTX64.EFI NOT updated')"
check "esp-sync is a no-op before prepare" yes "$(has "$H/cmesh-esp-sync" 'not prepared for Secure Boot')"
check "esp-sync writes then renames (never a half-written loader)" yes "$(has "$H/cmesh-esp-sync" 'BOOTX64.EFI.new" && sync && mv -f')"
# Found on the server: the fstab ESP is mounted at /boot/efi and vfat refuses a second
# mount ("Can't mount, would change RO state"), so the second disk was skipped.
for f in "$SB" "$H/cmesh-esp-sync"; do
    check "$(basename "$f"): reuses an existing mount of the ESP (findmnt -S)" yes "$(has "$f" 'findmnt -nro TARGET -S "\$dev"')"
    check "$(basename "$f"): no direct mount of an ESP outside esp_mount" 0 "$(code "$f" | sed '/^esp_mount()/,/^}/d' | grep -cE 'mount -o (ro|umask=0077) "\$dev"')"
    check "$(basename "$f"): no hostname(1) (not in the image)" no "$(has "$f" 'hostname)')"
done
check "harden --status: no hostname(1)" no "$(has "$HARDEN" 'hostname)')"
check "PE check reads 2 bytes of the PE signature (no null bytes into bash)" yes "$(has "$H/cmesh-esp-sync" 'count=2 2>/dev/null)" = "PE"')"
check "prepare: root=/rw/ro stripped from GRUB_CMDLINE_LINUX before composing" yes "$(has "$SB" "grep -vE '\^\(root=\|rootflags=\|rw\\\$\|ro\\\$\|\\\$\)'")"

echo
echo "(14) cmesh-esp-sync check: a real PE32+ parser"
# Build minimal PE32+ images: MZ header, e_lfanew at 0x3c -> "PE\0\0", COFF (20 bytes),
# optional header with magic 0x20b, 16 data directories; entry 4 = certificate table.
mkpe() { # mkpe <out> <cert-rva> <cert-size>
    local out="$1" rva="$2" size="$3"
    { printf 'MZ'; head -c 58 /dev/zero; printf '\x80\x00\x00\x00'; head -c 64 /dev/zero   # e_lfanew = 0x80
      printf 'PE\0\0'; head -c 20 /dev/zero                                                 # COFF
      printf '\x0b\x02'; head -c 110 /dev/zero                                              # magic 0x20b + rest of std/windows fields
      head -c 32 /dev/zero                                                                  # dirs 0-3
      printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((rva & 255)) $((rva >> 8 & 255)) $((rva >> 16 & 255)) $((rva >> 24 & 255)))"
      printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((size & 255)) $((size >> 8 & 255)) $((size >> 16 & 255)) $((size >> 24 & 255)))"
      head -c 88 /dev/zero; } > "$out"
}
mkpe "$WORK/signed.efi" 4096 1234
mkpe "$WORK/unsigned.efi" 0 0
printf 'not a PE at all' > "$WORK/text.bin"
"$H/cmesh-esp-sync" check "$WORK/signed.efi";   check "PE32+ with a certificate table: signed (0)" 0 $?
"$H/cmesh-esp-sync" check "$WORK/unsigned.efi"; check "PE32+ with an empty certificate table: unsigned (1)" 1 $?
"$H/cmesh-esp-sync" check "$WORK/text.bin";     check "not a PE: 2" 2 $?
"$H/cmesh-esp-sync" check "$WORK/nonexistent";  check "missing file: 2" 2 $?
export CMESH_ESP_LABEL=NO_SUCH_LABEL_$$ CMESH_UKI="$WORK/signed.efi"
"$H/cmesh-esp-sync" sync >/dev/null 2>&1;       check "sync without the prepared marker is a no-op (0)" 0 $?

echo
echo "(15) cmesh-logwatch: journal errors alert, journal text never leaves"
# Everything cmesh-logwatch shells out to is stubbed, so this runs anywhere -- the same
# reason cmesh-integrity takes CMESH_INTEGRITY_*. The stub alert records the source and
# the message it was handed, which is what makes the PHI assertion below possible: the
# canned journal line contains a patient id and an SSN, and no assertion here would
# catch them leaking if the alert simply quoted the line.
LW="$WORK/lw"; mkdir -p "$LW"
cat > "$LW/alert" <<'LALERT'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_OUT"
LALERT
cat > "$LW/journalctl" <<'LJL'
#!/bin/bash
[ -n "${FAKE_JOURNAL:-}" ] && cat "$FAKE_JOURNAL"
[ -n "${FAKE_JOURNAL_FAIL:-}" ] && exit 3
exit 0
LJL
cat > "$LW/systemctl" <<'LSC'
#!/bin/bash
case "$1" in
    --failed) printf '%s\n' "${FAKE_FAILED:-}" ;;
    show) case "$*" in
              *NRestarts*)      printf '%s\n' "${FAKE_RESTARTS:-0}" ;;
              *Result*)         printf '%s\n' "${FAKE_RESULT:-exit-code}" ;;
              *ExecMainStatus*) printf '%s\n' "${FAKE_STATUS:-1}" ;;
          esac ;;
esac
LSC
cat > "$LW/openssl" <<'LOS'
#!/bin/bash
case "$*" in
    *-enddate*)  [ -n "${FAKE_CERT_UNREADABLE:-}" ] && exit 1
                 printf 'notAfter=%s\n' "${FAKE_NOTAFTER:-Nov  1 00:00:00 2026 GMT}" ;;
    *-checkend*) [ -n "${FAKE_CERT_OLD:-}" ] && exit 1; exit 0 ;;
esac
LOS
chmod +x "$LW/alert" "$LW/journalctl" "$LW/systemctl" "$LW/openssl"
export ALERT_OUT="$LW/alerts" CMESH_LOGWATCH_STATE="$LW/state" CMESH_LOGWATCH_ALERT="$LW/alert" \
       CMESH_LOGWATCH_JOURNALCTL="$LW/journalctl" CMESH_LOGWATCH_SYSTEMCTL="$LW/systemctl" \
       CMESH_LOGWATCH_OPENSSL="$LW/openssl" CMESH_LOGWATCH_CERTDIR="$LW/certs" \
       CMESH_LOGWATCH_UNITS="marshall-live"
lw_reset() { rm -rf "$LW/state"; : > "$ALERT_OUT"; }
lw() { "$H/cmesh-logwatch" >/dev/null 2>&1; }

lw_reset
printf '%s\n' '** (exit) an exception was raised: patient 40912 record ss 123-45-6789' > "$LW/journal"
export FAKE_JOURNAL="$LW/journal"
lw
check "a first scan primes the window (install-day noise is not an alert)" 0 "$(wc -l < "$ALERT_OUT")"
lw
check "a hard error raises exactly one alert" 1 "$(wc -l < "$ALERT_OUT")"
check "the alert names the class, not the line" yes "$(grep -q 'process-exit=1' "$ALERT_OUT" && echo yes || echo no)"
check "the alert carries the journalctl command to read the detail" yes "$(grep -q 'journalctl -u marshall-live --since' "$ALERT_OUT" && echo yes || echo no)"
check "NO journal text in the alert (patient id, SSN, exception text)" 0 "$(grep -c '40912\|123-45-6789\|exception was raised' "$ALERT_OUT")"
lw
check "the same class does not re-alert inside the repeat window" 1 "$(wc -l < "$ALERT_OUT")"

lw_reset
: > "$FAKE_JOURNAL"
printf 'a benign err line\na second one\n' > "$LW/journal"
lw; lw
check "err lines below ERR_MAX do not alert" 0 "$(wc -l < "$ALERT_OUT")"
CMESH_LOGWATCH_ERR_MAX=2 lw
check "a burst at ERR_MAX does alert" 1 "$(wc -l < "$ALERT_OUT")"
check "the burst is reported by count, not by quoting" yes "$(grep -q 'unclassified=2' "$ALERT_OUT" && echo yes || echo no)"

lw_reset
: > "$LW/journal"
# The leading marker is what systemctl writes when stdout is not a tty, which is how a
# systemd unit always sees it -- parsing field 1 would take the bullet, not the unit.
FAKE_FAILED="* marshall-live.service loaded failed failed Marshall Live Server" lw
check "a unit in the failed state alerts on the first run (nothing to prime)" 1 "$(wc -l < "$ALERT_OUT")"
check "the unit name is parsed past systemctl's non-tty bullet" yes "$(grep -q 'marshall-live.service is in the failed state' "$ALERT_OUT" && echo yes || echo no)"
FAKE_FAILED="* marshall-live.service loaded failed failed Marshall Live Server" lw
check "a unit that stays failed does not nag every five minutes" 1 "$(wc -l < "$ALERT_OUT")"

lw_reset
FAKE_RESTARTS=0 lw
check "a stable restart count stays quiet" 0 "$(wc -l < "$ALERT_OUT")"
FAKE_RESTARTS=2 lw
check "an increased restart count alerts" 1 "$(wc -l < "$ALERT_OUT")"
check "the restart alert reports the delta and the total" yes "$(grep -q 'auto-restarted 2 time(s).*(2 total)' "$ALERT_OUT" && echo yes || echo no)"

lw_reset
mkdir -p "$LW/certs/model.marshall.work"; : > "$LW/certs/model.marshall.work/fullchain.pem"
lw
check "a certificate outside the window stays quiet" 0 "$(wc -l < "$ALERT_OUT")"
lw_reset
FAKE_CERT_OLD=1 lw
check "a certificate inside the window alerts with its notAfter" yes "$(grep -q 'expires within 21 days (Nov  1 00:00:00 2026 GMT)' "$ALERT_OUT" && echo yes || echo no)"
check "the expiry alert names the certbot command to check" yes "$(grep -q 'certbot-renew.timer && certbot certificates' "$ALERT_OUT" && echo yes || echo no)"
lw_reset
FAKE_CERT_UNREADABLE=1 lw
check "an unreadable certificate is its own alert, not a guessed expiry" yes "$(grep -q 'cannot read the TLS certificate' "$ALERT_OUT" && echo yes || echo no)"

lw_reset
mkdir -p "$LW/state"
printf '1000000000\n' > "$LW/state/marshall-live.last"
FAKE_JOURNAL_FAIL=1 lw
check "a failed journalctl read leaves the window open (its errors are not lost)" 1000000000 "$(cat "$LW/state/marshall-live.last")"
lw_reset
mkdir -p "$LW/state"
printf '1000000000\n' > "$LW/state/marshall-live.last"
printf '=CRASH REPORT==== 9-Oct-2026\n' > "$LW/journal"
lw
check "a long downtime does not replay a week of errors (window is capped)" yes "$(grep -q "since $(date -Is | cut -c1-4)" "$ALERT_OUT" && echo yes || echo no)"

: > "$ALERT_OUT"
CMESH_ALERT_BIN="$LW/alert" CMESH_UNIT_FAILED_SYSTEMCTL="$LW/systemctl" "$H/cmesh-unit-failed" marshall-live
check "cmesh-unit-failed exits 0 (a failed alert must not fail its caller)" 0 $?
check "it names the unit as the alert source" yes "$(grep -q '^marshall-live ' "$ALERT_OUT" && echo yes || echo no)"
check "it reports the unit, result, exit status and restarts" yes "$(grep -q 'marshall-live.service FAILED (result=exit-code exit=1 restarts=' "$ALERT_OUT" && echo yes || echo no)"
CMESH_ALERT_BIN="$LW/alert" "$H/cmesh-unit-failed" >/dev/null 2>&1
check "a missing unit argument exits 64" 64 $?
check "cmesh-alert@.service runs cmesh-unit-failed with the instance name" yes "$(has "$H/cmesh-alert@.service" 'ExecStart=/usr/local/sbin/cmesh-unit-failed %i')"

echo
echo "(16) cmesh-alert delivery: off by default, never fatal, never plaintext"
DL="$WORK/dl"; mkdir -p "$DL"
cat > "$DL/aws" <<'DAWS'
#!/bin/bash
echo "$*" >> "$AWS_LOG"
DAWS
cat > "$DL/age" <<'DAGE'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && cp "${!#}" "$out"
DAGE
cat > "$DL/agefail" <<'DAGEFAIL'
#!/bin/bash
echo "age: no identity matched any of the recipients" >&2
exit 1
DAGEFAIL
chmod +x "$DL/aws" "$DL/age" "$DL/agefail"
printf 'age1testrecipient\n' > "$DL/recipients"
export CMESH_ALERT_LOG="$DL/alerts.log" CMESH_ALERT_AWS="$DL/aws" CMESH_ALERT_AGE="$DL/age" AWS_LOG="$DL/aws.log"
: > "$AWS_LOG"
CMESH_ALERT_CONFIG=/dev/null "$H/cmesh-alert" logwatch "unit X: 1 hard error" >/dev/null 2>&1
check "with no config nothing is sent, and the caller still succeeds" 0 "$(wc -l < "$AWS_LOG")"
check "with no config the alert is still on the box" yes "$(grep -q 'unit X: 1 hard error' "$CMESH_ALERT_LOG" && echo yes || echo no)"
CMESH_ALERT_CONFIG=/dev/null CMESH_ALERT_DELIVERY=s3 "$H/cmesh-alert" logwatch "unit X: 1 hard error" >/dev/null 2>&1
check "delivery=s3 with no bucket stays local instead of failing" 0 "$(wc -l < "$AWS_LOG")"

cat > "$DL/alert.env" <<DENV
CMESH_ALERT_DELIVERY=s3
CMESH_ALERT_S3_ENDPOINT=us-east-1.linodeobjects.com
CMESH_ALERT_S3_BUCKET=cmeshai-backups
CMESH_ALERT_S3_PREFIX=alerts
CMESH_ALERT_AGE_RECIPIENTS=$DL/recipients
CMESH_ALERT_CREDENTIALS_FILE=$DL/creds.env
DENV
CMESH_ALERT_CONFIG="$DL/alert.env" "$H/cmesh-alert" logwatch "unit X: 1 hard error" >/dev/null 2>&1
check "an unreadable credentials file stays local instead of shipping" 0 "$(wc -l < "$AWS_LOG")"
printf 'AWS_ACCESS_KEY_ID=AKIATEST\nAWS_SECRET_ACCESS_KEY=x\nUNRELATED=nothing\n' > "$DL/creds.env"
CMESH_ALERT_CONFIG="$DL/alert.env" "$H/cmesh-alert" logwatch "unit X: 1 hard error" >/dev/null 2>&1
check "a configured host uploads exactly one object" 1 "$(wc -l < "$AWS_LOG")"
check "the object lands under the prefix and host" yes "$(grep -q 's3://cmeshai-backups/alerts/[^/]*/20[0-9]*T[0-9]*Z-[0-9]*-logwatch\.json\.age' "$AWS_LOG" && echo yes || echo no)"
check "the endpoint is object storage, not AWS itself" yes "$(grep -q -- '--endpoint-url https://us-east-1.linodeobjects.com' "$AWS_LOG" && echo yes || echo no)"
before=$(wc -l < "$AWS_LOG")
CMESH_ALERT_CONFIG="$DL/alert.env" CMESH_ALERT_AGE="$DL/agefail" "$H/cmesh-alert" logwatch "unit X" >/dev/null 2>&1
check "an age failure uploads nothing (no plaintext object)" "$before" "$(wc -l < "$AWS_LOG")"

echo
echo "(17) the installer wires all of it"
check "the logwatch timer is enabled" yes "$(has "$HARDEN" 'cmesh-logwatch.timer cmesh-byol-secureboot-finish.service')"
check "the logwatch timer is started, not just enabled" yes "$(has "$HARDEN" 'cmesh-integrity.timer cmesh-logwatch.timer systemd-timesyncd.service')"
for u in httpd marshall-model marshall-live certbot-renew cmesh-logwatch; do
    check "OnFailure is wired for ${u}" yes "$(has "$HARDEN" 'OnFailure=cmesh-alert@\$\{u\}\.service')"
done
check "the OnFailure drop-in is not written for a unit that does not exist" yes "$(has "$HARDEN" 'no \$\{u\}\.service on this host; nothing to wire')"
check "a configured alert.env is never clobbered" yes "$(has "$HARDEN" 'kept /etc/cmesh-byol/alert.env')"
check "an unconfigured host is seeded from the template, 0600" yes "$(has "$HARDEN" 'install -m 0600 "\$FILES/cmesh-alert.env.example" /etc/cmesh-byol/alert.env')"
check "the poller is not installed on the server" "" "$(code "$HARDEN" | grep -E '^put ' | awk '$2 ~ /poller/ {print $2}')"

echo
echo "(18) cmesh-alert-poller: reads the dead-drop, and never loses one it cannot read"
PL="$WORK/pl"; mkdir -p "$PL"
cat > "$PL/aws" <<'PAWS'
#!/bin/bash
case "$1$2" in
    s3ls) printf '%s\n' "${FAKE_LISTING:-}" ;;
    s3cp) cat "${FAKE_OBJECT:?}" ;;
esac
PAWS
cat > "$PL/age" <<'PAGE'
#!/bin/bash
[ -n "${FAKE_UNDECRYPTABLE:-}" ] && { echo "age: no identity matched" >&2; exit 1; }
cat "${FAKE_PLAIN:?}"
PAGE
chmod +x "$PL/aws" "$PL/age"
printf 'AGE-SECRET-KEY-1TEST\n' > "$PL/identity"
printf 'ciphertext' > "$PL/object"
printf '{"ts":"2026-10-09T16:00:00-04:00","host":"msh-ca-21","source":"logwatch","message":"marshall-live: 2 hard errors"}\n' > "$PL/plain"
export CMESH_ALERT_S3_ENDPOINT=us-east-1.linodeobjects.com CMESH_ALERT_S3_BUCKET=cmeshai-backups \
       CMESH_ALERT_AGE_IDENTITY="$PL/identity" CMESH_ALERT_STATE="$PL/state" \
       CMESH_ALERT_AWS="$PL/aws" CMESH_ALERT_AGE="$PL/age" \
       FAKE_OBJECT="$PL/object" FAKE_PLAIN="$PL/plain" \
       FAKE_LISTING="2026-10-09 16:00:00 100 alerts/msh-ca-21/20261009T160000Z-1-logwatch.json.age"
out=$("$POLLER" 2>&1)
check "a new alert is printed" yes "$(printf '%s' "$out" | grep -q 'marshall-live: 2 hard errors' && echo yes || echo no)"
out=$("$POLLER" 2>&1)
check "the same object is not printed twice" yes "$(printf '%s' "$out" | grep -q 'no new alerts' && echo yes || echo no)"
out=$("$POLLER" --all 2>&1)
check "--all re-reads what is already marked read" yes "$(printf '%s' "$out" | grep -q 'marshall-live: 2 hard errors' && echo yes || echo no)"
rm -rf "$PL/state"
out=$("$POLLER" --dry-run 2>&1)
check "--dry-run lists what a real run would read" yes "$(printf '%s' "$out" | grep -q 'would read s3://cmeshai-backups/alerts/msh-ca-21/' && echo yes || echo no)"
out=$("$POLLER" 2>&1)
check "--dry-run consumed nothing (the next real run still reads it)" yes "$(printf '%s' "$out" | grep -q 'marshall-live: 2 hard errors' && echo yes || echo no)"
rm -rf "$PL/state"
FAKE_UNDECRYPTABLE=1 "$POLLER" >/dev/null 2>&1
check "an undecryptable alert fails loudly instead of being skipped" 1 $?
check "an undecryptable alert is NOT marked read" "" "$(grep -o '20261009T160000Z-1' "$PL/state/seen" 2>/dev/null)"
CMESH_ALERT_S3_BUCKET="" "$POLLER" >/dev/null 2>&1
check "a missing bucket is a hard error, not a silent no-op" 1 $?

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

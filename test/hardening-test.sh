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
for f in "$HARDEN" "$H/cmesh-alert" "$H/cmesh-integrity" "$H/cmesh-arch-audit"; do
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
export CMESH_ALERT_LOG="$WORK/alerts.log"
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
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

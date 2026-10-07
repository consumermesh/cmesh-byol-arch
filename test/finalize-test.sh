#!/bin/bash
# Guards the order of operations in build_archlinux/files/cmesh-byol-finalize.
#
# WHY THIS EXISTS
#
# The first finalize ran on real hardware and failed on its first real command: it handed
# systemd-cryptenroll the plaintext mapping (/dev/mapper/cryptroot0) instead of the LUKS
# partition behind it, and would have hung on a passphrase prompt had that worked. Worse,
# it deleted the keyfile BEFORE rebuilding the initramfs that still embedded it. None of
# this is testable without a TPM and two LUKS devices, so the script's structure is
# asserted here instead: what it runs against, what it passes, and in which order.
#
# Usage: test/finalize-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FINALIZE="$REPO/build_archlinux/files/cmesh-byol-finalize"
[ -f "$FINALIZE" ] || { echo "FATAL: $FINALIZE not found" >&2; exit 1; }
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
CODE="$(mktemp)"
trap 'rm -f "$CODE"' EXIT
grep -v '^[[:space:]]*#' "$FINALIZE" > "$CODE"
count()   { grep -c -- "$1" "$CODE" || true; }
line_of() { grep -n -- "$1" "$CODE" | head -1 | cut -d: -f1; }
before()  { # before <pattern-a> <pattern-b> -> yes if a's first match precedes b's
    local a b; a=$(line_of "$1"); b=$(line_of "$2")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo yes || echo no
}

bash -n "$FINALIZE" && check "script is valid bash" 0 0 || check "script is valid bash" 0 1

echo
echo "(1) it works on the LUKS partition, never on the plaintext mapping"
check "backing device resolved from cryptsetup status" \
    "yes" "$(grep -q 'cryptsetup status "\$name" | awk' "$CODE" && echo yes || echo no)"
check "backing device must carry a crypto_LUKS signature" "yes" "$(grep -q 'crypto_LUKS' "$CODE" && echo yes || echo no)"
check "cryptenroll never sees /dev/mapper" "0" "$(count 'cryptenroll.*/dev/mapper')"
check "nothing is built from a /dev/mapper/ prefix" "0" "$(count '"/dev/mapper/"')"

echo
echo "(2) enrolment can run without a TTY"
check "cryptenroll unlocks with the keyfile" "yes" "$(grep -q -- '--unlock-key-file="\$LUKS_KEY"' "$CODE" && echo yes || echo no)"
check "TPM2 device and PCR policy given" "yes" "$(grep -q -- '--tpm2-device=auto --tpm2-pcrs="\$PCRS"' "$CODE" && echo yes || echo no)"
check "re-run does not enrol a second token" "yes" "$(grep -q 'already carries a TPM2 token' "$CODE" && echo yes || echo no)"

echo
echo "(3) nothing is destroyed until the boot path no longer needs it"
check "enrol before crypttab rewrite"            "yes" "$(before 'tpm2-pcrs=' 's|\${LUKS_KEY}|none|g')"
check "token verified before crypttab rewrite"   "yes" "$(before 'no TPM2 token visible' 's|\${LUKS_KEY}|none|g')"
check "keyslot number read while keyfile exists" "yes" "$(before 'test-passphrase --disable-external-tokens' 'shred -u')"
check "keyslot number read BEFORE any TPM token exists" "yes" "$(before 'test-passphrase --disable-external-tokens' 'tpm2-pcrs=')"
check "token plugins disabled when asking which slot the keyfile is" \
    "yes" "$(grep -q -- '--test-passphrase --disable-external-tokens' "$CODE" && echo yes || echo no)"
check "slot to wipe is checked against token-bound slots" "yes" "$(grep -q 'is bound to a token' "$CODE" && echo yes || echo no)"
check "token check happens before the wipe" "yes" "$(before 'is bound to a token' 'luksKillSlot')"
check "crypttab rewrite before mkinitcpio"       "yes" "$(before 's|\${LUKS_KEY}|none|g' 'mkinitcpio -P')"
check "FILES=() before mkinitcpio"               "yes" "$(before 'FILES=()' 'mkinitcpio -P')"
check "mkinitcpio before the keyfile is removed" "yes" "$(before 'mkinitcpio -P' 'shred -u')"
check "initramfs checked for keyfile before removal" "yes" "$(before "lsinitcpio \"\$img\" | grep -q 'cmesh-luks.key'" 'shred -u')"
check "initramfs checked for crypttab before removal" "yes" "$(before "lsinitcpio \"\$img\" | grep -q 'etc/crypttab'" 'shred -u')"
check "keyfile removed before its keyslot is wiped" "yes" "$(before 'shred -u' 'luksKillSlot')"
check "mkinitcpio failure is fatal (no rm after)"  "yes" "$(grep -q 'mkinitcpio -P || die' "$CODE" && echo yes || echo no)"

echo
echo "(4) the keyslot wipe cannot take out the passphrase or the TPM"
check "slot comes from test-passphrase, not a constant" "yes" "$(grep -q 'Key slot' "$CODE" && echo yes || echo no)"
check "at least 3 keyslots required before a wipe" "yes" "$(grep -q '"\$n" -ge 3' "$CODE" && echo yes || echo no)"
check "luksKillSlot is batch (no interactive prompt)" "yes" "$(grep -q 'luksKillSlot -q' "$CODE" && echo yes || echo no)"
check "keyfile is overwritten, not just unlinked" "yes" "$(grep -q 'shred -u' "$CODE" && echo yes || echo no)"

echo
echo "(5) the no-TPM path leaves the machine bootable"
check "no TPM: keyfile left in place, with a warning" "yes" "$(grep -q 'NO TPM device found' "$CODE" && echo yes || echo no)"
check "marker written and unit disabled at the end" \
    "yes" "$([ "$(line_of 'date -Is > "\$MARKER"')" -gt "$(line_of 'luksKillSlot')" ] && echo yes || echo no)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

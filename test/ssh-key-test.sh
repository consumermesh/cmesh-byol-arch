#!/bin/bash
# Tests the config-drive parsers in build_archlinux/files/cmesh-byol-install.
#
# WHY THIS EXISTS
#
# The installer reads its LUKS passphrase and its SSH keys out of the cloud-config on the
# OVHcloud config drive, and that drive is scrubbed during the same run. Getting the parse
# wrong is therefore not a retryable mistake: a bad passphrase read aborts before anything
# is destroyed (the installer checks for it), but a bad SSH KEY read produces a finished,
# encrypted, network-reachable machine that nobody can log in to -- which is exactly what
# happened on the first successful install.
#
# The parser is extracted FROM the installer rather than duplicated, so it cannot drift
# from what ships. The extraction is marker-delimited because the installer's block has
# been through one layer of shell quote-mangling to embed an awk program that itself
# matches quote characters.
#
# Usage: test/ssh-key-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
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

# The parser is the awk program in the marked block. Restore it to the source the shell
# would pass to awk: the installer's "'"'"'" dance exists only to embed a single quote
# inside a single-quoted shell string, so undoing it is just replacing that 5-character
# sequence with one apostrophe.
sed -n '/CMESH-SSH-KEY-PARSER-BEGIN/,/CMESH-SSH-KEY-PARSER-END/p' "$INSTALLER" \
    | sed -n '/awk .*'"'"'$/,/^ *'"'"' "\$cd_mnt\/user-data")/p' \
    > "$WORK/parser-raw.txt"

if [ ! -s "$WORK/parser-raw.txt" ]; then
    echo "FATAL: could not extract the SSH key parser from $INSTALLER" >&2
    echo "       (did the CMESH-SSH-KEY-PARSER markers move or disappear?)" >&2
    exit 1
fi

# Strip the leading `awk '` and the trailing `' "$cd_mnt/user-data")`, then unescape.
sed -e "1s/.*awk '//" \
    -e '$s/'"'"' "\$cd_mnt\/user-data").*$//' \
    "$WORK/parser-raw.txt" | sed "s/'\"'\"'/'/g" > "$WORK/parser.awk"

if ! awk -f "$WORK/parser.awk" /dev/null >/dev/null 2>&1; then
    echo "FATAL: the extracted awk program does not run:" >&2
    cat "$WORK/parser.awk" >&2
    exit 1
fi
echo "extracted the SSH key parser from $(basename "$INSTALLER")"

# Run the parser over a user-data file and return the keys it found, one per line.
parse_keys() { awk -f "$WORK/parser.awk" "$1"; }

echo
echo "a canonical cloud-config"
cat > "$WORK/canonical.yaml" <<'EOF'
#cloud-config
cmesh_luks_passphrase: "hunter2hunter2"
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOne spfoos@localhost
EOF
check "finds the single key" \
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOne spfoos@localhost" \
    "$(parse_keys "$WORK/canonical.yaml")"

echo
echo "the shape actually used for this server (comments, then key, then nothing)"
cat > "$WORK/real.yaml" <<'EOF'
#cloud-config
# Passphrase for the LUKS2 volume that cmesh-byol-install creates on first boot.
# It becomes a keyslot on BOTH disks and is the only way in if the TPM is cleared.
# The config drive is scrubbed by the installer once the passphrase has been read.
cmesh_luks_passphrase: "9rJ2ATSDfcYX9ky3Wq5ed+ZOsdRGpWQ3WBj+XFyblNM="
EOF
check "no keys present -> empty output" "" "$(parse_keys "$WORK/real.yaml")"

echo
echo "several keys, mixed quoting, trailing whitespace"
cat > "$WORK/multi.yaml" <<'EOF'
#cloud-config
cmesh_luks_passphrase: "hunter2hunter2"
ssh_authorized_keys:
  - ssh-ed25519 AAAAKeyOne one@host
  - "ssh-rsa AAAAKeyTwo two@host"
  - 'ssh-ed25519 AAAAKeyThree three@host'
users:
  - name: somebody
EOF
check "finds all three, strips quotes, stops at dedent" \
    "ssh-ed25519 AAAAKeyOne one@host
ssh-rsa AAAAKeyTwo two@host
ssh-ed25519 AAAAKeyThree three@host" \
    "$(parse_keys "$WORK/multi.yaml")"

echo
echo "must not swallow list items belonging to a LATER key"
cat > "$WORK/later.yaml" <<'EOF'
#cloud-config
ssh_authorized_keys:
  - ssh-ed25519 AAAAKeyOne one@host
packages:
  - vim
  - tree
runcmd:
  - echo hello
EOF
check "only the key, not packages/runcmd entries" \
    "ssh-ed25519 AAAAKeyOne one@host" \
    "$(parse_keys "$WORK/later.yaml")"

echo
echo "keys listed before other keys in the document"
cat > "$WORK/interleaved.yaml" <<'EOF'
#cloud-config
ssh_authorized_keys:
  - ssh-ed25519 AAAAKeyOne one@host
cmesh_luks_passphrase: "hunter2hunter2"
disable_root: false
EOF
check "stops at the non-list line" \
    "ssh-ed25519 AAAAKeyOne one@host" \
    "$(parse_keys "$WORK/interleaved.yaml")"

echo
echo "no ssh_authorized_keys key at all"
printf '#cloud-config\ncmesh_luks_passphrase: "hunter2hunter2"\n' > "$WORK/none.yaml"
check "empty output" "" "$(parse_keys "$WORK/none.yaml")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

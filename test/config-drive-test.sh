#!/bin/bash
# Tests where the installer looks for user data on the config drive.
#
# WHY THIS EXISTS
#
# The first deployment with the payload layout got through the deploy hook, booted, found
# the config drive, mounted it, and then died with "no cmesh_luks_passphrase found". The
# passphrase was there. The drive is an OpenStack-format config drive (iso9660,
# LABEL=config-2) and keeps its user data at openstack/latest/user_data; the installer
# only looked at /user-data, the NoCloud layout. One wrong path cost a 40-minute deploy.
#
# The lookup is extracted FROM the installer rather than duplicated, so it cannot drift.
#
# Usage: test/config-drive-test.sh
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

sed -n '/CMESH-CONFIG-DRIVE-PATH-BEGIN/,/CMESH-CONFIG-DRIVE-PATH-END/p' "$INSTALLER" > "$WORK/fn.sh"
if ! grep -q '^config_drive_user_data()' "$WORK/fn.sh"; then
    echo "FATAL: could not extract config_drive_user_data from $INSTALLER" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$WORK/fn.sh"

drive() { # drive <name> <file>... -> creates the files, prints the mountpoint
    local m="$WORK/$1" f; shift
    mkdir -p "$m"
    for f in "$@"; do mkdir -p "$m/$(dirname "$f")"; echo "#cloud-config" > "$m/$f"; done
    printf '%s' "$m"
}
rel() { # strip the mountpoint prefix from the function's answer
    local m="$1" out
    out=$(config_drive_user_data "$m") || { echo "NONE"; return; }
    echo "${out#"$m"}"
}

echo "the OpenStack layout OVHcloud actually writes (iso9660, LABEL=config-2)"
m=$(drive openstack openstack/latest/user_data openstack/latest/meta_data.json openstack/2018-08-27/user_data)
check "openstack/latest/user_data is found" "/openstack/latest/user_data" "$(rel "$m")"

echo
echo "the NoCloud layout (vfat, LABEL=cidata)"
m=$(drive nocloud user-data meta-data)
check "/user-data is found" "/user-data" "$(rel "$m")"

echo
echo "precedence and fallbacks"
m=$(drive both user-data openstack/latest/user_data)
check "NoCloud wins when both exist" "/user-data" "$(rel "$m")"
m=$(drive dated openstack/2012-08-10/user_data openstack/2018-08-27/user_data openstack/2017-02-22/user_data)
check "no 'latest': newest dated version is used" "/openstack/2018-08-27/user_data" "$(rel "$m")"
m=$(drive ec2 ec2/latest/user-data)
check "ec2 layout is accepted" "/ec2/latest/user-data" "$(rel "$m")"

echo
echo "nothing usable"
m=$(drive meta_only openstack/latest/meta_data.json)
check "metadata without user data: not found" "NONE" "$(rel "$m")"
mkdir -p "$WORK/empty"
check "empty drive: not found" "NONE" "$(rel "$WORK/empty")"
check "function returns non-zero when nothing is found" "1" "$(config_drive_user_data "$WORK/empty" >/dev/null; echo $?)"

echo
echo "the installer uses the lookup, not a hardcoded path"
# grep -c, not grep -q: under pipefail a -q that exits on its first match can SIGPIPE awk
# and turn a hit into a "no".
check "read_passphrase calls config_drive_user_data" \
    "1" "$(awk '/^read_passphrase\(\)/,/^}/' "$INSTALLER" | grep -c 'config_drive_user_data "\$cd_mnt"')"
check "no remaining hardcoded \$cd_mnt/user-data" \
    "0" "$(grep -v '^[[:space:]]*#' "$INSTALLER" | grep -c '\$cd_mnt/user-data')"
check "a miss lists what the drive contained" \
    "yes" "$(grep -q 'config drives seen' "$INSTALLER" && echo yes || echo no)"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

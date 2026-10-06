#!/bin/bash
# Guards the ordering directives in build_archlinux/files/cmesh-byol-install.service.
#
# WHY THIS EXISTS
#
# The unit has now carried two DIFFERENT ordering defects, and both had the same
# signature: the installer never ran, produced no output anywhere, and the machine spent
# a full deploy cycle looking fine.
#
#   1. `DefaultDependencies=no`, `After=sysinit.target local-fs.target` AND
#      `Before=network-pre.target`, while being `WantedBy=multi-user.target`.
#      network-pre.target is ordered before multi-user.target, so the unit had to run
#      before a target that runs before it. systemd drops a job in a cycle, silently.
#
#   2. `After=cloud-init.target`, on the belief that cloud-init mounts the config drive.
#      It does not -- cmesh-byol-install mounts it by label itself -- but cloud-init
#      stalled with its final stage unfinished, so cloud-init.target was never reached
#      and the installer waited forever.
#
# Neither is visible by reading the installer script, and neither produces an error. So
# they are checked here instead: the ordering must stay minimal, and it must never again
# name a target that is not structurally always reached.
#
# Usage: test/unit-ordering-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
UNIT="$REPO/build_archlinux/files/cmesh-byol-install.service"

if [ ! -f "$UNIT" ]; then
    echo "FATAL: $UNIT not found" >&2
    exit 1
fi

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

# Directives only: comments in this file discuss cloud-init at length, deliberately, and
# must not be mistaken for configuration.
directives() { grep -E '^[[:space:]]*(After|Before|Wants|Requires|WantedBy|DefaultDependencies)=' "$UNIT"; }

echo "ordering directives under test:"
directives | sed 's/^/    /'
echo

check "no ordering against cloud-init (the defect that stalled it)" \
    "0" "$(directives | grep -c 'cloud-init' || true)"
check "no Before=network-pre.target (the cycle defect)" \
    "0" "$(directives | grep -c 'network-pre' || true)"
check "DefaultDependencies is not disabled" \
    "0" "$(directives | grep -c '^DefaultDependencies=no' || true)"
check "After= is exactly local-fs.target" \
    "After=local-fs.target" "$(grep -E '^After=' "$UNIT")"
check "still pulled in by multi-user.target" \
    "WantedBy=multi-user.target" "$(grep -E '^WantedBy=' "$UNIT")"

echo
echo "the completion guard must survive (an interrupted install has to be re-runnable)"
check "ConditionPathExists present" \
    "1" "$(grep -c '^ConditionPathExists=!/var/lib/cmesh-byol/installed' "$UNIT")"

echo
echo "the installer must still be able to read the config drive without cloud-init:"
INSTALLER="$REPO/build_archlinux/files/cmesh-byol-install"
check "mounts the config drive by label itself" \
    "yes" "$(grep -q 'LABEL=cidata' "$INSTALLER" && echo yes || echo no)"
check "waits for it with a timeout rather than a dependency" \
    "1" "$(grep -c '^wait_for_config_drive()' "$INSTALLER")"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

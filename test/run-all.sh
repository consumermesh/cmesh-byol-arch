#!/bin/bash
# Runs every test suite in test/. This is what CI calls, so a local run and a CI run are
# the same thing.
#
# These suites exist because the deploy hook, the installer service unit, and the
# config-drive parsers have all failed in ways that produced NO output on the machine:
# OVHcloud reports only "the script did not end properly", and a systemd job that never
# starts says nothing at all. Every defect so far has been found by a human reading a disk
# from rescue mode, which costs an image upload and a reinstall per attempt.
#
# The point of this file is to make that feedback loop seconds instead of an hour.
#
# Usage: test/run-all.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0
RAN=0

for suite in "$HERE"/*.sh; do
    name="$(basename "$suite")"
    [ "$name" = "run-all.sh" ] && continue
    [ "$name" = "rescue-probe.sh" ] && continue   # runs on a server, not here
    RAN=$((RAN + 1))
    printf '\n############ %s ############\n' "$name"
    if bash "$suite"; then
        printf '>>>> %s: PASS\n' "$name"
    else
        printf '>>>> %s: FAIL\n' "$name"
        FAILED=$((FAILED + 1))
    fi
done

printf '\n========================================\n'
if [ "$FAILED" -eq 0 ]; then
    printf 'all %d suites passed\n' "$RAN"
else
    printf '%d of %d suites FAILED\n' "$FAILED" "$RAN"
fi
[ "$FAILED" -eq 0 ]

#!/bin/bash
# Build the BYOL image, using KVM when this machine actually allows it.
#
# Run this from the repository root (or anywhere — it cd's to the repo root itself).
#
# WHY THIS EXISTS RATHER THAN A BARE `packer build`:
#
#   * /dev/kvm ships as crw-rw---- root:kvm on most distributions, including GitHub's
#     hosted runners. A user outside the kvm group gets
#       "Could not access KVM kernel module: Permission denied"
#     and QEMU dies. `usermod -aG kvm` cannot fix an already-running session, so this
#     re-executes itself through `sg kvm` when that is what it takes.
#
#   * Probing /dev/kvm by reading it is a FALSE NEGATIVE — it is an ioctl-only device,
#     so a read fails regardless of permission. The only trustworthy test is to start
#     QEMU under -accel kvm and see whether it survives.
#
#   * Packer resolves provisioner paths relative to the WORKING DIRECTORY, not to the
#     HCL file, so the build must run from the repository root.
#
# Requires: packer, qemu-system-x86, qemu-utils, genisoimage.
set -euo pipefail

# --- re-exec under the kvm group if necessary and possible -------------------------
#
# Depend on `sg` successfully ENTERING the group, rather than on predicting whether it
# can. A gate that guesses and a probe that tests can disagree — and when they did, the
# build silently ran without KVM while the probe said KVM was available. `sg` prints the
# resulting group list, so confirm the group before trusting the re-entry.
in_group() { id -Gn | tr ' ' '\n' | grep -qx kvm; }

if [ -e /dev/kvm ] && ! in_group && command -v sg >/dev/null 2>&1; then
    echo ">>> not in the kvm group; re-executing via sg kvm"
    if sg kvm -c 'id -Gn | tr " " "\n" | grep -qx kvm'; then
        exec sg kvm -c "$(printf '%q ' "$0" "${@:-}")"
    fi
    echo ">>> sg kvm did not grant the group — continuing without it" >&2
fi

cd "$(dirname "${BASH_SOURCE[0]}")"

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found in PATH" >&2; exit 1; }; }
for t in packer qemu-system-x86_64 genisoimage sha512sum; do need "$t"; done

# --- decide the accelerator by actually starting QEMU ------------------------------
accel=tcg
if [ -e /dev/kvm ]; then
    # `|| true`: a non-zero exit here is the SUCCESS case (timeout kills qemu), and
    # would otherwise trip set -e.
    probe_out="$(timeout 8 qemu-system-x86_64 -accel kvm -machine pc -m 128 \
        -display none -monitor none -serial none -no-reboot 2>&1 || true)"
    if grep -qiE 'permission denied|failed to (initialize|open) kvm|could not access kvm' \
        <<<"$probe_out"; then
        echo ">>> KVM present but not usable: ${probe_out:-no output}" >&2
        echo ">>> active groups: $(id -Gn)" >&2
    else
        accel=kvm
        echo ">>> KVM probe: qemu started under -accel kvm (killed by timeout, as expected)"
    fi
else
    echo ">>> /dev/kvm absent" >&2
fi

if [ "$accel" = tcg ]; then
    cat >&2 <<'EOF'
>>> WARNING: building under tcg (software emulation).
>>> This works anywhere but is very slow — expect hours rather than ~15 minutes.
>>> For a fast build, run this on a machine with usable KVM, ideally the target
>>> server itself.
EOF
fi
echo ">>> accelerator: ${accel}"

if [ -n "${GITHUB_ENV:-}" ]; then echo "ACCELERATOR=${accel}" >> "$GITHUB_ENV"; fi

# --- build ------------------------------------------------------------------------
packer init build_archlinux/archlinux.pkr.hcl
packer build -var "accelerator=${accel}" build_archlinux/archlinux.pkr.hcl

img=build_archlinux/output/archlinux.qcow2
[ -f "$img" ] || { echo "FATAL: ${img} was not produced" >&2; exit 1; }

sum=$(sha512sum "$img" | awk '{print $1}')
echo
echo "=== image built ==="
ls -lh "$img"
echo
echo "  path:          $(readlink -f "$img")"
echo "  size:          $(stat -c %s "$img") bytes"
echo "  imageCheckSum: ${sum}"
echo "  type:          sha512"
echo
echo "Point the OVHcloud console at this file, or upload it somewhere reachable and use"
echo "that URL. It is the .qcow2 itself, not the sha512 file."

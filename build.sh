#!/bin/bash
# Build the BYOL image on a machine with real KVM — fastest on the target server itself.
#
# The image is only needed to install a server, so building it ON that server is the
# shortest path: KVM is available, no upload is required, and you get the checksum
# printed for the imageCheckSum field.
#
# Requires: packer, qemu-system-x86, qemu-utils, genisoimage, /dev/kvm openable.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

need() { command -v "$1" >/dev/null 2>&1 || { echo "FATAL: '$1' not found in PATH" >&2; exit 1; }; }
for t in packer qemu-system-x86_64 genisoimage sha512sum; do need "$t"; done

# KVM availability decides whether this takes ~15 minutes or several hours.
accel=tcg
if [ -e /dev/kvm ] && dd if=/dev/kvm of=/dev/null bs=1 count=1 status=none 2>/dev/null; then
    accel=kvm
else
    echo "WARNING: /dev/kvm is missing or not openable — falling back to tcg." >&2
    echo "         Software emulation works but is very slow (hours, not minutes)." >&2
fi
echo ">>> accelerator: ${accel}"

packer init build_archlinux/archlinux.pkr.hcl
packer build -var accelerator="$accel" build_archlinux/archlinux.pkr.hcl

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

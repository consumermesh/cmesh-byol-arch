#!/bin/bash
# Build the BYOL image inside a throwaway Arch container.
#
# WHY A CONTAINER: the build needs packer, qemu and genisoimage, and you should not have
# to install those on the machine you are building for. The container is disposable and
# the only things bind-mounted are the repository (read-only) and the output directory.
#
# RUN THIS ON THE HOST, not inside another container. It needs:
#   * podman or docker
#   * /dev/kvm, passed through with --device, or the build falls back to tcg
#   * a few GB free in ./build_archlinux/output
#
#   ./build-in-container.sh
#   RUNTIME=docker ./build-in-container.sh
#   CPUS=8 MEMORY=8g ./build-in-container.sh
#
# KVM NOTE: passing /dev/kvm in is the entire reason to prefer this over CI. Without it
# the build still works but runs under software emulation, which is slower — usable, but
# pointless if the host has KVM available.
set -euo pipefail

RUNTIME="${RUNTIME:-}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-4g}"
IMAGE="${IMAGE:-docker.io/archlinux:latest}"

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_DIR="$PWD"

# --- pick a runtime -----------------------------------------------------------------
if [ -z "$RUNTIME" ]; then
    for candidate in podman docker; do
        if command -v "$candidate" >/dev/null 2>&1; then RUNTIME="$candidate"; break; fi
    done
fi
[ -n "$RUNTIME" ] || { echo "FATAL: neither podman nor docker found in PATH" >&2; exit 1; }
echo ">>> runtime: $RUNTIME"

# --- KVM passthrough ----------------------------------------------------------------
DEVICES=()
if [ -e /dev/kvm ]; then
    DEVICES=(--device /dev/kvm)
    echo ">>> /dev/kvm passed through — build will use hardware acceleration"
else
    echo ">>> WARNING: no /dev/kvm on this host; the build will use tcg (slower)" >&2
fi

mkdir -p build_archlinux/output

# --- build --------------------------------------------------------------------------
# The Arch container has no packer, so install it plus qemu. Everything else the build
# needs (bash, coreutils, tar, gzip) is in the base image.
#
# The repo is mounted read-only at /src and copied inside the container, so the build
# cannot modify your working tree. Output is written to /out, which IS the host's
# build_archlinux/output.
#
# NOTE: /work is NOT passed to --workdir. The container creates it below, and a
# --workdir naming a path that does not exist yet fails before the script runs at all:
#   Error: workdir "/work" does not exist on container <id>
# /tmp always exists, so start there and cd once the copy exists.
"$RUNTIME" run --rm -i \
    "${DEVICES[@]}" \
    --cpus "$CPUS" \
    --memory "$MEMORY" \
    -v "$REPO_DIR:/src:ro" \
    -v "$REPO_DIR/build_archlinux/output:/out" \
    -w /tmp \
    "$IMAGE" \
    bash -euo pipefail -c '
        echo ">>> inside container: $(cat /etc/arch-release 2>/dev/null || echo arch)"
        pacman -Sy --noconfirm --needed \
            packer qemu-system-x86 qemu-img cdrtools libisoburn >/dev/null

        for t in packer qemu-system-x86_64 genisoimage sha512sum; do
            command -v "$t" >/dev/null || { echo "FATAL: $t missing in container" >&2; exit 1; }
        done

        # Work on a copy so a read-only mount is not a constraint and a failed build
        # leaves no partial state in the repository.
        mkdir -p /work
        cp -a /src/. /work/
        cd /work

        # build.sh probes KVM itself and falls back to tcg, so pass no accelerator hint.
        ./build.sh

        cp -v build_archlinux/output/archlinux.qcow2 /out/
        cp -v build_archlinux/output/archlinux.qcow2.sha512 /out/ 2>/dev/null || true
    '

# build.sh writes the checksum files alongside the image inside the container; make sure
# the host copy has them even if the in-container copy step was skipped.
img="$REPO_DIR/build_archlinux/output/archlinux.qcow2"
[ -f "$img" ] || { echo "FATAL: $img was not produced" >&2; exit 1; }
sum=$(sha512sum "$img" | awk '{print $1}')
printf '%s\n' "$sum" > "$img.sha512"
echo
echo "=== image built ==="
ls -lh "$img"
echo
echo "  path:          $img"
echo "  imageCheckSum: $sum"
echo "  type:          sha512"

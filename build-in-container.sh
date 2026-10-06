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
#   IMAGE=docker.io/archlinux:base-devel ./build-in-container.sh
#
# No CPU or memory limits are applied to the container: under rootless podman the
# cgroup controllers are not delegated and --memory fails during container init. The
# build VM's own size is set in the Packer HCL (-m 2048M), which is what matters.
#
# KVM NOTE: passing /dev/kvm in is the entire reason to prefer this over CI. Without it
# the build still works but runs under software emulation, which is slower — usable, but
# pointless if the host has KVM available.
set -euo pipefail

RUNTIME="${RUNTIME:-}"
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
# NOTE: --workdir is deliberately NOT used at all. Every value tried fails with
#   Error: workdir "<path>" does not exist on container <id>
# including /tmp, which exists in every image — so the validation is not seeing the
# container's filesystem the way one would expect. The shell does its own mkdir/cd
# below, which removes the dependency entirely.
#
# NOTE: --memory and --cpus are also deliberately absent. Under ROOTLESS podman the
# cgroup controllers are not delegated to the user slice, so --memory fails during
# container init before anything runs:
#   error setting cgroup config for procHooks process: openat2
#   .../memory.swap.max: no such file or directory
# Neither flag changes the image that gets built, and QEMU's own -m (2048M, set in the
# HCL) is what actually bounds the build VM. Dropping them costs nothing and removes a
# whole class of rootless failure.
#
# --security-opt label=disable: with SELinux enforcing, the bind mounts need relabelling
# or the container cannot read /src.
"$RUNTIME" run --rm -i \
    "${DEVICES[@]}" \
    --security-opt label=disable \
    -v "$REPO_DIR:/src:ro" \
    -v "$REPO_DIR/build_archlinux/output:/out" \
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

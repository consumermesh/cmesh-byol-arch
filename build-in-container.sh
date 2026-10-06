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
# base-devel, NOT :latest. The minimal archlinux image ships no bash at all, and
# build.sh needs it (here-strings, ${BASH_SOURCE[0]}), so :latest fails with:
#   exec: "bash": executable file not found in $PATH
# base-devel also carries make/gcc, which the build wants regardless.
IMAGE="${IMAGE:-docker.io/archlinux:base-devel}"

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

# Packer refuses to build when its output directory already exists, so a second run
# fails until it is removed by hand:
#   Error: output directory 'output' already exists. Please remove it or change
#          output_directory
# That is easy to hit, because a previous run is exactly when you most want to re-run.
#
# Existing artifacts are preserved by moving them aside rather than deleted — the image
# from a good build is the thing you were trying to obtain, and a build is only ~90
# seconds, so there is no reason to risk losing a usable artifact to save disk.
# The REAL output directory is <repo>/output, not build_archlinux/output:
# output_directory is resolved against the working directory, and packer runs from the
# repository root. Both are tidied so a re-run works whichever one is present.
for dir in output build_archlinux/output; do
    [ -d "$dir" ] || continue
    if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        keep="${dir%/}.prev.$(date +%Y%m%dT%H%M%S)"
        echo ">>> $dir is not empty; moving it to $keep"
        mv "$dir" "$keep"
    else
        rmdir "$dir"
    fi
done

# Do NOT recreate either directory here.
#
# Packer refuses on the EXISTENCE of the output directory, not on it being non-empty:
#   Error: output directory 'output' already exists. Please remove it or change
#          output_directory
# so leaving an empty one behind (which an earlier version of this script did with
# `mkdir -p`) reproduces the same failure the move-aside above exists to prevent. Packer
# creates it itself. The container's nested `mkdir -p build_archlinux/output` was removed
# for the same reason.
for dir in output build_archlinux/output; do
    if [ -d "$dir" ]; then
        echo "FATAL: $dir still exists; packer will refuse to build." >&2
        ls -la "$dir" >&2
        exit 1
    fi
done

# --- build --------------------------------------------------------------------------
# The Arch container has no packer, so install it plus qemu. Everything else the build
# needs (bash, coreutils, tar, gzip) is in the base image.
#
# The repo is mounted read-only at /src and copied inside the container, so the build
# cannot modify your working tree. The host's build_archlinux/output is bind-mounted at
# the exact path packer writes to, so the finished image lands on the host directly.
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
    -v "$REPO_DIR:/src" \
    "$IMAGE" \
    bash -euo pipefail -c '
        # Guard the image choice explicitly: the minimal archlinux image has no bash,
        # and its absence surfaces as an opaque runc error before anything runs
        #   exec: "bash": executable file not found in $PATH
        # so report it here instead. This line is only reached because bash exists.
        echo ">>> inside container: $(cat /etc/arch-release 2>/dev/null || echo arch)"
        command -v pacman >/dev/null || { echo "FATAL: not an Arch image (no pacman)" >&2; exit 1; }

        pacman -Sy --noconfirm --needed \
            packer qemu-system-x86 qemu-img cdrtools libisoburn >/dev/null

        for t in packer qemu-system-x86_64 genisoimage sha512sum; do
            command -v "$t" >/dev/null || { echo "FATAL: $t missing in container" >&2; exit 1; }
        done

        # Run straight out of the mount. Nothing is copied: the HCL is read and
        # provision.sh is read, and the only place packer writes is build_archlinux/.
        #
        # WHERE PACKER WRITES: packer reports "VM files in directory: output", and
        # output_directory is resolved relative to the HCL FILE, not the working
        # directory. The HCL is /src/build_archlinux/archlinux.pkr.hcl, so the target is
        # /src/build_archlinux/output — the host directory itself, through the mount.
        #
        # WHY THE REPO IS MOUNTED READ-WRITE: it is not because packer needs to modify
        # the repository. It is because a nested bind mount does not escape a read-only
        # parent here, and SELinux labels make the narrow mounts fail outright. Verified
        # on the host with this exact script:
        #   -v repo:/src:ro -v repo/build_archlinux:/src/build_archlinux
        #     -> mkdir output: read-only file system
        #   -v repo:/src
        #     -> touch succeeded
        # The build therefore writes only inside build_archlinux/output (plus the packer
        # lock file), but it *could* write elsewhere, so this is a deliberate trade for a
        # working build rather than a claim of isolation. `git status` afterwards shows
        # anything unexpected.
        cd /src

        # HOME must be writable and OUTSIDE the mounted tree: packer keeps its plugin
        # cache under $HOME/.config/packer. /tmp is writable in the container.
        export HOME=/tmp

        test -w build_archlinux \
            || { echo "FATAL: build_archlinux is not writable; check the bind mount" >&2; exit 1; }

        # build.sh probes KVM itself and falls back to tcg, so pass no accelerator hint.
        ./build.sh
    '

# Locate the artifact packer produced rather than assuming its path.
#
# RESOLVED: output_directory is resolved against the WORKING DIRECTORY, not the HCL file.
# packer is invoked from the repository root, so `output_directory = "output"` writes to
# <repo>/output/ — confirmed on disk as ~/src/cmesh-byol-arch/output/archlinux.qcow2,
# while both this script and build.sh looked in build_archlinux/output/ and reported
# "not produced" for an image that had built fine. Search for it; do not name it.
#
# The guard above now tidies <repo>/output too, since that is the real location.
img=""

for candidate in "$REPO_DIR/output/archlinux.qcow2" \
                 "$REPO_DIR/build_archlinux/output/archlinux.qcow2"; do
    if [ -f "$candidate" ]; then img="$candidate"; break; fi
done
if [ -z "$img" ]; then
    img="$(find "$REPO_DIR" -maxdepth 3 -name '*.qcow2' -type f \
           -not -path '*/output.prev.*' -not -path '*/packer_cache/*' \
           2>/dev/null | head -1)"
fi

if [ -z "$img" ] || [ ! -f "$img" ]; then
    echo "FATAL: no .qcow2 found under $REPO_DIR" >&2
    echo "--- what packer actually produced ---" >&2
    find "$REPO_DIR" -maxdepth 3 -name '*.qcow2' 2>/dev/null | head -20 >&2
    ls -la "$REPO_DIR/output" "$REPO_DIR/build_archlinux/output" 2>/dev/null >&2
    exit 1
fi

sum=$(sha512sum "$img" | awk '{print $1}')
printf '%s\n' "$sum" > "$img.sha512"
echo
echo "=== image built ==="
ls -lh "$img"
echo
echo "  path:          $img"
echo "  imageCheckSum: $sum"
echo "  type:          sha512"

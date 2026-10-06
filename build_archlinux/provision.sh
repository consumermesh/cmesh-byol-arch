#!/bin/bash
# Build-time provisioning, run INSIDE the throwaway QEMU VM by Packer.
#
# Prepares a BYOL-compatible Arch image whose first boot on real hardware performs the
# encrypted install. Modelled on ovh/bringyourownlinux build_archlinux/provision.sh;
# the differences are called out inline.
set -euo pipefail

echo ">>> cmesh-byol-arch provisioning starting"

### Phase 1: Install the tools the first-boot installer needs ###

pacman -Syu --noconfirm

# cryptsetup + mdadm are the whole point; systemd-cryptenroll ships with systemd and is
# what enrols the TPM on first boot. dosfstools/gptfdisk for the ESP and partition
# tables, rsync for the rootfs copy, zstd for the in-RAM tarball, e2fsprogs for
# mkfs.ext4 and resize2fs.
#
# Deliberately NOT installed: zfs-utils/zfs-dkms. See README "Why not ZFS" — ZFS is not
# in Arch's official repos, pins the kernel, and its initramfs hook is incompatible with
# the systemd hook used here.
pacman -S --noconfirm --needed \
    cryptsetup \
    mdadm \
    dosfstools \
    gptfdisk \
    e2fsprogs \
    rsync \
    zstd \
    lvm2 \
    parted \
    linux-firmware-intel \
    intel-ucode \
    amd-ucode

# Fail the build early if any tool the installer shells out to is missing, rather than
# discovering it on a customer's server with the disks already wiped.
for tool in cryptsetup mdadm sgdisk mkfs.ext4 mkfs.vfat rsync tar zstd \
            systemd-cryptenroll grub-install grub-mkconfig mkinitcpio blkid findmnt \
            mkswap fallocate chattr; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FATAL: required tool '$tool' is missing from the image" >&2
        exit 1
    fi
done
echo ">>> all required tools present"

# The installer writes the TARGET's mkinitcpio.conf using the systemd, mdadm_udev and
# sd-encrypt hooks. sd-encrypt is what understands crypttab in the initramfs and a TPM2
# keyslot; mdadm_udev assembles the arrays after the dm-crypt mappings appear. If either
# moves, the INSTALLED system will not boot — far too late to discover.
for hook in systemd sd-encrypt mdadm_udev filesystems; do
    if [ ! -e "/usr/lib/initcpio/install/$hook" ]; then
        echo "FATAL: mkinitcpio hook '$hook' is missing; the installed system would not boot" >&2
        exit 1
    fi
done
echo ">>> required mkinitcpio hooks present"

### Phase 2: Network and console ###

# Remove the cloud image's static network configuration so cloud-init manages
# networking at first boot (the installer needs no network, but the installed
# system does).
rm -f /etc/systemd/network/*.network

# nomodeset: KVM display on some boards. Text mode for compatibility.
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="nomodeset iommu=pt"/' /etc/default/grub
sed -i 's/GRUB_GFXPAYLOAD_LINUX=.*/GRUB_GFXPAYLOAD_LINUX="text"/' /etc/default/grub

# Initramfs hooks for the BOOTSTRAP system. This is the image that runs before the
# install, so it only needs to reach its own root partition — the encrypted system's
# initramfs is generated later, inside the chroot, by files/cmesh-byol-install.
#
# No "net" hook: it targets the busybox init and conflicts with the systemd hook.
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard keymap sd-vconsole block filesystems fsck)/' /etc/mkinitcpio.conf

### Phase 3: Collapse to a single partition (BYOL contract) ###

# BYOL requires the image to contain EXACTLY ONE partition, formatted ext4/XFS/BTRFS.
# Merge the ESP into the root filesystem and delete the extra partitions. The target's
# real ESP is recreated by our installer at first boot, which also installs GRUB to it.
root_disk="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)")"
efi_dev="$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)"
if [ -n "$efi_dev" ]; then
    echo ">>> merging /boot/efi ($efi_dev) into the root filesystem"
    # Trailing digits of the device name are the partition number.
    efi_partnum="${efi_dev##*[!0-9]}"
    rsync -aSH /boot/efi/ /boot_efi.new/
    umount /boot/efi
    blkdiscard "$efi_dev" || true
    rsync -aSH /boot_efi.new/ /boot/efi/
    rm -rf /boot_efi.new
    parted "/dev/$root_disk" -s "rm $efi_partnum"
fi

# Remove any bios_grub stub partition (GPT type 21686148-...).
lsblk -nro NAME,PARTTYPE "/dev/$root_disk" | while read -r part parttype; do
    if [ "$parttype" = "21686148-6449-6e6f-744e-656564454649" ]; then
        echo ">>> removing bios_grub stub partition /dev/$part"
        blkdiscard "/dev/$part" || true
        parted "/dev/$root_disk" -s "rm ${part##*[!0-9]}"
    fi
done

### Phase 4: Install the first-boot installer ###

# Locate the files the `file` provisioner delivered.
#
# This deliberately accepts EITHER layout rather than asserting one, because the
# destination semantics have cost two build cycles already and guessing between them is
# what caused it. Observed in practice:
#
#   destination = "/tmp"                 -> files loose in /tmp        (v6 log)
#   destination = "/tmp/cmesh-byol-files" -> "Not a directory" on install (v5 log)
#
# The shell provisioner's own script appears as /tmp/script_<pid>.sh, so packer does
# append a basename to the destination directory; why the second form failed is not
# established. Rather than keep theorising, find them and say which was found.
FILES_SRC=""
for candidate in /tmp/cmesh-byol-files /tmp; do
    if [ -f "$candidate/cmesh-byol-install" ] && [ -f "$candidate/cmesh-byol-finalize" ]; then
        FILES_SRC="$candidate"
        break
    fi
done

if [ -z "$FILES_SRC" ]; then
    echo "FATAL: could not find the delivered installer files in /tmp/cmesh-byol-files or /tmp" >&2
    echo "--- /tmp ---" >&2
    ls -la /tmp >&2
    [ -d /tmp/cmesh-byol-files ] && { echo "--- /tmp/cmesh-byol-files ---" >&2; ls -la /tmp/cmesh-byol-files >&2; }
    exit 1
fi
echo ">>> installer files found in ${FILES_SRC}"

for f in cmesh-byol-install cmesh-byol-finalize cmesh-byol-install.service cmesh-byol-finalize.service; do
    [ -f "$FILES_SRC/$f" ] \
        || { echo "FATAL: ${FILES_SRC}/$f was not delivered" >&2; ls -la "$FILES_SRC" >&2; exit 1; }
done

install -Dm755 "$FILES_SRC/cmesh-byol-install" /usr/local/sbin/cmesh-byol-install
install -Dm755 "$FILES_SRC/cmesh-byol-finalize" /usr/local/sbin/cmesh-byol-finalize

install -Dm644 "$FILES_SRC/cmesh-byol-install.service" \
    /etc/systemd/system/cmesh-byol-install.service
install -Dm644 "$FILES_SRC/cmesh-byol-finalize.service" \
    /etc/systemd/system/cmesh-byol-finalize.service

# The installer runs on the first boot of the deployed system. It is NOT enabled here:
# enabling it would make the build VM try to install over its own disks.
ln -sf /etc/systemd/system/cmesh-byol-install.service \
    /etc/systemd/system/multi-user.target.wants/cmesh-byol-install.service

### Phase 4b: OVH's deploy-time hook — and the bootloader ###

# /root/.ovh/make_image_bootable.sh is REQUIRED BY CONTRACT. OVH aborts the deployment
# before it starts without it:
#   The '/root/.ovh/make_image_bootable.sh' file does not exist.
#
# It is also the only place a bootloader can be installed. OVHcloud runs this hook AFTER
# it has partitioned the disks, rsynced the image into them and FORMATTED THE ESP, so
# nothing the build leaves on the ESP survives, and the machine cannot boot far enough to
# run cmesh-byol-install until a loader exists. A no-op stub here is an unbootable server.
#
# The hook is exercised outside the image (see the hook test harness in the repo) because
# its failure modes are silent: OVHcloud reports only "the script did not end properly",
# with no output from the script at all. Read the hook's own log first when a deployment
# does not boot -- it is written to the deployed root and survives the reboot:
#
#   mount /dev/nvme0n1p2 /mnt && cat /mnt/var/log/ovh-make-bootable.log
#
# The hook deliberately does NOT touch the partition layout: it runs before the first
# reboot, while the layout OVH just created is still the one cmesh-byol-install replaces.
install -d -m 0755 /root/.ovh
cat > /root/.ovh/make_image_bootable.sh <<'HOOK'
#!/bin/bash
# Makes the deployed system bootable, so it can reach its first boot where
# /usr/local/sbin/cmesh-byol-install rewrites both disks as LUKS2 under RAID1.
#
# Runs chrooted by the OVHcloud deployer after the image has been written, and the ESP
# has been formatted. See:
#   https://github.com/ovh/bringyourownlinux#mib
#
# WHAT THIS MUST DO
#
# Exactly one thing is load-bearing: put a bootloader on the ESP. OVHcloud formats the
# ESP while writing the image, so nothing the build left there survives, and the machine
# cannot boot far enough to run cmesh-byol-install until a loader exists. The ESP is
# therefore the only thing this script has to get right.
#
# WHAT IT MUST NOT DO
#
# Fail the deployment over anything else. An earlier revision of this hook rebuilt the
# initramfs and treated three "should never happen" assertions as fatal. One of them
# fired, the deployer aborted at step 14/17, and the only diagnostic OVHcloud reported
# was "the script did not end properly" -- no line number, no message, nothing. Both the
# disk layout and the bootloader state were then unrecoverable without a rescue boot,
# and the ESP had already been formatted, so the machine could not boot either way.
#
# The assertions were not wrong; making them fatal was. The initramfs is regenerated
# twice more before it matters (by this hook's successor on first boot, and again by
# cmesh-byol-install on the target), so failing a deployment over it buys nothing and
# costs a full upload. Every step below is therefore best-effort and LOGGED, and this
# script exits 0 unless it cannot write a bootloader at all.
#
# THE LOG IS THE PRODUCT
#
# Because the deployer discards this script's output, the log is the only way to see
# what happened. It is written to the DEPLOYED ROOT (not the ESP, 512 MiB and formatted
# again by cmesh-byol-install) and survives the reboot, so it can be read from rescue
# mode:
#
#   mount /dev/nvme0n1p2 /mnt && cat /mnt/var/log/ovh-make-bootable.log
#
# Read it FIRST when a deployment does not boot. It records the disk layout as the
# deployer left it, the mount table, and the exit status of every step.
set -uo pipefail

STATUS_LOG=""
EEXIT=0

# Capture stdout AND stderr for the whole script. OVHcloud reports neither, so anything
# not written here is lost.
#
# The log path is chosen by WRITING A TEST BYTE, not by trying the redirection and
# checking its status: `exec > >(tee -a "$f")` always returns 0, whatever happens to
# $f, because process substitution succeeds as soon as the pipe is created. Verifying
# it that way selects a path that cannot be written and then loses every line to a tee
# that dies asynchronously -- silently, which is the exact failure this log exists to
# prevent.
log_path() {
    local dir
    for dir in "$@"; do
        mkdir -p "$dir" 2>/dev/null || true
        if { : > "$dir/ovh-make-bootable.log"; } 2>/dev/null; then
            echo "$dir/ovh-make-bootable.log"
            return 0
        fi
    done
    return 1
}

# The deployed root is the point: it survives the reboot, so the log can be read from
# rescue mode. /boot is a real partition and would also survive. /tmp is tmpfs and would
# not, but beats losing the log entirely if the root is not writable at this point.
LOG="$(log_path /var/log /boot /tmp)" || LOG=/dev/null
STATUS_LOG="$LOG"

exec > >(tee -a "$LOG") 2>&1

log()  { echo "cmesh-byol-bootloader: $*"; }
warn() { echo "cmesh-byol-bootloader: WARNING: $*" >&2; }

# Record a step's result durably. The summary is what a human reads after a failed
# deploy, so it is written as the script runs rather than at the end: if the deployer
# kills us on a timeout, everything up to that point is still on disk.
step() {
    local name="$1" rc="$2"
    if [ "$rc" -eq 0 ]; then
        echo "cmesh-byol-bootloader: OK   $name"
    else
        echo "cmesh-byol-bootloader: FAIL $name (exit $rc)"
    fi
    [ -n "$STATUS_LOG" ] && printf '%s\t%s\t%s\n' "$(date -Is)" "$rc" "$name" >> "$STATUS_LOG"
    return 0
}

report() {
    echo "cmesh-byol-bootloader: ================================================================"
    echo "cmesh-byol-bootloader: $*"
    echo "cmesh-byol-bootloader: ================================================================"
}

echo "cmesh-byol-bootloader: ================================================================"
echo "cmesh-byol-bootloader: cmesh-byol-arch deploy hook, $(date -Is)"
echo "cmesh-byol-bootloader: log: $LOG"
echo "cmesh-byol-bootloader: ================================================================"

### State as the deployer left it ###

# This is the record of what OVHcloud actually built. It is the first thing to look at
# when the layout is not what the partitioning API was asked for.
echo "--- uname ---";            uname -a                          2>&1 | sed 's/^/  /'
echo "--- firmware ---";         { [ -d /sys/firmware/efi ] && echo "UEFI" || echo "legacy BIOS"; } 2>&1 | sed 's/^/  /'
echo "--- lsblk ---";            lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL,MOUNTPOINT 2>&1 | sed 's/^/  /'
echo "--- partitions ---";       cat /proc/partitions            2>&1 | sed 's/^/  /'
echo "--- mount table ---";      findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 | sed 's/^/  /'
echo "--- /boot ---";            ls -la /boot                     2>&1 | sed 's/^/  /'
echo "--- /boot/efi ---";        ls -la /boot/efi                 2>&1 | sed 's/^/  /'
echo "--- /etc/fstab ---";       cat /etc/fstab                   2>&1 | sed 's/^/  /'

### Locate the EFI System Partition(s) ###

# /boot/efi has been populated on every deploy so far, but it is not documented that the
# deployer creates that mount point, and this script must not depend on an undocumented
# detail for the one step it cannot skip. Find the ESP by partition type GUID instead --
# that is what the firmware looks for -- and mount it if it is not already mounted.
ESP_DEVS=()
esp_candidates() {
    lsblk -rpnlo NAME,PARTTYPE 2>/dev/null | while read -r dev pt; do
        # C12A7328-F81F-11D2-BA4B-00A0C93EC93B is the EFI System Partition type GUID.
        case "$pt" in
            c12a7328-f81f-11d2-ba4b-00a0c93ec93b|C12A7328-F81F-11D2-BA4B-00A0C93EC93B)
                echo "$dev" ;;
        esac
    done
}

while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    case " ${ESP_DEVS[*]-} " in
        *" $dev "*) continue ;;
    esac
    ESP_DEVS+=("$dev")
done < <(esp_candidates)

# Fall back to any FAT partition if no ESP type GUID was found. A bootloader written to
# a FAT partition the firmware does not treat as an ESP will not boot, but the attempt
# costs nothing and the log then says exactly what was found.
if [ "${#ESP_DEVS[@]}" -eq 0 ]; then
    warn "no partition has the EFI System Partition type GUID"
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        ESP_DEVS+=("$dev")
    done < <(lsblk -rpnlo NAME,FSTYPE 2>/dev/null | awk '$2=="vfat"{print $1}')
    [ "${#ESP_DEVS[@]}" -gt 0 ] && warn "falling back to FAT partitions: ${ESP_DEVS[*]}"
fi

if [ "${#ESP_DEVS[@]}" -eq 0 ]; then
    warn "no ESP found at all; GRUB cannot be installed by this hook"
fi

# First ESP is mounted at the canonical /boot/efi, which is where grub-install expects
# it and where grub.cfg's search will look. The others are mounted only long enough to
# receive a copy of the loader, so that the machine still boots if the firmware picks a
# different disk.
mount_esp() {
    local dev="$1" target="$2"
    mkdir -p "$target" 2>/dev/null || return 1
    if findmnt -rn -S "$dev" >/dev/null 2>&1; then
        # Already mounted somewhere; bind it where we want it rather than mounting twice.
        mountpoint -q "$target" 2>/dev/null && return 0
        mount --bind "$(findmnt -rn -S "$dev" -o TARGET)" "$target" 2>/dev/null && return 0
        return 1
    fi
    mount "$dev" "$target" 2>&1 | sed 's/^/  /'
    mountpoint -q "$target" 2>/dev/null
}

PRIMARY_ESP=""
if [ "${#ESP_DEVS[@]}" -gt 0 ]; then
    if mount_esp "${ESP_DEVS[0]}" /boot/efi; then
        PRIMARY_ESP="${ESP_DEVS[0]}"
        log "ESP ${ESP_DEVS[0]} mounted at /boot/efi"
    else
        warn "could not mount ${ESP_DEVS[0]} at /boot/efi"
    fi
fi

### 1. Install the bootloader — the only step that must succeed ###

# Firmware on these servers network-boots, so no NVRAM entry may be created and the boot
# order must not be touched (--no-nvram). With no NVRAM entry the firmware falls back to
# the REMOVABLE MEDIA PATH, \EFI\BOOT\BOOTX64.EFI. --removable writes exactly that file;
# without it the machine does not boot at all, which is how an earlier deployment failed
# ("Chain on hard drive failed", then iPXE).
if [ -n "$PRIMARY_ESP" ]; then
    log "installing GRUB (x86_64-efi, removable path) on $PRIMARY_ESP"
    grub-install --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=cmesh \
        --removable --no-nvram --recheck
    step "grub-install" $?
else
    step "grub-install" 1
fi

# grub.cfg lives on /boot, not the ESP, and GRUB drops to a rescue prompt without it.
# Non-fatal: grub-install is what makes the machine bootable, and this only decides
# whether the menu is populated.
if [ -d /boot/grub ] || [ -n "$PRIMARY_ESP" ]; then
    mkdir -p /boot/grub 2>/dev/null || true
    log "generating /boot/grub/grub.cfg"
    grub-mkconfig -o /boot/grub/grub.cfg
    step "grub-mkconfig" $?
else
    warn "no /boot/grub and no ESP; skipping grub-mkconfig"
fi

### 2. Mirror the loader onto every other ESP ###

# A second ESP exists because the disks are mirrored and the machine must survive losing
# one. The firmware picks one of them with no NVRAM entry, so both need the loader.
for dev in "${ESP_DEVS[@]:1}"; do
    target="/mnt/cmesh-esp-$(basename "$dev")"
    if mount_esp "$dev" "$target"; then
        log "mirroring the removable loader onto $dev"
        mkdir -p "$target/EFI/BOOT" 2>/dev/null || true
        if [ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
            cp -f /boot/efi/EFI/BOOT/BOOTX64.EFI "$target/EFI/BOOT/BOOTX64.EFI"
            step "mirror loader to $dev" $?
        else
            warn "$dev: /boot/efi/EFI/BOOT/BOOTX64.EFI does not exist to mirror"
        fi
        umount "$target" 2>/dev/null || true
    else
        warn "could not mount $dev to mirror the loader"
    fi
done

### 3. Rebuild the initramfs — best effort, never fatal ###

# The image's initramfs was built inside a build VM, where autodetect embedded only the
# modules needed to boot virtio disks. This machine boots NVMe behind md RAID1, so it
# wants nvme and raid1 present. Both are named explicitly rather than inferred, since
# autodetect only has to miss one module for the boot to die in the initramfs with no
# output -- which is a failure this project has already paid for once.
#
# This is a best-effort step, and it is safe for it to fail: cmesh-byol-install writes
# its own /etc/mkinitcpio.conf with the modules and hooks the ENCRYPTED system needs and
# regenerates the initramfs inside the target chroot, and cmesh-byol-finalize rebuilds
# it a third time after enrolling the TPM. The initramfs only has to carry the bootstrap
# system as far as the installer.
if [ -f /etc/mkinitcpio.conf ]; then
    if grep -q '^MODULES=()' /etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=()/MODULES=(nvme raid1)/' /etc/mkinitcpio.conf
        log "set MODULES=(nvme raid1)"
    elif grep -q '^MODULES=' /etc/mkinitcpio.conf; then
        grep -q 'nvme' /etc/mkinitcpio.conf || sed -i 's/^MODULES=(/MODULES=(nvme raid1 /' /etc/mkinitcpio.conf
    fi
    grep '^MODULES=' /etc/mkinitcpio.conf 2>/dev/null | sed 's/^/  /' || warn "could not read MODULES= from /etc/mkinitcpio.conf"

    log "rebuilding the initramfs for this machine"
    mkinitcpio -P
    step "mkinitcpio -P" $?

    img=/boot/initramfs-linux.img
    if [ -f "$img" ]; then
        # Verify by DECOMPRESSING: the image is a compressed cpio archive, so grepping
        # the file directly finds nothing and would warn every time -- a check that
        # always fires is worse than no check.
        if command -v zstd >/dev/null 2>&1; then
            missing=""
            for mod in nvme raid1; do
                zstd -dc "$img" 2>/dev/null | grep -aq "$mod" || missing="$missing $mod"
            done
            if [ -n "$missing" ]; then
                warn "$img does not contain:${missing} (cmesh-byol-install rebuilds it anyway)"
            else
                log "verified nvme and raid1 are present in $(basename "$img")"
            fi
        fi
        log "initramfs: $(basename "$img") $(stat -c %s "$img" 2>/dev/null) bytes"
    else
        warn "no initramfs at $img"
    fi
else
    warn "no /etc/mkinitcpio.conf; skipping the initramfs rebuild"
fi

### Verdict ###

echo "--- ESP contents ---"
find /boot/efi -maxdepth 3 2>/dev/null | sed 's/^/  /'

LOADER_OK=0
if [ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
    LOADER_OK=1
else
    EEXIT=1
fi

if [ "$LOADER_OK" -eq 1 ]; then
    report "bootloader installed; the encrypted install runs on first boot"
else
    # Exit non-zero only here, where the machine genuinely has no boot path. OVHcloud
    # will report "the script did not end properly", which is accurate: there is
    # nothing on the ESP for the firmware to fall back to.
    report "FAILED: no /boot/efi/EFI/BOOT/BOOTX64.EFI. This machine has no boot path."
    echo "cmesh-byol-bootloader: the ESP was found but the loader was not written to it."
    echo "cmesh-byol-bootloader: see $LOG"
fi

echo "cmesh-byol-bootloader: done, $(date -Is), exit $EEXIT"
exit "$EEXIT"
HOOK

chmod 0755 /root/.ovh/make_image_bootable.sh

# Fail the build if it is missing: the whole deployment is blocked on this one file, and
# discovering that from OVH's error message after an upload wastes an hour.
test -x /root/.ovh/make_image_bootable.sh \
    || { echo "FATAL: /root/.ovh/make_image_bootable.sh is missing or not executable" >&2; exit 1; }
echo ">>> OVH hook present: /root/.ovh/make_image_bootable.sh"

rm -rf /tmp/cmesh-byol-files

### Phase 5: Cleanup ###

# machine-id is regenerated during the install (systemd-machine-id-setup).
rm -f /etc/machine-id
pacman -Scc --noconfirm

echo ">>> cmesh-byol-arch provisioning complete"

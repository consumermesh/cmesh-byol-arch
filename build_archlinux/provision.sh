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

### Phase 4b: OVH's required hook file ###

# /root/.ovh/make_image_bootable.sh MUST EXIST, or the deployment aborts before it
# starts with:
#   The '/root/.ovh/make_image_bootable.sh' file does not exist.
#
# This is a hard requirement of the BYOL contract, independent of whether the hook is
# useful. OVH's own build_archlinux ships one; this image deliberately omitted it on the
# reasoning that the hook runs chrooted into the filesystem OVH already laid down, which
# is too late to change the partition layout. That reasoning was right and the conclusion
# was wrong: OVH *validates presence*, so the file has to be there even when it has
# nothing to do.
#
# It is intentionally a no-op. Everything this image needs at deploy time happens on
# first boot, from cmesh-byol-install, which repartitions both disks and installs into
# the encrypted stack. Doing anything here would be doing it in the wrong place — and
# OVH runs this before the first reboot, while the disk layout it just created is still
# the one we are about to replace.
install -d -m 0755 /root/.ovh
cat > /root/.ovh/make_image_bootable.sh <<'HOOK'
#!/bin/bash
# Required by the OVHcloud BYOL contract. Deliberately does nothing.
#
# This image does not configure the deployed system here. It cannot: this hook runs
# chrooted into the filesystem OVH has already partitioned and formatted, which is after
# the point where the disk layout could still be changed. The real work happens on the
# FIRST BOOT of the deployed system, in /usr/local/sbin/cmesh-byol-install, which
# rewrites both disks as LUKS2 under RAID1 and installs into them.
#
# See https://github.com/consumermesh/cmesh-byol-arch
set -euo pipefail

echo "cmesh-byol-arch: nothing to do here by design."
echo "  The encrypted install runs on first boot: /usr/local/sbin/cmesh-byol-install"
echo "  Progress is logged to /var/log/cmesh-byol-install.log and /dev/console."
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

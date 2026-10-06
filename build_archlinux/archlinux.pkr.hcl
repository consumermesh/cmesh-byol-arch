packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# Builds a BYOL-compatible Arch Linux image whose FIRST BOOT on the target bare-metal
# server re-partitions both disks into LUKS2-under-RAID1 and installs the system into it.
#
# Modelled on ovh/bringyourownlinux build_archlinux, with two deliberate differences:
#
#   1. No /root/.ovh/make_image_bootable.sh. That hook runs chrooted inside the
#      filesystem OVH already laid down, which is too late to change the partition
#      layout or the RAID stacking. Everything interesting happens on first boot
#      instead, from build_archlinux/files/cmesh-byol-install.
#   2. The image still satisfies the BYOL contract exactly (single ext4 partition),
#      because OVH requires that of the image it burns.

source "qemu" "baremetal" {
  # Arch Linux cloud image (rolling).
  iso_url      = "https://archlinux.mirrors.ovh.net/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
  iso_checksum = "file:https://archlinux.mirrors.ovh.net/archlinux/images/latest/Arch-Linux-x86_64-cloudimg.qcow2.SHA256"
  disk_image   = true

  # Grow the source image: a system upgrade plus mdadm/cryptsetup/systemd tooling
  # does not fit in the stock ~2G.
  disk_size = "6G"

  format           = "qcow2"
  vm_name          = "archlinux.qcow2"
  output_directory = "output"
  disk_compression = true
  # Let blkdiscard in provision.sh actually release freed blocks in the qcow2.
  disk_discard = "unmap"

  accelerator = "kvm"
  cpus        = 2
  memory      = 2048
  headless    = true

  communicator              = "ssh"
  ssh_username              = "packer"
  ssh_password              = "packer"
  ssh_clear_authorized_keys = true
  ssh_timeout               = "15m"

  # Remove the provisioning user (known password) before powering off. The
  # install-time service is left enabled: it is what runs on the real hardware.
  shutdown_command = "sudo sh -c 'userdel -rf packer 2>/dev/null; poweroff'"

  # Serial to stdout so provision.sh boot messages land in the Packer log (PACKER_LOG=1).
  qemuargs = [["-serial", "stdio"]]

  # cloud-init NoCloud seed: create the provisioning user from the CD.
  cd_content = {
    "meta-data" = ""
    "user-data" = <<-USERDATA
    #cloud-config
    ssh_pwauth: true
    users:
      - name: packer
        plain_text_passwd: packer
        sudo: ALL=(ALL) NOPASSWD:ALL
        lock_passwd: false
    USERDATA
  }
  cd_label = "cidata"
}

build {
  sources = ["source.qemu.baremetal"]

  provisioner "file" {
    # Paths in a provisioner are resolved relative to the WORKING DIRECTORY, not to
    # this HCL file — so `build_archlinux/files` must be spelled out when packer is
    # invoked from the repository root (which is what the CI workflow does).
    source      = "build_archlinux/files/"
    destination = "/tmp/cmesh-byol-files"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }} && sudo {{ .Path }}"
    script          = "build_archlinux/provision.sh"
  }
}

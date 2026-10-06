packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# Hardware acceleration for the build VM.
#
# "kvm" is 10-30x faster and is what you want on a machine that offers it (bare metal,
# or a runner with real nested virtualisation). "tcg" is pure software emulation: slow,
# but it works anywhere — including CI runners that expose /dev/kvm but deny access to
# it, which is the case for GitHub's hosted runners.
#
# Override at build time:  packer build -var accelerator=tcg ...
variable "accelerator" {
  type    = string
  default = "kvm"
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

  accelerator = var.accelerator
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
  #
  # `shell: /bin/bash` is explicit rather than relying on the image's default account
  # shell — OVH's Ubuntu example (known-good on the same runners) specifies it and their
  # Arch example does not. The sshd drop-in is likewise belt-and-braces for
  # PasswordAuthentication, which `ssh_pwauth` alone sets by editing the main
  # sshd_config. Neither is currently required — the build connects without them — so
  # they are deliberately minimal and permissive-free.
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
        shell: /bin/bash
    write_files:
      - path: /etc/ssh/sshd_config.d/99-packer.conf
        permissions: '0644'
        content: |
          PasswordAuthentication yes
          UseDNS no
    runcmd:
      - systemctl restart sshd || systemctl restart ssh || true
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
    #
    # destination is a DIRECTORY INTO WHICH the files are placed: packer appends the
    # source basename and creates it, so with source "build_archlinux/files/" the four
    # files land at /tmp/cmesh-byol-files/<name>.
    #
    # Do NOT "fix" this to /tmp on the theory that the basename is appended the other
    # way round. Doing that drops the files loose in /tmp and provision.sh then fails
    # with "FATAL: /tmp/cmesh-byol-files is not a directory". The authoritative evidence
    # is the shell provisioner: packer writes its own script to /tmp/script_<pid>.sh,
    # i.e. it appends the basename to the destination directory.
    source      = "build_archlinux/files/"
    destination = "/tmp/cmesh-byol-files"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }} && sudo {{ .Path }}"
    script          = "build_archlinux/provision.sh"
  }
}

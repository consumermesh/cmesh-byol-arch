# cmesh-byol-arch

A [Bring Your Own Linux](https://github.com/ovh/bringyourownlinux) (BYOL) image for
OVHcloud bare-metal servers that installs **Arch Linux with a LUKS2-encrypted root
under RAID1**.

Point the OVHcloud console (or the `POST /dedicated/server/{serviceName}/reinstall`
API) at the released `.qcow2` URL, and the server comes up encrypted.

---

## Why this repo exists

OVHcloud's deployer partitions and formats your disks *before* it lays down the image
you supply. Its storage model has no LUKS — queried from the public API:

```
GET /1.0/dedicated/installationTemplate/byolinux_64
→ "filesystems": ["btrfs", "ext4", "swap", "xfs", "zfs"], "lvmReady": true
```

There is no `luks`/`dm-crypt` filesystem type, and no encryption parameter anywhere in
the partitioning schema. So **an encrypted disk cannot be produced by the deployer.**
It has to be produced by the image itself.

That is what this repo does: the BYOL image is a **bootstrap**. Its first boot
re-partitions both disks, builds the encrypted stack, installs the system into it, and
reboots into the encrypted installation.

ZFS is the other candidate, because it is the one encryption primitive OVH's API does
expose. It is rejected here deliberately — see [Why not ZFS](#why-not-zfs).

## The layout it produces

```
nvme0n1                              nvme1n1
├─p1  512M  vfat  (ESP)              ├─p1  512M  vfat  (ESP)
├─p2    1G  linux-raid ─┐            ├─p2    1G  linux-raid ─┐
│                      ├─ md2 (raid1, ext4) → /boot         │
└─p3  ~893G LUKS2 ─┐   │            └─p3  ~893G LUKS2 ─┐    │
   └─ cryptroot0 ──┴───┴──── md3 (raid1, ext4) ────────┴────┘
                                  → /
```

**LUKS sits *under* RAID, not over it.** This is the single most important decision in
the design:

| | LUKS under RAID (this repo) | LUKS over RAID |
|---|---|---|
| A disk dies | Remaining leg decrypts on its own; array keeps running | The only LUKS header was on the array — restore from backup |
| Replace a disk | Partition, LUKS format, `mdadm --add`, resync | Re-key the entire array |
| Headers | One per disk | One for everything |
| Failure mode | Degraded but alive | Total data loss from a *single* disk failure |

Encrypting the assembled array is fewer steps and quietly trades away the redundancy
you bought the second disk for. If you take one thing from this repo, take that.

`/boot` and both ESPs stay unencrypted. GRUB reads `/boot` directly, and firmware reads
FAT32 directly — encrypting either means a passphrase at the bootloader plus a real risk
of an unbootable host. Neither holds PHI; the kernel and initramfs are not the sensitive
part.

## Why not ZFS

ZFS native encryption would let OVH's deployer do the layout. Three costs, none of which
are about encryption quality:

1. **Arch's ZFS initramfs hook is incompatible with systemd in the initramfs.** The
   [ArchWiki](https://wiki.archlinux.org/title/Install_Arch_Linux_on_ZFS) states that
   systemd in the initramfs "will lock out the root filesystem and prevent booting" for a
   ZFS root, and requires switching every `systemd` hook to busybox. The documented
   systemd-compatible alternative, `mkinitcpio-sd-zfs`, is AUR-only and **"will not work
   for Encrypted filesystems."**
2. **ZFS pins your kernel.** It is not in Arch's official repositories. Per the same
   wiki: *"It will not be possible to apply any kernel updates until updated packages
   are uploaded."* On a rolling distro that is a structural conflict with security
   patching — and a compliance problem, not just an operational one.
3. It adds an out-of-tree kernel module and a third-party binary repository to the
   trust chain.

LUKS costs none of that: `cryptsetup`, `mdadm` and `lvm2` are all in Arch's `core`
repository and all ship on the Arch installation ISO. No third-party repo, no
out-of-tree module, kernel updates unconstrained.

## Requirements for the target server

- **Exactly two NVMe disks** of equal size. The installer validates this and refuses to
  run otherwise.
- **KVM/IPMI access.** You will need it. This image repartitions live disks; do not run
  it blind.
- **≥ 8 GiB RAM.** The self-install holds a compressed copy of the root filesystem in
  `/run` (tmpfs) while it destroys the disks. It refuses to start below the threshold.
- UEFI boot. The installer writes GRUB to both ESPs.

> **This image destroys both disks, unconditionally.** That is its purpose. It is not
> safe to attach to a server holding data you want to keep.

## How to use it

### 1. Build the image (CI, preferred)

Push a tag; the [`Builder`](.github/workflows/build.yml) workflow produces a GitHub
Release containing `archlinux.qcow2` and its `.sha512`, exactly like OVH's own example
images. Release asset URLs are directly consumable by the OVHcloud API:

```
https://github.com/consumermesh/cmesh-byol-arch/releases/download/<tag>/archlinux.qcow2
https://github.com/consumermesh/cmesh-byol-arch/releases/download/<tag>/archlinux.qcow2.sha512
```

### 2. Or build locally

```bash
packer init build_archlinux/archlinux.pkr.hcl
cd build_archlinux && PACKER_LOG=1 packer build archlinux.pkr.hcl
```

Requires `packer`, `qemu-system-x86`, `qemu-utils` and `genisoimage`.

### 3. Deploy it

Via the OVHcloud Control Panel: **Bare Metal Cloud → Dedicated servers → your server →
General information → `...` → Install → Custom → Bring Your Own Linux**, then supply the
image URL and checksum.

Via the API, the important part is the **passphrase** — it is supplied through
cloud-init, not through a custom field:

```json
{
  "operatingSystem": "byolinux_64",
  "customizations": {
    "hostname": "cmesh-hipaa",
    "imageURL": "https://github.com/consumermesh/cmesh-byol-arch/releases/download/v1/archlinux.qcow2",
    "imageCheckSum": "<sha512 from the release>",
    "imageCheckSumType": "sha512",
    "configDriveUserData": "<base64 of the cloud-config below>"
  }
}
```

`configDriveUserData` is **base64-encoded**. The cleartext it encodes:

```yaml
#cloud-config
ssh_authorized_keys:
  - ssh-ed25519 AAAA... you@workstation
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [wheel]
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... you@workstation
# Consumed by the installer as the initial LUKS passphrase, then scrubbed.
# CHANGE THIS. It must be identical on both LUKS keyslots to be usable as a rescue
# passphrase for either disk.
cmesh_luks_passphrase: "CHANGE-ME-long-random-passphrase"
```

Generate it with something that is not your shell history:

```bash
head -c 32 /dev/urandom | base64
```

The passphrase is read from the config drive, used to create both keyslots, and the
config drive is then **overwritten with random bytes** so the only copy on the server is
inside the LUKS keyslots.

## What happens on first boot

Roughly two minutes after the deployer finishes:

1. `cmesh-byol-install.service` starts and refuses to continue unless the disk count,
   memory, KVM/block-device access and TPM presence are all as expected.
2. It reads `cmesh_luks_passphrase` from the config drive into memory.
3. It copies the running root filesystem into a compressed tarball **in `/run` (tmpfs)**.
4. It destroys both partition tables and rebuilds the layout above.
5. It extracts the tarball into the encrypted root, writes `fstab` / `crypttab` /
   `mkinitcpio.conf`, and generates the initramfs.
6. It installs GRUB to **both** ESPs.
7. It **scrubs the config drive**, then reboots.
8. On the way back up, the initramfs unlocks LUKS from a temporary keyfile on `/boot`,
   and a one-shot `cmesh-byol-finalize.service`:
   - enrols the key in the TPM2 (`systemd-cryptenroll`) for unattended boot,
   - **deletes the temporary keyfile** and rebuilds the initramfs,
   - leaves the passphrase keyslot intact as the rescue path.

If any step fails the installer logs to the serial console and to
`/var/log/cmesh-byol-install.log`, and does **not** mark itself complete — so you can
read the failure over KVM rather than guessing.

### About the temporary keyfile

Between step 5 and step 8 the root is unlocked by a keyfile on the (unencrypted)
`/boot`, so the machine can reboot unattended. It is removed as soon as the TPM is
enrolled. If you would rather not have that window at all, delete
`cmesh-byol-finalize.service` from the image and accept a passphrase prompt at every
boot instead.

### About TPM2 without a PIN

Auto-unlock is enrolled **without a PIN** (`--tpm2-with-pin` omitted) so the server can
recover from a power event without a human. Add `--tpm2-with-pin=yes` to the
`systemd-cryptenroll` call in `files/cmesh-byol-finalize` if you would rather have a
second factor and accept console access on every boot. Record whichever you choose —
and record the PCR policy, because a firmware update that changes those measurements
turns silent unlock into a passphrase prompt.

## Verifying an installation

```bash
cryptsetup status cryptroot0          # open
cryptsetup status cryptroot1
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
#   md3's two children must be cryptroot0 / cryptroot1 — NOT nvmeXp3
blkid /dev/nvme0n1p3                  # TYPE="crypto_LUKS"
cat /proc/mdstat                      # md2 and md3 both [UU]
findmnt -no SOURCE /
```

Then confirm it survives an unattended reboot, which is the property that actually
matters:

```bash
systemctl reboot
# after it returns, without a passphrase:
cryptsetup status cryptroot0 | head -3
```

## Backing up the LUKS headers

Losing a header loses that disk, even with the passphrase and intact data. There are two
independent headers here (that is the point of LUKS-under-RAID), but neither is
recoverable from the other.

`cryptsetup luksHeaderBackup` is **LUKS1-only**. For LUKS2 there is no supported
equivalent, so copy the header and keyslot area directly. Measured: the keyslot area is
`16744448` bytes at offset `32768`, payload at `16777216` (16 MiB), and that size is
fixed — it does not scale with the device, so 32 MiB covers it:

```bash
dd if=/dev/nvme0n1p3 of=/root/luks-header-nvme0n1p3.img bs=1M count=32
dd if=/dev/nvme1n1p3 of=/root/luks-header-nvme1n1p3.img bs=1M count=32
```

Store them off-host; a header plus the passphrase decrypts everything. Test the restore
on a scratch device before you need it.

## Related

- [encrypted-raid1-install.md](https://github.com/consumermesh/cmesh.ai/blob/main/deploy/runbooks/encrypted-raid1-install.md)
  — the manual version of this design, and the reference for the layout and the
  LUKS-under-RAID argument.
- [OVHcloud: API and Storage](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/partitioning-ovh.md)
  — the partitioning model this repo works around.
- [ovh/bringyourownlinux](https://github.com/ovh/bringyourownlinux) — the BYOL image
  contract this repo implements.

## Status

Built from the OVH `build_archlinux` example. The install path is **not yet proven on
hardware** — treat the first deployment as a test, keep KVM open, and do not put real
data on the server until `Verifying an installation` passes and a reboot comes back
without a passphrase.

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

That is what this repo does: the BYOL image is a **bootstrap**. OVH's deployer is asked
for one extra RAID1 partition that nothing runs from. On first boot the bootstrap takes
that partition, builds the encrypted stack in it, installs the system into it, and
reboots into the encrypted installation.

ZFS is the other candidate, because it is the one encryption primitive OVH's API does
expose. It is rejected here deliberately — see [Why not ZFS](#why-not-zfs).

## The layout it produces

```
nvme0n1                                nvme1n1
├─p1  511M  vfat  (ESP) /boot/efi      ├─p1  511M  vfat  (ESP, loader mirrored)
├─p2    1G  linux-raid ─┐              ├─p2    1G  linux-raid ─┐
│                       ├─ md (raid1, ext4) → /boot            │   [unencrypted]
├─p3    8G  linux-raid ─┐              ├─p3    8G  linux-raid ─┐
│                       ├─ md (raid1, ext4) → bootstrap /      │   [dormant after install]
└─p4  ~880G LUKS2 ─┐    │              └─p4  ~880G LUKS2 ─┐    │
   └─ cryptroot0 ──┴────┴── md/cmeshroot (raid1, ext4) ───┴────┘
                                  → /  (and /swap/swapfile inside it)
```

**Every partition above is created by OVH's partitioner**, from the `storage` block in
the reinstall payload (see [Deploy it](#5-deploy-it)). The installer never rewrites a
partition table. It cannot: it runs from a root filesystem on these same disks, and the
kernel will not reload a partition table while any partition on the disk is held open.
An earlier design that wiped the disks from the running system failed exactly there.

So the deployer is asked for `/boot`, a small `/` for the bootstrap, and a third RAID1
partition mounted at `/data` with `size: 0` (the rest of the disk). `/data` is the
**payload**: nothing runs from it, so the installer can stop its array, LUKS-format the
two members, and build the encrypted root on top. `/boot` and the ESPs are shared with
the bootstrap and keep the GRUB the deploy hook installed. The bootstrap root stays on
disk, unused, as a known-good rescue environment; reclaim it later if you want the 8 GiB.

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

`/boot` is **1 GiB**. Measured on an equivalent OVH Arch host, `/boot` actually holds
**71 MiB** — `intel-ucode.img` 15M, `initramfs-linux.img` 20M, `vmlinuz-linux` 17M,
`grub/` 19M, `amd-ucode.img` 0.3M — with one kernel installed and the stock mkinitcpio
preset using `PRESETS=('default')`, so **no fallback image is built**. That is ~8% of
this partition, or ~12% transiently while a kernel upgrade has both versions on disk.
OVH provision the same target at 988 MiB, so this is marginally more than the layout it
replaces.

If you later add `linux-lts` as a second, independently bootable kernel, re-check it:
two kernels roughly double the 37 MiB per-kernel cost, which still fits here, but it is
the change that would eventually matter. `/boot` has no LVM to grow into, so resizing it
later means working on a live encrypted partition and md array.

The root filesystem is created with `-m 1` — 1% reserved blocks instead of ext4's 5%
default. Unlike the `/boot` figure, this one is **measured on the real host**: `df`
reports `878G total, 3.0G used, 830G avail`, and `878 − 3 − 830 = 45 GiB` of hidden
reserve, i.e. 5.15%. Dropping to 1% returns **~35 GiB** to non-root users, including
postgres.

Note also that `df` on that host reports 878 GiB for a partition of ~891 GiB: the
difference is ext4's own inode and bitmap overhead (~1.5%), not free space. Plan capacity
against the `df` number, not the partition size.

## Swap, and why it is a file

Swap **is** configured, as `/swap/swapfile` — a file inside the encrypted root, sized to
`min(RAM/2, 8 GiB)` with a 4 GiB floor.

**Why not a swap partition.** Swap holds whatever the kernel evicted from RAM: on this
host that is customer records, chat transcripts, database pages, and — because the LUKS
mappings are open — potentially key material. An unencrypted swap partition would quietly
undo the encryption-at-rest property the rest of this layout exists to provide. A swap
file on the encrypted root inherits that encryption for free. The other correct option is
a dedicated LUKS swap partition with a random key per boot (`crypttab` option `swap`);
that is more moving parts for no extra protection here, because the root is already
encrypted under the same header.

**Why swap at all.** Without it, memory pressure on a database server invokes the OOM
killer and terminates postgres. With it, cold anonymous pages are evicted and the process
survives. Running with no swap is a deliberate choice only when memory is provably
oversized for the workload — not a default worth taking silently.

The entry uses `pri=0` and is deliberately given no `resume=` offset, so the kernel never
treats it as a hibernation target.

## Hibernation is refused

`systemctl hibernate` will not work on this image, and that is intentional. A hibernation
image is a complete copy of decrypted RAM written to disk; on a PHI host it is a
disclosure risk with no operational justification when suspend-to-idle covers the same
need. If you want it anyway, you must size swap to at least RAM and add `resume=` and
`resume_offset=` to the kernel command line — and you should write down why.

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

- **Two NVMe disks** of equal size, deployed with the three-partition `storage` layout
  below. The installer checks that `/data` is a RAID1 array with one member per disk and
  refuses to run otherwise.
- **KVM/IPMI access.** You will need it. Do not run this blind.
- UEFI boot. The deploy hook writes GRUB to the ESP and mirrors the loader to the other.

> **This image destroys the `/data` partition, unconditionally.** That is its purpose.
> It is not safe to attach to a server holding data you want to keep.

## How to use it

### 1. Build it (recommended: on the target server)

The image is only needed to install a server, so the shortest path is to build it **on
that server**. KVM is available there, nothing needs uploading, and the checksum is
printed for the `imageCheckSum` field:

```bash
git clone https://github.com/consumermesh/cmesh-byol-arch
cd cmesh-byol-arch
sudo pacman -S --needed packer qemu-system-x86 qemu-utils cdrtools   # or libisoburn
./build.sh
```

Takes roughly 10–20 minutes with KVM, and prints the image path, size and sha512.

### 2. Or build it in a container

If you would rather not install packer and QEMU on the machine, run the build inside a
throwaway Arch container. **Run this on the host**, not inside another container:

```bash
./build-in-container.sh
RUNTIME=docker ./build-in-container.sh        # force a runtime
CPUS=8 MEMORY=8g ./build-in-container.sh
```

The repository is bind-mounted read-only and copied inside the container, so your
working tree cannot be modified by a failed build. `build_archlinux/output/` is
bind-mounted so the `.qcow2` lands on the host, and the checksum is printed.

`/dev/kvm` is passed through when present — that is the whole reason to prefer this over
CI. Without it the build falls back to software emulation, which works but is slower.

### 3. Or let CI publish a release

Push a tag and the [`Builder`](.github/workflows/build.yml) workflow attaches
`archlinux.qcow2` and its checksum to a GitHub Release. Release asset URLs are directly
consumable by the OVHcloud API:

```
https://github.com/consumermesh/cmesh-byol-arch/releases/download/<tag>/archlinux.qcow2
https://github.com/consumermesh/cmesh-byol-arch/releases/download/<tag>/archlinux.qcow2.sha512
```

> **CI caveat.** GitHub's hosted runners expose `/dev/kvm` but the `runner` user is not
> in the `kvm` group, and `build.sh`'s `sg kvm` fallback does not reliably obtain it
> there. The workflow therefore builds under `tcg`. Measured: a booted,
> SSH-reachable guest in **~4 minutes** and the full build well inside the job timeout,
> so this is viable but not fast. Prefer method 1 or 2 when you want speed.

### 4. Or build manually

Run from the **repository root** — the HCL's provisioner paths are resolved relative to
the working directory, not to the HCL file:

```bash
packer init build_archlinux/archlinux.pkr.hcl
PACKER_LOG=1 packer build build_archlinux/archlinux.pkr.hcl
packer build -var accelerator=tcg build_archlinux/archlinux.pkr.hcl   # force software
```

Requires `packer`, `qemu-system-x86`, `qemu-utils` and `genisoimage`, plus `/dev/kvm`
for a tolerable build time. The image lands in `build_archlinux/output/`.

### 5. Deploy it

Via the OVHcloud Control Panel: **Bare Metal Cloud → Dedicated servers → your server →
General information → `...` → Install → Custom → Bring Your Own Linux**, then supply the
image URL and checksum.

Via the API (`scripts/ovh-reinstall.exs` sends `deploy.json`; start from
`deploy.json.example`), two parts matter. The **`storage` layout** is what the installer
expects to find, and the **passphrase** is supplied through cloud-init, not through a
custom field:

```json
{
  "operatingSystem": "byolinux_64",
  "storage": [{
    "diskGroupId": 1,
    "hardwareRaid": [],
    "partitioning": {
      "disks": 2,
      "layout": [
        { "fileSystem": "ext4", "mountPoint": "/boot", "size": 1024, "raidLevel": 1, "extras": {} },
        { "fileSystem": "ext4", "mountPoint": "/",     "size": 8192, "raidLevel": 1, "extras": {} },
        { "fileSystem": "ext4", "mountPoint": "/data", "size": 0,    "raidLevel": 1, "extras": {} }
      ]
    }
  }],
  "customizations": {
    "hostname": "cmesh-hipaa",
    "imageURL": "https://github.com/consumermesh/cmesh-byol-arch/releases/download/v1/archlinux.qcow2",
    "imageCheckSum": "<sha512 from the release>",
    "imageCheckSumType": "sha512",
    "configDriveUserData": "<base64 of the cloud-config below>",
    "efiBootloaderPath": "\\EFI\\BOOT\\BOOTX64.EFI"
  }
}
```

The ESP is not listed: OVH adds one per disk on UEFI servers. `/data` must be RAID1,
must have one member on each disk, and is the only thing the installer destroys. The
Control Panel's Custom partitioning can produce the same layout, but it has been observed
to drop `configDriveUserData`, so prefer the API.

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
# Optional. The key-only sudo account the installed system gets; root SSH login is
# turned off once it exists. Default: admin.
cmesh_admin_user: admin
```

Generate it with something that is not your shell history:

```bash
head -c 32 /dev/urandom | base64
```

The passphrase is read from the config drive, used to create both keyslots, and the
config drive is then **overwritten with random bytes** so the only copy on the server is
inside the LUKS keyslots.

## Two phases: the deploy-time hook, then the first boot

There are two places code runs, and confusing them produces an unbootable server — which
is what happened on the first real deployment.

**Phase 1 — `/root/.ovh/make_image_bootable.sh`, run by OVHcloud during deployment.**
OVHcloud partitions the disks, rsyncs the image in, and **formats the ESP**. Confirmed
from rescue mode on a failed deployment: the ESP came out completely empty, with no
`/EFI` directory at all. So nothing the build image puts on the ESP survives, and this
hook is the only place a bootloader can be installed.

It installs GRUB with `--removable`, which writes `\EFI\BOOT\BOOTX64.EFI` — the UEFI
fallback path. That is required rather than cosmetic: we pass `--no-nvram` because OVH
servers network-boot and the firmware boot order must not be touched, and with no NVRAM
entry the firmware only ever finds the removable path. It also regenerates `grub.cfg`,
and fails loudly if either file is missing.

The hook does **not** touch the partition layout, and neither does anything else: the
layout OVH created is the final one.

**Phase 2 — `cmesh-byol-install`, on the first boot of the deployed system.**
Only reachable once Phase 1 has produced a loader. It reads the LUKS passphrase, stops
the `/data` array, builds LUKS2-under-RAID1 on its members, copies the running system
into it, points the shared `/boot` at it, and reboots.

> The ordering is the subtle part. Phase 2 cannot install the bootloader that Phase 2
> needs in order to run. A no-op Phase 1 therefore does not produce a degraded system —
> it produces a server that never boots.

## What happens on first boot

Roughly two minutes after the deployer finishes:

1. `cmesh-byol-install.service` starts and refuses to continue unless `/boot` and
   `/boot/efi` are mounted, `/data` is a RAID1 array with one member on each of two
   disks, and nothing else holds those members.
2. It reads `cmesh_luks_passphrase` (and the SSH keys) from the config drive into memory.
   OVHcloud's config drive is OpenStack-format (iso9660, `LABEL=config-2`) and keeps the
   user data at `openstack/latest/user_data`; the NoCloud `/user-data` layout is accepted
   too.
3. It unmounts `/data`, stops its array, and wipes the md superblocks from both members.
   Nothing else on the disks is touched.
4. It LUKS-formats both members, opens them as `cryptroot0`/`cryptroot1`, and creates
   `md/cmeshroot` over the two mappings. ext4, 1% reserved.
5. It mounts the new root, binds the shared `/boot` into it, and `rsync`s the running
   system across. Then it writes `fstab` (UUIDs only), `mdadm.conf`,
   `crypttab.initramfs` and `mkinitcpio.conf`, enables sshd and networking, and disables
   itself and cloud-init on the installed system.
6. Last, because it rewrites the shared `/boot`: it generates the initramfs (verified to
   contain the crypttab and keyfile) and regenerates `grub.cfg` (verified to carry
   `root=UUID=` of the new filesystem). GRUB itself is not reinstalled; the hook's loader
   is reused.
7. It **scrubs the config drive**, then reboots.
8. On the way back up, the initramfs unlocks LUKS from a temporary keyfile on `/boot`,
   and a one-shot `cmesh-byol-finalize.service`:
   - enrols the key in the TPM2 (`systemd-cryptenroll`) for unattended boot,
   - **deletes the temporary keyfile** and rebuilds the initramfs,
   - leaves the passphrase keyslot intact as the rescue path.

If any step fails the installer logs to the serial console and to
`/var/log/cmesh-byol-install.log`, and does **not** mark itself complete — so you can
read the failure over KVM rather than guessing.

> **If the console goes silent right after `Loading initial ramdisk ...`**, the kernel is
> not on the console you are watching. OVHcloud's operator console is a serial line, and
> the deploy hook copies the deployer kernel's `console=` parameters into GRUB (exactly as
> OVHcloud's reference hooks do) so that the kernel, the installer and the installed
> system all print there. An image built before that step existed boots with no
> `console=` at all and prints to the VGA framebuffer only — every failure *and every
> success* looks like a hang. Boot rescue mode and run `test/post-install-probe.sh`: it
> prints the deploy hook's log, the journal of every boot the kernel actually reached,
> what the initramfs contains, and the kernel lines in `grub.cfg`.

### About the temporary keyfile

Between step 5 and step 8 the root is unlocked by a keyfile on the (unencrypted)
`/boot`, so the machine can reboot unattended. It is removed as soon as the TPM is
enrolled. If you would rather not have that window at all, delete
`cmesh-byol-finalize.service` from the image and accept a passphrase prompt at every
boot instead.

### About TPM2 without a PIN

Auto-unlock is enrolled **without a PIN** (`--tpm2-with-pin` omitted) so the server can
recover from a power event without a human. Add `--tpm2-with-pin=yes` to the
`systemd-cryptenroll` call in `build_archlinux/files/cmesh-byol-finalize` if you would rather have a
second factor and accept console access on every boot. Record whichever you choose —
and record the PCR policy, because a firmware update that changes those measurements
turns silent unlock into a passphrase prompt.

## Verifying an installation

```bash
cryptsetup status cryptroot0          # open
cryptsetup status cryptroot1
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
#   the array under / must have cryptroot0 / cryptroot1 as children — NOT nvmeXnYpZ
blkid -t TYPE=crypto_LUKS             # both payload partitions, one per disk
cat /proc/mdstat                      # every array [UU]
findmnt -no SOURCE /                  # /dev/md/cmeshroot (or its mdNNN alias)

# Swap is on the encrypted volume, not a bare partition:
swapon --show                         # NAME must be /swap/swapfile
findmnt -no SOURCE -T /swap/swapfile  # must resolve to the same array as /
ls -l /swap/swapfile                  # 0600 root:root
```

Then confirm it survives an unattended reboot, which is the property that actually
matters:

```bash
systemctl reboot
# after it returns, without a passphrase:
cryptsetup status cryptroot0 | head -3
```

## Hardening and monitoring

Encryption at rest is one HIPAA safeguard. The rest — access control, audit controls,
integrity, automatic logoff, authentication — is applied by
`build_archlinux/files/cmesh-byol-harden` with the files under
`build_archlinux/files/hardening/`. provision.sh runs it at build time (`--build`), so
every image carries it, and the installer copies the result into the encrypted system.
The same script, without `--build`, applies it to a server that is already running.

What it puts in place:

| Control | How |
|---|---|
| Named admin account, no shared root login | The installer creates `admin` (or `cmesh_admin_user:` from the cloud-config) in `wheel`, gives it the config drive's SSH keys, then writes `PermitRootLogin no` + `AllowUsers admin` — only after the keys are confirmed in place. sudo is NOPASSWD (there are no passwords) and logs every command and its I/O. |
| SSH hardening | `sshd_config.d/10-cmesh-hardening.conf`: keys only, 3 tries, 10-minute idle logoff, no forwarding, pre-auth banner (`/etc/issue.net`), modern ciphers, VERBOSE logging (key fingerprint per login). |
| Firewall | nftables, default deny inbound, SSH rate-limited from `ssh_allowed_v4` — **edit it** in `/etc/nftables.conf` to your management addresses. SSH over IPv6 is off by default (commented rules to enable). sshguard bans brute-forcers into its own nft set. |
| Audit trail | auditd with `rules.d/50-cmesh-hipaa.rules`: identity files, sudo, every command run as root by a logged-in user (`-k rootcmd`), the boot path, LUKS/mdadm tools, firewall, modules, mounts, time, failed access. `60-cmesh-phi.rules` watches `/srv` and `/home`; point it at where the PHI lives. `99-…` makes the set immutable until reboot. |
| Logs | journald persistent, compressed, sealed (run `journalctl --setup-keys` once), bounded to 512 MB. auditd 10 × 50 MB, rotates, never suspends. |
| Kernel | sysctl: kptr/dmesg restriction, no SysRq, no forwarding, rp_filter, no redirects, syncookies. AppArmor on the kernel command line and `apparmor.service` enabled. No core dumps anywhere (coredump.conf + hard ulimit). |
| Shell | `TMOUT=900` read-only in login shells. |
| Hardware | `mdmonitor` (with `--syslog`) and `smartd` (daily short, weekly long self-test) report through `cmesh-alert`. |
| Vulnerabilities | `cmesh-arch-audit.timer` checks installed packages against the Arch security tracker daily; packages with an available fix raise an alert. Arch has no security-only channel: **schedule `pacman -Syu` and a reboot window.** |
| File integrity | `cmesh-integrity`: daily `pacman -Qkk` plus a sha256 manifest of `/etc`, `/boot`, `/usr/local`, unit files and SSH keys, against a baseline taken after finalize. A pacman hook re-baselines after each transaction so upgrades do not alert. |
| Alerts | Everything above calls `/usr/local/sbin/cmesh-alert`, which writes to the journal (`-t cmesh-alert`, priority err) and `/var/log/cmesh-alerts.log`. Add your delivery there, or alert on the identifier from your collector. |

### On a server that is already installed

No reinstall. Copy the script and its files, run it as root, and keep that session open
until you have confirmed a second one works:

```bash
scp -r build_archlinux/files/cmesh-byol-harden build_archlinux/files/hardening root@HOST:/tmp/
ssh root@HOST
/tmp/cmesh-byol-harden --files /tmp/hardening     # add --admin-user NAME to not use "admin"
```

It creates the admin account from root's `authorized_keys`, validates the sshd config
with `sshd -t` before reloading (and removes its own drop-ins if that fails), checks the
firewall with `nft -c` before loading it (established connections are accepted first, so
your session survives), and prints what still needs a reboot (AppArmor, `audit=1`).
Then, **in a second terminal**: `ssh admin@HOST sudo -n true`. Only when that works,
close the first.

A copy is kept at `/usr/share/cmesh-byol/hardening`, so later re-runs are just
`cmesh-byol-harden` after editing a file there. `cmesh-byol-harden --status` reports
every control without changing anything.

### What the script cannot do for you

- **Secure Boot.** The TPM seal is bound to PCR 7 only. With Secure Boot off, PCR 7 is
  the same for any OS booted on the machine, so the encryption protects a pulled drive
  but not the box itself. Check `bootctl status`; the fix is your own Secure Boot keys
  (sbctl), a signed unified kernel image, and binding to PCRs 7+11.
- **Logs off the box.** Local retention is bounded by the 8 GiB root. Ship the journal
  (`systemd-journal-upload`, or any collector) to storage you control, with the
  retention your policy names. The audit log is the record an auditor asks for.
- **SSH source addresses**, the PHI paths in `60-cmesh-phi.rules`, and alert delivery in
  `cmesh-alert` are placeholders until you fill them in.
- **Backups**, a Business Associate Agreement with the provider, the risk analysis, and
  access reviews — paperwork, not packages.

## Backing up the LUKS headers

Losing a header loses that disk, even with the passphrase and intact data. There are two
independent headers here (that is the point of LUKS-under-RAID), but neither is
recoverable from the other.

`cryptsetup luksHeaderBackup` is **LUKS1-only**. For LUKS2 there is no supported
equivalent, so copy the header and keyslot area directly. Measured: the keyslot area is
`16744448` bytes at offset `32768`, payload at `16777216` (16 MiB), and that size is
fixed — it does not scale with the device, so 32 MiB covers it:

```bash
for p in $(blkid -o device -t TYPE=crypto_LUKS); do
    dd if="$p" of="/root/luks-header-$(basename "$p").img" bs=1M count=32
done
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

## License

[MIT](LICENSE) © 2026 Consumer Mesh, LLC.

Note that this repository builds a Linux image and pulls packages from the Arch Linux
repositories at build time. Nothing here changes the licensing of those components; the
MIT grant covers this repository's own scripts and documentation. OVH's
[bringyourownlinux](https://github.com/ovh/bringyourownlinux) is a separate work under
its own terms.

# Stage 1: persistent user rootfs and independent init — QEMU prototype

**Status:** QEMU-only prototype with passing **explicit two-boot and inner-sudo serial assertions**; **not enabled** by installed Veyra or Live ISO. Evidence: [GitHub Actions #39308745394](https://github.com/angyedz/Veyra-Linux/actions/runs/39308988112).
This prototype is stacked on [Stage 0](DUAL-ENVIRONMENT.md) in PR #8.
Track product requirements and future steps in [ROADMAP.md](ROADMAP.md).

## What is being tested

```text
QEMU VM kernel (one kernel)
  |
  +-- System-side /init and test-only C supervisor (initial namespaces)
  |     +-- owns /dev/vda virtual disk, ext4 mount, mapping policy
  |     +-- maps inner UIDs 0..65535 -> outer UIDs 100000..165535
  |     +-- starts and supervises a separate user-environment init
  |
  +-- User environment (new user/PID/mount/net/IPC/UTS namespaces)
        +-- persistent ext4 rootfs, pivot_root, fresh procfs and run/tmp
        +-- /sbin/init (BusyBox PID 1 in **user PID namespace**)
             +-- /sbin/openrc sysinit / boot / default
                  +-- test-only OpenRC service increments persistent boot-count
        +-- ordinary inner UID 1000 writes a home file
        +-- inner sudo elevates to namespace UID 0, outer UID **100000**
```

**Important distinction:** Alpine's default PID 1 is **BusyBox init**, which
invokes **OpenRC** to manage runlevels. Merely executing `/sbin/openrc`
does not make OpenRC the kernel PID 1. Veyra's architecture requires a
*separate init instance for each environment*, not necessarily an OpenRC
binary acting as the literal PID 1. The system still has its own init.

## Implementation artifacts

- `tests/stage1-user-supervisor.c` — **test-only** privileged system-side
  supervisor launched within a disposable QEMU guest; creates user/mount/PID/
  network/IPC/UTS namespaces, writes multi-ID UID/GID mappings, pivots into
  the disk-backed rootfs and starts its independent init. The outside root UID
  mapping is intentionally **100000**, never host UID 0. The unprivileged
  launcher first drops to outside UID 100000, creates a user namespace,
  receives the system supervisor's authorized 65536-ID UID/GID mappings,
  then starts its own PID 1. Unlike self-mapping, this privileged setup does
  not deny `setgroups`, so namespace-local sudo may change group vectors.
- `scripts/veyra-stage1-qemu-init.sh` — disposable VM initial init that
  mounts the test rootfs and invokes the system-side supervisor.
- `tests/fixtures/stage1-user-inittab` and
  `tests/fixtures/stage1-user-openrc.initd` — minimal BusyBox PID 1 runlevels
  and a test service writing a durable boot counter. A private intermediate
  tmpfs root is used because `pivot_root` directly from initramfs `rootfs`
  returns EINVAL.
- `tests/test-stage1-user-openrc-qemu.py` — boots the *same disk image*
  twice, expects count 1 then 2 and checks inner UID 1000 file ownership.
- `.github/workflows/stage1-user-openrc-qemu.yml` — assembles disposable
  Alpine 3.22 userspace on an ext4 raw file with mkfs.ext4 -d, an Alpine LTS
  kernel and dedicated initramfs. No host disk partitions are modified.

## Acceptance gates for this prototype

- [x] Standalone C supervisor builds statically with `-Werror`.
- [x] First QEMU boot loads its user disk and launches BusyBox PID 1 within the
      user PID namespace, with independent OpenRC runlevels.
- [x] Inside UID 0 is mapped to outside **100000**; inside UID 1000 to
      outside **101000**, and the inner user successfully writes to `/home`.
- [x] The OpenRC test service writes boot-count 1, syncs, and the outer system
      reports readiness with an isolated rootfs.
- [x] A second QEMU boot of the same raw disk reports boot-count **2** and
      preserves the normal user's home file.
- [x] A normal inner UID 1000 uses setuid `sudo` to obtain inner UID **0**; a root-owned proof file is mapped to outside UID **100000**, never outside UID 0. Authorized system-side GID mapping keeps inner `setgroups()` functional.
- [x] CI retains serial evidence for the QEMU test.

**Test evidence:** [successful QEMU Stage 1 OpenRC and sudo run](https://github.com/angyedz/Veyra-Linux/actions/runs/39308988112) recorded both boot counts and the mapped sudo proof. This validates the disposable prototype only.

None of these prove **production** host security. The prototype is only the first runnable milestone in Stage 1 of the full [roadmap](ROADMAP.md).

## Known limitations and security risks

This prototype deliberately has the following gaps:

1. It is **not the normal Veyra boot or login path**. It uses a guest-only
   privileged C supervisor, not a production reviewed system service.
2. OpenRC services may require carefully scoped `/dev`, `/sys`, cgroups,
   D-Bus, sockets, ptys, and host bridges in real desktop use. Here, the
   environment is deliberately offline and minimal. The virtual disk and
   its block device belong exclusively to the test system side.
3. The child inherits **serial console file descriptors** for diagnostic
   output; a real Veyra supervisor must sanitize inherited FDs and grant
   only narrowly reviewed communication endpoints.
4. The rootfs, UID mappings, storage permissions and mountpoint lifecycle
   must be made race-safe and non-escapable. Existing code is experimental.
5. **Normal interactive user login, password policy, vpkg and KDE** are *not* integrated. `sudo` is validated **only inside this controlled disposable guest**, with an explicit temporary NOPASSWD test rule. This is not a production sudo privilege policy or proof that user root cannot exploit a kernel vulnerability.
6. System-owned Plasma/KWin and user-side plasmashell/KRunner, session bus,
   graphics access, VPN traffic and A/B integration are separate future
   milestones. This demonstration has no physical network, no user VPN and
   no desktop.
7. The ext4 raw image is merely the **first test substrate**: Veyra's actual
   rootfs architecture remains filesystem-neutral (ext4, XFS, F2FS, Btrfs)
   and does not require a container image or filesystem snapshots.
8. The lifecycle and recovery design requires supervision, signal handling,
   user init health checks, persistence migration and recovery safeguards.

**Product rule:** never route the system KDE, physical networking, system
updates or boot control through user `sudo`. The nested user environment
must be independently recoverable.

# Stage 1: persistent user rootfs and independent init — QEMU prototype

**Status:** QEMU-only prototype; the lifecycle manager, structural rootfs validation and their new two-boot tests are the next incremental milestone. **Not enabled** by installed Veyra or Live ISO. The earlier separate-init and inner-sudo baseline passed in [GitHub Actions](https://github.com/angyedz/Veyra-Linux/actions/runs/39308988112).
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

- tests/stage1-user-supervisor.c — **test-only** system-side manager and
  namespace launcher. Its local start, status and stop commands use a
  root-owned Unix socket under system /run; it validates the persistent mount
  before each start, waits for OpenRC readiness, reaps the launcher to detect
  PID 1 crashes, and stops only that nested PID 1. It creates separate
  user/mount/PID/network/IPC/UTS namespaces and maps inner IDs 0..65535 to
  outer IDs 100000..165535. The unprivileged launcher creates its own user
  namespace before the system-side process installs the UID/GID maps. The
  manager socket is not mounted in the user rootfs.
- scripts/veyra-stage1-qemu-init.sh — disposable VM initial init that mounts
  the test rootfs, starts the manager and drives its lifecycle checks.
- tests/fixtures/stage1-user-inittab and
  tests/fixtures/stage1-user-openrc.initd — minimal BusyBox PID 1 runlevels
  and a test service writing a durable boot counter. A private intermediate
  tmpfs root is used because pivot_root directly from initramfs rootfs returns
  EINVAL.
- tests/test-stage1-user-openrc-qemu.py — boots the same disk image twice;
  in each guest boot it tests invalid rootfs ownership and extra setuid
  rejection, start/status/stop/restart, and forced PID 1 crash detection. Two
  nested starts per guest boot leave persistent counts 2 then 4.
- .github/workflows/stage1-user-openrc-qemu.yml — builds a disposable Alpine
  3.22 rootfs on an ext4 raw file, assigns the ext4 root inode to mapped UID/GID
  100000, then boots an Alpine LTS kernel and dedicated initramfs. No host disk
  partitions are modified.

## System-side lifecycle manager and rootfs checks

The QEMU system init starts one foreground manager in the initial namespaces.
System-side test commands send start, status or stop over
/run/veyra-user-manager/control.sock. Its parent directory is root-owned mode
0700; the socket is mode 0600, and the server accepts only peer UID 0 as seen
from the system's initial user namespace. The nested user rootfs does not
receive the system /run mount or this socket.

Start validates the stopped rootfs, creates the unprivileged namespace
launcher, installs the authorized multi-ID maps, and waits for the nested
OpenRC boot counter plus normal-user and mapped-sudo proofs. Status reports
the manager's current state. Stop sends SIGTERM to nested PID 1, then uses
SIGKILL after a bounded wait. The manager polls and reaps its launcher; an
unexpected exit becomes FAILED and remains visible until another start.
These commands are a QEMU-only management interface, not an installed service
or public API.

Before each start the validator requires the exact rootfs mountpoint to be a
separate non-volatile filesystem with no nested mountpoints. It opens the
mountpoint without following a symlink, checks the root inode and every
entry's UID/GID are inside the mapped range, caps traversal depth and entry
count, rejects unsupported device/special files, and allows only the six
expected character devices. The only allowed setuid file is the fixture's
mapped-root-owned /usr/bin/sudo. It also requires the Stage 1 format marker
and resolves /sbin/init and sudo inside the rootfs with openat2 root
resolution.

The QEMU harness injects an initial-namespace-root-owned file and an unexpected
setuid file, and requires both starts to fail before launching the user init.
It also injects a nested tmpfs mount and a block device. It then exercises
start, status, stop, restart and a forced nested PID 1 crash on each of two
guest boots using the same ext4 disk.

These checks are structural startup checks, not cryptographic authentication
of user data. The marker can be changed by anyone who can write the rootfs;
this prototype has no signed manifest, immutable rootfs, production mount
policy or protection against a shared-kernel vulnerability. The expected
namespace-local sudo rule is NOPASSWD only in this disposable fixture.

## Acceptance gates for this prototype

The earlier PR #9 baseline passed a static C build and QEMU checks for
separate PID 1, mapped UIDs, namespace-local sudo and persistent state. The
new manager and rootfs validator are not marked complete until their dedicated
workflow runs pass.

- [ ] Build the system-side manager statically with -Werror.
- [ ] Start, report running status, stop, report stopped status and restart
      the nested user environment in QEMU.
- [ ] Detect a forced nested PID 1 crash and report FAILED from the system
      side.
- [ ] Reject an unmapped initial-namespace-root-owned rootfs entry and an
      unexpected setuid file before launching user PID 1.
- [ ] Preserve the same disk across two QEMU guest boots; the two nested starts
      per guest boot must leave boot counts 2 then 4.
- [ ] Keep the existing inner UID 1000 and sudo proof mapped to outside UIDs
      101000 and 100000 respectively.
- [ ] Retain serial evidence for the manager and rootfs validation checks.

None of these prove **production** host security. This remains a disposable
prototype in Stage 1 of the full [roadmap](ROADMAP.md).

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
4. The new validator checks mount and ownership structure at start, but does
   not authenticate mutable user data or close every race on a hostile live
   filesystem. Production mount policy and the full storage lifecycle need
   a separate review.
5. **Normal interactive user login, password policy, vpkg and KDE** are *not* integrated. `sudo` is validated **only inside this controlled disposable guest**, with an explicit temporary NOPASSWD test rule. User-side sudo maps to outside UID 100000; it does not control the system-side manager. This does not prevent a shared-kernel exploit.
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

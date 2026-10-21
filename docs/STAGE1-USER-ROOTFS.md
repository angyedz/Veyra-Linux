# Stage 1: persistent user rootfs and independent init — QEMU prototype

**Status:** the trusted-stage rootfs binding and descriptor-hardening milestone **passed** in [two-boot QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39404374568) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39404374542). Review [PR #17](https://github.com/angyedz/Veyra-Linux/pull/17) additionally tests system OpenRC default-runlevel autostart, serial autologin as inner UID 1000, a private `devpts` instance, and `/run` isolation across two QEMU boots; [QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39561204413) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39561204499) pass. These remain test-only and are not enabled by installed Veyra or Live ISO. Earlier, the QEMU lifecycle and rootfs-validation milestone passed in [PR #10 QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323358) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323395). The [PR #11 manager-exit cleanup follow-up](https://github.com/angyedz/Veyra-Linux/pull/11) passed [QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056661) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056566). The [PR #12 rootfs launch validation follow-up](https://github.com/angyedz/Veyra-Linux/pull/12) passed [QEMU](https://github.com/angyedz/Veyra-Linux/actions/runs/39320831998) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39320831889), including both inode-comparator outcomes and rejection of an init symlink that points outside the user rootfs. **Not enabled** by installed Veyra or Live ISO; this remains a disposable prototype, not production security validation.
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
  PID 1 crashes, and stops only that nested PID 1. It retains the validated
  rootfs directory descriptor through launch, then checks the bind-mounted
  rootfs device/inode before pivoting; a mismatch aborts startup. A QEMU
  self-test exercises both same-directory and different-directory comparator
  results. On an unexpected manager
  exit, `PR_SET_PDEATHSIG` terminates the launcher; nested PID 1 also arms
  that signal against launcher exit. It creates separate
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
- PR #17 adds tests/fixtures/stage1-system-manager.initd to start the manager and user environment from the system OpenRC default runlevel, and tests/fixtures/stage1-user-autologin plus an inittab getty line to exercise no-password serial autologin as UID 1000. This is a disposable QEMU fixture, not an installed login configuration.
- tests/test-stage1-user-openrc-qemu.py — boots the same disk image twice;
  in each guest boot it tests invalid rootfs ownership and extra setuid
  rejection, an init symlink escape attempt, both inode identity outcomes,
  start/status/stop/restart, forced PID 1 crash detection, and
  cleanup after killing the system-side manager. Three nested starts per
  guest boot leave persistent counts 3 then 6.
- .github/workflows/stage1-user-openrc-qemu.yml — builds a disposable Alpine
  3.22 rootfs on an ext4 raw file, assigns the ext4 root inode to mapped UID/GID
  100000, then boots an Alpine LTS kernel and dedicated initramfs. No host disk
  partitions are modified.



## Test-only OpenRC autostart and serial autologin (PR #17)

The review-branch QEMU fixture installs a minimal Alpine system root with the test manager service enabled in OpenRC's default runlevel. That service starts the system-side manager, which starts the persistent ext4 user rootfs. The user namespace mounts a private `devpts` instance with `/dev/ptmx` routed to it; the user BusyBox init then starts a serial getty whose test login wrapper drops to inner UID 1000. The login and its namespace-local `sudo` cannot see a system-only `/run` marker or the manager control socket. `sudo` writes the same marker path into the private user `/run`, and the system checks its marker remains unchanged.

The same user-root disk is reused across two actual QEMU boots. Per boot, assertions cover the OpenRC autostart, the private `devpts` and `/run` boundary, user autologin, normal lifecycle, manager/PID 1 failure cleanup and service recovery; the persistent login counter advances from 1–5 on the first boot to 6–10 on the second. Evidence: [PR #17 QEMU workflow](https://github.com/angyedz/Veyra-Linux/actions/runs/39561204413) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39561204499).

This verifies the test fixture's service ordering and serial user-side login only. It does not install this OpenRC service, enable no-password login in Veyra, implement graphical authentication/session management, or provide production storage isolation or security review.

## System-side lifecycle manager and rootfs checks

The baseline QEMU system init starts one foreground manager in the initial namespaces. Review PR #17 replaces this manual startup in its disposable fixture with a system OpenRC default-runlevel service; that service also auto-starts the user environment and the test serial login. The installed system still has no production manager service or login path.
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
The follow-up change arms `PR_SET_PDEATHSIG` against an unexpected manager
exit, and nested PID 1 arms it against launcher exit. Terminating PID 1 in a
PID namespace terminates the remaining processes in that namespace. The
follow-up QEMU case kills the manager while a user environment is running,
checks that PID 1 exits, then restarts the manager and expects STOPPED. This
does not replace production service cgroup ownership or full crash recovery.
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

The QEMU harness injects an initial-namespace-root-owned file, an unexpected
setuid file, a nested tmpfs mount and a block device, and requires each start
to fail before launching user init. It then exercises start, status, stop,
restart and a forced nested PID 1 crash on each of two guest boots using the
same ext4 disk. The manager-death check starts a third environment and kills
the manager to verify cleanup, then restarts it and checks stale-socket
recovery. The [PR #10 QEMU run](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323358)
asserts counts 2 then 4 for the baseline. The [PR #11 QEMU run](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056661)
asserts persistent counts 3 then 6, including manager-death cleanup. The
[PR #12 QEMU run](https://github.com/angyedz/Veyra-Linux/actions/runs/39320831998)
retains those lifecycle checks and additionally exercises both outcomes of the
rootfs inode comparator and requires `openat2(RESOLVE_IN_ROOT)` to reject an
`/sbin/init` symlink targeting an existing system-side file; the
[integration run](https://github.com/angyedz/Veyra-Linux/actions/runs/39320831889)
passed on the same PR head.

These checks are structural startup checks, not cryptographic authentication
of user data. The marker can be changed by anyone who can write the rootfs;
this prototype has no signed manifest, immutable rootfs, production mount
policy or protection against a shared-kernel vulnerability. The expected
namespace-local sudo rule is NOPASSWD only in this disposable fixture.

## Acceptance gates for this prototype

The earlier PR #9 baseline passed a static C build and QEMU checks for
separate PID 1, mapped UIDs, namespace-local sudo and persistent state. The
PR #10 manager and rootfs checks passed in [QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323358)
and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39312323395). The PR #11 manager-exit cleanup follow-up passed [QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056661)
and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39318056566). The PR #12 rootfs launch follow-up passed [QEMU CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39320831998) and [integration CI](https://github.com/angyedz/Veyra-Linux/actions/runs/39320831889), exercising matching and mismatching inode comparator results.

- [x] Build the system-side manager statically with -Werror.
- [x] Start, report running status, stop, report stopped status and restart
      the nested user environment in QEMU.
- [x] Detect a forced nested PID 1 crash and report FAILED from the system
      side.
- [x] Terminate the system-side manager unexpectedly and verify its launcher
      and nested PID 1 stop; restart the manager and recover STOPPED.
- [x] Reject an unmapped initial-namespace-root-owned file, unexpected
      setuid file, nested mountpoint and block device before launching user PID 1.
- [x] Preserve the same disk across two QEMU guest boots; the three nested
      starts per guest boot leave counts 3 then 6, including manager-death
      cleanup.
- [x] Reject an `/sbin/init` symlink that would resolve to an existing file
      outside the rootfs with `openat2(RESOLVE_IN_ROOT)`.
- [x] Exercise matching and mismatching directory-identity results for the
      validated descriptor comparator; require a match before pivoting.
- [x] Keep the existing inner UID 1000 and sudo proof mapped to outside UIDs
      101000 and 100000 respectively.
- [x] Retain serial evidence for the manager and rootfs validation checks.
- [x] QEMU verify that replacing the rootfs mount name after descriptor
      pinning cannot redirect the bind mount (actual source-name swap fixture
      and a trusted system-side staged mount).
- [x] QEMU assert descriptor sanitizer preserves only approved FDs, and
      fails closed if a forbidden descriptor survives. The child closes all
      descriptors >=3 before running user code.

- [x] QEMU assert pidfd-based process signalling: a live child receives its
      signal and a pidfd referring to the reaped child rejects further
      signals with ESRCH. The Stage 1 manager must acquire a pidfd before
      reporting the user environment running, uses that handle for TERM/KILL,
      and closes it when the supervised launcher exits. A missing pidfd is a
      failed start, not a fallback to signalling a numeric PID.

**Recent evidence:** [QEMU Stage 1 CI run 39404374568](https://github.com/angyedz/Veyra-Linux/actions/runs/39404374568) recorded both clean guest boots, persistent counts 3 → 6 and manager crash recovery. The [integration CI run 39404374542](https://github.com/angyedz/Veyra-Linux/actions/runs/39404374542) passed. A preceding QEMU run exposed a guest shutdown race; the manager now refuses to signal initial-namespace PID 1 or its own PID and reports the signal target for diagnosis.

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
3. The QEMU supervisor now closes all system FDs >=3 in the launcher
   except strictly required launch channels, and closes all remaining FDs
   >=3 in nested PID 1 before executing user code. A regression self-test
   checks allowlisted and forbidden FDs. **Console FDs 0–2** are still
   inherited from the VM system for serial diagnostics and need explicitly
   controlled replacement in production.
4. The system-side manager uses its already-open validated directory FD
   (`/proc/self/fd/N`) to create a bind mount under a root-owned, non-writable
   staging parent. The unprivileged child binds this **system-controlled
   staging mount**, not the mutable original rootfs pathname. It verifies
   the directory inode before pivoting. A QEMU self-test replaces a bind
   mount's visible name and proves that a system-side FD bind still selects
   the original directory. This avoids trying to bind a privileged procfd
   directly from a less-privileged user namespace (which returned EINVAL
   in QEMU). The manager also keeps its validated FD during OpenRC readiness.
   **This mitigates pathname substitution**, not changes to content within
   a rootfs by another privileged writer. An unclean manager exit may leave
   the protected stage mount until the next start or VM reboot.
   Production storage policy and lifecycle still require review.
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


**PID lifecycle hardening:** `pidfd_open` and `pidfd_send_signal` require
a sufficiently recent Linux kernel (supported by the QEMU kernel in CI).
This is a test-only Stage 1 improvement and **does not** replace cgroup
service ownership, time-of-check synchronization, host security isolation,
or a production signal policy.

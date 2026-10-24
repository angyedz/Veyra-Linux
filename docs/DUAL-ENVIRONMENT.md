# Veyra dual-environment execution model

**Status:** architecture contract and experimental probes only. The installed
Veyra ISO does **not** yet launch the user environment described here.
See the [Development Roadmap](ROADMAP.md) for milestones and evidence gates.

This document complements ARCHITECTURE.md; it does not change the existing
Calamares/TUI installation or A/B boot process.

## Three independent concepts

1. **System environment:** system OpenRC PID 1, kernel, hardware, physical
   networking, GRUB, boot coordinator and protected A/B deployments.
2. **Persistent user environment:** one **shared** root filesystem and
   package database for ordinary Linux accounts, with its own OpenRC/PID 1
   inside separate user, mount, PID, network and IPC namespaces. Each account
   retains its own UID/GID, authenticated session and private `/home/LOGIN`.
   Users log directly into this environment, with no explicit enter command.
3. **Recovery:** independently booted minimal OS; not a third simultaneously
   running PID 1 during ordinary operation.

The system and user environments share one Linux kernel. A/B changes the
system deployment, not the persistent user environment.

**Resilience design (2026-10-20, not implemented):** a system OpenRC-owned [Veyra Guardian](VEYRA-RESILIENCE.md) must detect user-init/Plasma failures without depending on the user rootfs. A system-owned TTY and independently bootable [VRE](VEYRA-RECOVERY.md) provide fallback. [SnapCore](VEYRA-SNAPCORE.md) is a proposed block-level CoW user snapshot layer below ext4/XFS/F2FS, **not** directory copies or a Btrfs/LVM requirement. User-root and `/home` must be separately restorable; system A/B rollback must not implicitly touch them.

## System-root access boundary

A password-gated initial-system root console is a **separately authenticated**
system operation, not a shortcut through inner `sudo`. See
[System-root access bridge](VEYRA-ROOT-ACCESS.md) for the intended trusted
TTY/PAM flow and adversarial acceptance tests. No production host-root
broker is integrated into the normal Veyra session yet; the currently
available package prototype uses an obsolete per-account-root fixture.

## Privileges

A regular user is unprivileged **inside** the user environment. `sudo`
grants administrative privileges **inside that environment only**. UID 0
inside its user namespace must not map to privileged UID 0 in the initial
user namespace. No process in the user environment may have a writable
mount of the host root, A/B store, host /boot or EFI partition, host
configuration, or privileged host control sockets.

This must be an enforcement property of the kernel boundary, not a vpkg
package classification, command blacklist, sudo wrapper or convention.

**Do not expose** the host mount namespace, privileged Docker/container
sockets, host D-Bus system bus, host OpenRC controls, writable sysfs,
host /proc, raw block devices, unrestricted /dev, or host kernel-control
interfaces. Restrict capabilities, device access and privileged kernel
operations; audit namespace ownership, inherited file descriptors,
setuid helpers, IPC and any privileged cross-boundary API.

User namespaces alone are insufficient. Mount propagation must be private,
the environment root must not provide an escape to host filesystem mounts,
and every deliberate host service bridge must use a narrow authorization
policy. A container boundary cannot guarantee security against kernel
vulnerabilities; that is an explicit threat-model limitation.

## Networking and VPN

The host owns physical Wi-Fi/Ethernet and its routing, DNS and firewall.
The user environment owns a separate network namespace, connected through
a system-managed virtual link. The user environment can administer its
own routes, DNS, firewall and VPN with scoped CAP_NET_ADMIN; it must not
be able to change host routes, firewall, physical interfaces or DNS.

VPN clients (including OpenVPN and WireGuard) and their kill switches
affect **only user-environment traffic**. System updates and host
services never inherit the user VPN. The virtual link and forwarding
policy must be tested for DNS, IPv4/IPv6 and traffic leakage, and for
safe operation when the VPN fails. TUN device access must be scoped;
WireGuard kernel support comes from the system kernel.

## KDE-only platform and desktop execution

**Ownership is not execution location.** KDE Plasma is a fixed,
**system-managed component** of Veyra: system deployment owns KDE's
packages, KWin/compositor integration, graphics policy and their coherent
versions. These packages cannot be upgraded, uninstalled or replaced via
user `sudo` or `vpkg` acting inside the user environment.

**Runtime boundary:** `plasmashell`, KRunner (`krunner`) and all
ordinary desktop command launchers execute inside the **user environment**
with its user namespace, filesystem, processes, session bus and network.
These processes **must execute system-owned KDE binaries and plugins**
from a system-managed, **read-only** KDE runtime paired to the active
A/B system deployment. Read-only availability of KDE libraries and
executables does not grant the process host privileges. There must be
**no independent user-environment copy of Plasma, plasmashell, KRunner,
KDE Frameworks or desktop plugins** used by the supported Veyra session.

### Coherent KDE updates across the execution boundary

* A KDE update is a **system-deployment update**. Stage the complete
  compatible KDE desktop stack in the inactive A/B generation, including
  KWin, plasmashell, KRunner, KDE Frameworks, relevant Qt libraries,
  display integration, portals and system-managed plugins. Do not stage
  a new KWin with the previous generation's plasmashell.
* The system selects **exactly one KDE runtime for a booted system
  generation**. Mount this runtime read-only into the user environment.
  The user session launches its plasmashell, KRunner and desktop
  components from that selected runtime, **never from independently
  upgraded user-owned packages**.
* Pair plugin/module lookup, library search paths and D-Bus service
  activation with that exact runtime. Simply mounting a binary from the
  new generation while it loads incompatible libraries or plugins from
  mutable user `/usr` is **not acceptable**. An implementation must
  validate loader, Qt plugin and QML import paths for the whole session.
* A/B activation and rollback take effect at a **reboot** and spawn
  **fresh user session processes** from the new or restored system KDE
  runtime. Do not live-switch a runtime underneath an existing session.
  No stale KDE processes from the previous generation may be carried
  across a generation switch.
* User packages may provide **ordinary applications** (and optional,
  explicitly isolated user customizations), but user `sudo` cannot
  mutate the selected KDE runtime or change the supported session's
  system-owned binaries. No package-name bans: protection comes from
  the mounts, namespace and trusted launch policy. If a user installs
  another plasmashell into their own rootfs, it does not become the
  system-managed Veyra session.
* KDE runtime layout, mount composition, version-matching, rollback and
  plugin isolation are **not implemented yet**. Never enable default
  user-session startup until tests prove them.

The precise read-only runtime mountpoint is not yet finalized; any
provisional launcher path must not be treated as the ABI or security
contract.

For clarity: KDE Plasma is **not installed as user-owned packages**.
Damage to the user environment does not delete the system KDE
deployment. It can nevertheless break the user-side `plasmashell` or
KRunner process, requiring independent user-environment recovery.

### Alt+F2 / KRunner launch contract

KDE KRunner is a **separate executable** and may be activated using
`org.kde.krunner` on D-Bus. Therefore, putting `plasmashell` in the
user environment alone does **not** guarantee safe Alt+F2 behavior.

1. The system compositor/shortcut service may recognize Alt+F2, but
   must send at most a narrow **show KRunner** notification to the
   active user session. It must never receive or execute search text,
   shell command arguments, desktop-entry Exec lines or user-selected
   program names.
2. The **user** KRunner process and every runner/plugin run inside the
   user environment. D-Bus activation of `org.kde.krunner` must occur
   on the **user environment's private session bus**. The host must not
   expose a separately activatable privileged KRunner on the desktop
   user's shortcut path.
3. Program and shell execution, `.desktop` actions, URL/file handlers,
   terminal invocation, KIO application launching, portals and optional
   D-Bus runners must not offer alternate host-execution routes.
   Privileged host D-Bus, polkit, service-manager and command-execution
   endpoints are **deny by default**. Any narrow host integration
   undergoes a separate security review.
4. If user init, session bus or KRunner is unavailable, Alt+F2 **fails
   closed** rather than falling back to a host KRunner/host shell.
   The system can still present independent maintenance or recovery UI.
5. `sudo` issued from KRunner or Konsole is **user-environment sudo**,
   granting only user-environment root. No command-name blacklist,
   kernel-package blacklist or sudo-only workaround is a substitute
   for the namespace and kernel-resource boundaries.

`scripts/veyra-user-krunner.sh` is an **experimental fail-closed
process-launch check**, not a security boundary: it refuses obvious
host-side invocations and pins KRunner to the environment's local D-Bus
session socket. It is **not yet wired to shortcuts, session startup, or
the installer**. The real isolation comes from correct creation of the
environment namespaces, mounts, UID mappings and host service policy,
not from the script. Merely adding a wrapper cannot prevent direct
host-side execution.

**Same rules apply** to the Plasma application menu, task manager,
Konsole, Dolphin, desktop entries, opening documents, and any other
user-triggered launch path.

Other desktop environments are **not interchangeable supported
sessions** on installed Veyra. Installing their packages inside the
user environment cannot replace the system KDE session. Legacy
development installers still expose alternative desktops; removing
those legacy options and tests must be coordinated with the finished
KDE-only installation path, not silently inferred from this design.

Graphics, input, audio, Wayland, portals and D-Bus integration need
narrow, independently reviewed interfaces; exposing raw devices or
host control sockets defeats the boundary.

## Package management

The user environment has its own package state and a normal default
`vpkg install NAME` experience. Its root can install arbitrary package
files **inside that environment** without changing host deployments.
The installed system's vpkg must be independent of an installed apk
binary or libapk. Nix integration may invoke standalone Nix. System
deployment updates are a separate host-authorized transaction against
an inactive A/B generation, never implicit from user sudo.

## Current prototype limits and CI evidence

- `scripts/veyra-user-env-prototype.sh --check ROOTFS` checks only a canonical, unprivileged-owned rootfs layout. It refuses nested mounts. Its actual `unshare` launch uses **one UID mapping only** (inner UID 0 to outer nonroot UID), so it cannot provide an ordinary account plus `sudo` yet. It also does not set up the required OpenRC devices, networking or desktop. The host filesystem must never be treated as safely isolated based solely on this prototype.
- `tests/test-user-env-prototype.sh` exercises syntax and fail-closed negative cases plus non-destructive rootfs preflight on nonroot runners; it is not a QEMU boot test.
- `tests/probe-dual-environment.sh` returns **77 (SKIP)** when the runner blocks namespace creation and **1 (FAIL)** if invariants fail after namespace entry. CI reports a SKIP explicitly and must not interpret it as proof of a working user environment.
- The standalone **QEMU-only** `tests/userns-qemu-check.c`, `scripts/veyra-userns-qemu-init.sh`, `tests/test-userns-qemu.py` and `.github/workflows/userns-qemu.yml` boot Alpine's LTS kernel with an ephemeral initramfs, no disks and no NICs. A guest process drops to UID 1000, creates its user namespace, and an authorized guest parent configures UID/GID maps before the child proves inner UID 0, PID 1, network/mount/IPC separation and that it cannot read a 0600 root-owned guest file. This **passed in QEMU** in [GitHub Actions run 39301689815](https://github.com/angyedz/Veyra-Linux/actions/runs/39301689815). It does not boot OpenRC or exercise the production Veyra user rootfs; the QEMU parent mapping is a test-only supervisor.
- `scripts/veyra-user-krunner.sh` is not integrated into KDE. It checks for an isolated session bus and a provisional read-only system runtime, but cannot authenticate the runtime origin or prevent the user from overmounting their own view. Real system-controlled mount composition, loader/plugin pairing, privilege isolation and host-side launch policy remain open work.
- The real init arrangement (Alpine BusyBox init versus dedicated OpenRC init), multi-ID UID/GID mappings, inherited file descriptor cleanup, controlled host devices/services, runtime pairing and guest tests still require implementation.

## Implementation gates (none assumed complete)

- [ ] Define persistent rootfs layout, UID/GID mappings and state migration.
- [ ] Prove separate OpenRC init and PID 1 with unprivileged host mappings.
- [ ] Prove user sudo cannot write host root, A/B store, /boot or host sockets.
- [ ] Prove host networking stays unchanged under user VPN and kill switch.
- [ ] Prove system-owned KDE integration with user-executed plasmashell and private user D-Bus.
- [ ] Prove KDE A/B upgrade and rollback atomically switch the entire version-matched runtime (KWin, plasmashell, KRunner, Frameworks, Qt, plugins) with no stale binaries, modules or user-owned substitutes.
- [ ] Prove Alt+F2/KRunner, menu, desktop entries and all app launches never execute commands on the host; prove fail-closed behavior when user session is down.
- [ ] Prove arbitrary package installation changes only the user rootfs.
- [ ] Prove reboot and A/B rollback preserve user rootfs and services.
- [ ] Run adversarial isolation tests and document kernel threat model.

Do not enable this architecture in the installer until these gates pass.

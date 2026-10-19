# Veyra dual-environment execution model

**Status:** architecture contract and experimental probes only. The installed
Veyra ISO does **not** yet launch the user environment described here.

This document complements ARCHITECTURE.md; it does not change the existing
Calamares/TUI installation or A/B boot process.

## Three independent concepts

1. **System environment:** system OpenRC PID 1, kernel, hardware, physical
   networking, GRUB, boot coordinator and protected A/B deployments.
2. **Persistent user environment:** separate root filesystem, user namespace,
   mount namespace, PID namespace with its own PID 1 and OpenRC, network and
   IPC namespaces, package database, services and ordinary user accounts.
   Users log directly into this environment, with no explicit enter command.
3. **Recovery:** independently booted minimal OS; not a third simultaneously
   running PID 1 during ordinary operation.

The system and user environments share one Linux kernel. A/B changes the
system deployment, not the persistent user environment.

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

## KDE-only platform

KDE Plasma is the fixed Veyra desktop platform. The system owns the
supported graphics stack and launch contract; plasmashell runs in the
user environment. Installing another DE package or a kernel package
inside the user environment must not replace the system compositor
launch policy or active kernel. Do not special-case package names.
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

## Implementation gates (none assumed complete)

- [ ] Define persistent rootfs layout, UID/GID mappings and state migration.
- [ ] Prove separate OpenRC init and PID 1 with unprivileged host mappings.
- [ ] Prove user sudo cannot write host root, A/B store, /boot or host sockets.
- [ ] Prove host networking stays unchanged under user VPN and kill switch.
- [ ] Prove user KDE Plasma Wayland session and graphics/audio integration.
- [ ] Prove arbitrary package installation changes only the user rootfs.
- [ ] Prove reboot and A/B rollback preserve user rootfs and services.
- [ ] Run adversarial isolation tests and document kernel threat model.

Do not enable this architecture in the installer until these gates pass.

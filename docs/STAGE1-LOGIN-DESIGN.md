# Stage 1: production account and login design

**Status:** proposed design only; no installed dual-environment login or
production session manager is implemented. This contract is the next Stage 1
design step in the [roadmap](ROADMAP.md). It preserves the current installer
until the integrated acceptance gate passes.

## Goals

- Enroll a normal user identity on the system side, then start that user's own
  persistent Linux root after the system login path authenticates them.
- Keep the host password database, kernel, devices, boot state and system
  services outside every user root.
- Give each account its own root filesystem, mapped ID range and persistent
  home. Share one Linux kernel; do not share mutable root filesystems between
  accounts.
- Keep ordinary `sudo` inside the user's environment. A successful desktop or
  TTY login must never authorize system-root access.
- Make logout, process cleanup, storage errors and failed authentication
  fail closed and leave user data intact.

## Identity and enrollment

The system account name is the stable login identity. The system's configured
login authenticator owns password verification and its password verifier
remains in the system account database. Enrollment stores only the account
name, the assigned outer UID/GID range and the user-root/home locations in a
system-owned registry. It must not copy the system password, password hash,
authentication token or host `/etc/shadow` into the user root.

The system-side `veyra-account-registry resolve USER` operation is the
manager-facing eligibility and mapping lookup. It rechecks that the enrolled
system account is still active, has the same UID/GID, and has not gained host
`wheel`/`sudo` membership or direct sudo policy authorization. It returns the
system identity and reserved mapping base, but **does not authenticate a
login**. The session broker must obtain authentication from the configured
system PAM/login path and compare that trusted session identity with the
resolved UID/GID before opening the account's root.

The existing Calamares and TUI installers create a conventional system user.
That legacy path remains unchanged until the new profile can provision and
recover both environments. The production dual-environment profile must
enroll users through the system account mechanism, reserve a unique mapped ID
range for each account, and provision that account's root and home atomically
from trusted system-owned inputs. The registry and mapping allocator must be
root-owned, locked during updates, reject duplicate or overlapping ranges,
and recover cleanly after interruption. Removing an account must not silently
delete its root or home.

An account enrolled as an ordinary dual-environment user must not be in the
host `wheel` group, receive host `sudo` authorization, or retain a shell that
can run arbitrary commands in the system root. System administration remains
a separate role and session. Do not change the legacy installer's current
single-environment account policy until the replacement login profile passes
the integrated acceptance gate.

Inside each user root, the enrolled account has a normal inner UID (currently
1000 in the QEMU fixtures). The system maps that identity through that
account's reserved outer range. A root owned by Alice must never be mounted
for Bob. Writable user state, including `/home` and package state, lives
outside system A/B deployments and survives their rollback.

## Login and session handoff

SDDM or a system TTY login authenticates the account in the system
environment. Only after that succeeds may a system-owned session entry ask
the manager to start the corresponding user environment. The manager obtains
the account identity from a trusted system login/session context and validates
it against the enrolled registry; it does not trust a username, UID, path,
environment variable or command supplied by a process inside a user root.

The login password and verifier never cross the handoff. The system creates
the user/mount/PID/network/IPC namespaces, pins the validated user root and
home, installs the mapped IDs, applies device and capability policy, and
executes the user's session inside that environment. No host-root mount,
host `/run`, shadow database, service socket, raw device or reusable
authentication credential is inherited by user processes. The precise SDDM,
PAM/logind or equivalent session-broker interface remains an implementation
choice; it must provide a system-verifiable authenticated session identity,
not merely trust caller-supplied data or a world-accessible socket.

Until multiple concurrent sessions against one writable root are proven safe,
the system permits at most one active session per account. The manager owns a
cgroup or an equivalently reviewed process boundary for each session, closes
all unapproved file descriptors, stops the session on logout, waits for
processes to exit, and releases mounts only after they are no longer in use.
An unclean manager exit must be recoverable without deleting or reformatting
the user's root or home.

## System OpenRC manager

The installed system has one root-owned OpenRC service that starts the session
manager after the persistent user store is mounted and before SDDM or TTY
login becomes available. The service owns manager startup, per-session
supervision, stop/restart, cgroup cleanup, mount cleanup and diagnostics.
OpenRC service ordering must prevent a login from racing storage setup.

The manager's control endpoint exists only in the system environment under a
root-owned, non-user-writable runtime directory. User roots cannot see or open
it. The reviewed login/session broker is the only request path; it conveys a
validated identity and session lifetime, never a root shell, arbitrary host
command, password or host mount. A failed or stale request cannot leave a
session, mount or privileged descriptor behind.

## Passwords and inner `sudo`

The system login password is checked by the system authenticator and is not
readable from the user environment. User-side `sudo` authorizes work inside
that user's namespace only. Its production authentication policy must be
specified separately; it must not expose the system shadow database, reuse a
host-root authorization, or retain the fixtures' `NOPASSWD` rule. A separate
inner credential or a reviewed narrow authentication provider must be chosen
before enabling inner `sudo` in the installed profile.

The user-requested system-root bridge is a different operation. A normal
login session is not sufficient authorization: the system must perform a
fresh administrator-password check on a system-controlled trusted TTY/UI and
create a separate system-root session. The prompt, terminal I/O and privileged
session must remain outside the user root. That bridge stays disabled until
its separate Stage 2 threat model, adversarial tests and independent review
pass; see the [Dual Environment contract](DUAL-ENVIRONMENT.md).

## Fail-closed requirements

- Wrong, missing, expired or revoked system authentication cannot start a
  user session or a system-root session.
- An unenrolled account, duplicate ID range, incomplete root/home, unexpected
  mount, unsafe device, missing persistent store or stale manager state cannot
  start the user environment.
- A user session cannot read system credentials or control host mounts,
  services, boot files, devices, network state or other users' roots.
- User-side `sudo` can administer only that user's environment. It cannot
  reach the system manager's privileged control path.
- Failed start, logout, reboot and manager crash preserve the user root and
  home. Account removal never implies destructive storage removal.
- The shared-kernel limitation remains explicit; namespaces do not protect
  against a kernel vulnerability.

## Implementation gates

1. Specify account migration and inner-`sudo` credential policy; add the
   root-owned enrollment registry and atomic ID-range allocator. Prove an
   ordinary enrolled account has no host `wheel` or `sudo` path.
2. Implement a production system OpenRC manager and reviewed session-broker
   request path, with cgroup/process ownership and trusted root/home cleanup.
3. Prove enrolled-account authentication and logout through a system TTY in a
   clean installed QEMU system; do not use serial autologin.
4. Integrate SDDM only after the TTY flow passes. Prove the authenticated
   session starts the selected account root, launches a graphical session,
   shuts down cleanly and cannot obtain host `sudo` or host service access.
5. Repeat across two system boots and A/B rollback while checking separate
   user roots, `/home`, package state and recovery behavior.
6. Keep the feature disabled in the installer until these gates and an
   independent security review pass.

The existing PR #20–26 artifacts prove test fixtures only. They do not satisfy
these installed-system gates.

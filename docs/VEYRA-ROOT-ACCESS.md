# Veyra system-root access bridge

**Status: design contract plus an experimental managed-TTY request path.**
Draft package PR [#7](https://github.com/angyedz/veyra-pkgrepo/pull/7) adds a
system-only PAM profile, root-owned administrator allowlist, fixed per-session
request descriptor, and a system-manager path to the reserved `/dev/tty9`.
This first path is limited to managed local virtual-terminal sessions. It does
not provide a Plasma/Wayland request surface or system seat/session binding,
installed-image wiring, detached-descendant cleanup, or complete QEMU security
gates. Keep the console disabled until the full implementation passes the
acceptance gates below and receives independent security review.

Package source checks ([run 39770175510](https://github.com/angyedz/veyra-pkgrepo/actions/runs/39770175510)),
all 19 Alpine APK builds, and the session-manager QEMU job passed on package
head `a4099d7`. The QEMU log and serial artifact show that an unlisted account
cannot trigger the system-root console and that even an allowlisted account is
rejected when its session is on a serial TTY
([run 39770175564](https://github.com/angyedz/veyra-pkgrepo/actions/runs/39770175564),
[serial artifact](https://github.com/angyedz/veyra-pkgrepo/actions/runs/39770175564/artifacts/12422530539)).
This does not exercise successful VT9 activation or PAM password entry on that
VT. Installed-image behavior and the remaining adversarial bridge proof are
still open.

**Account-model correction (2026-10-22):** Veyra's target has one shared
user-environment root with multiple ordinary Linux accounts and separate
`/home/LOGIN` directories. The current package PR #6/#7 manager authenticates
outer system accounts and provisions a separate complete user root per
account; that session-manager architecture does not match the target and must
be redesigned before merging. The root bridge remains a separate system-root
authority: a request from a user-environment session must lead to a fresh
system-side PAM check on a trusted system console, while its request channel
cannot carry a command, password or privileged session I/O back into the shared
user environment. This prototype is not yet the accepted implementation of
that flow.

## Purpose and authority

The bridge gives a person already at the machine a deliberate route from a
Veyra user session to a root shell in the initial system environment. Normal
user-session processes and inner `sudo` remain confined to the one shared user
environment; inner root affects that environment and its accounts. The bridge
is a separate, freshly authenticated system-administration session, not a
namespace transition requested by a user process.

The target accepts one fixed request from an authenticated session in the
shared user environment. A system-owned manager binds it to the live session,
switches to a system-controlled trusted TTY, performs fresh system-side PAM
authentication against system-owned administrator policy, and starts the
fixed root console itself. A user's identity or password in the user
environment does not grant system-root access. There is no accepted
Plasma/Wayland request surface, seat/session binding, or graphical display
handoff yet; the package does not change `/etc/inittab` or install a getty on
VT9.

The current PR #7 implementation is only an experiment: its session manager
authenticates an outer system account before it launches a separate rootfs for
that account. This account/rootfs architecture does not match Veyra's shared
user environment and must be replaced before the bridge can be integrated.

The system administrator authenticates as an outer Linux account selected by
root-owned system policy. That policy is separate from ordinary dual-environment
account enrollment: an account that has host `wheel`/`sudo` authority must not
silently become an ordinary isolated account. A normal user's password by
itself never grants host-root access.

## Trusted flow

1. The system-owned session manager accepts a fixed request packet over a
   private descriptor associated with a live user-environment session. The
   user environment receives no broker path and cannot provide a username,
   command, path, environment, TTY number, extra descriptor, or credential.
   The manager must verify the active session and local TTY; authoritative
   seat/session binding remains unfinished.
2. The manager switches to its fixed, reserved initial-system VT9 and starts
   the console itself. The username/password prompt is rendered and read on
   this initial-system TTY, outside user namespaces and outside any
   client-controlled PTY or compositor surface. The manager returns to the
   previous VT after the console exits.
3. The system login process authenticates through a dedicated PAM service and
   checks account eligibility against current system-owned policy. It requires
   fresh authentication for each bridge session; an existing user-session
   grant is not accepted.
4. Only after both checks succeed, a small system-side launcher starts the
   fixed root login shell on that TTY in the initial mount, PID, user, and
   network namespaces. The launcher supplies a clean root-owned environment,
   fixed working directory and fixed shell, and closes every descriptor except
   standard input/output/error attached to the allocated TTY.
5. On logout, timeout, TTY disconnect, broker restart, or failed setup, the
   launcher terminates the session process group, closes the TTY, records the
   outcome, and returns the display to the user's session or a system-owned
   login screen.

PR #7 prototypes the fixed-action path and parts of steps 1–5 for a managed
local TTY, but its outer-account/per-account-root session model conflicts with
the shared-user-environment target. Its protocol and PAM console are
experimental components only. The branch must be redesigned and retested
before it can count as the Veyra bridge. Seat/session binding, desktop UI and
display integration, installed-image wiring, and cgroup cleanup for detached
descendants also remain unfinished.

The bridge may be requested from a user session, but the request is only a
fixed action relayed through a system-owned control surface. User-root
processes cannot connect directly to a privileged broker socket or choose the
action's parameters. They must never receive the administrator's password,
PAM conversation, one-use grant, root shell descriptors, or a host command
channel. A request must not switch to a root shell on the untrusted session's
PTY.

## Authentication and authorization

- Use a dedicated PAM service whose `auth` and `account` stacks use the system
  account database and enforce current account lock/expiry state.
- Require membership in a root-owned system-administrator policy. PR #7 uses
  `/etc/veyra/root-admins`, a root-owned mode `0600` file listing eligible
  system account names. User-environment account records and groups are never
  authoritative for system-root access. The enrollment and account-management
  UX remains open.
- Reject `root` direct login unless a separately reviewed policy explicitly
  enables it. The default route authenticates a named administrator and then
  enters the fixed root shell.
- Apply bounded retries, a delay or lockout policy, and a session timeout.
  PR #7 allows one attempt per launcher invocation, requests PAM failure delay,
  adds a delay after failed attempts, and expires a shell after 15 minutes
  without keyboard input. Fail closed if PAM, the policy source, the system
  TTY, or the audit sink is unavailable.
- Do not pass reusable passwords or tokens between the PAM frontend, user
  session, and broker. If an internal grant is needed, keep it system-side,
  single-use, short-lived, and bound to the authenticated process and allocated
  TTY.

## Boundary rules

- The authentication prompt and root shell use only a TTY allocated by the
  initial-system broker. User namespaces cannot open or replace it. PR #7
  currently pins the prototype to `/dev/tty9` and rejects non-initial UID/GID
  maps; it does not prove the installed image hides that TTY and host input
  devices from the user environment.
- Only a system-owned control component may contact the broker. The current
  managed-TTY path uses a private per-session descriptor and active-VT check;
  binding a request to authoritative seat/session state and rejecting stale or
  unassociated requests remains required.
- Accept only a fixed request enum. Ignore or reject extra protocol fields and
  never interpret user-controlled text as an executable, path, environment
  value, terminal device, or shell argument.
- The root launcher uses a fixed system shell and a minimal environment such
  as `HOME=/root`, `USER=root`, `LOGNAME=root`, and a fixed system `PATH`.
  It does not inherit the user session's `HOME`, `PATH`, `TERM`, locale,
  `LD_*`, D-Bus variables, working directory, capabilities, or file
  descriptors. `TERM` may be selected only from a small validated system list.
- The broker runs in the initial system namespaces. It does not join or mount
  anything from the user namespace and does not expose its control socket,
  credentials, or root TTY inside the user root.
- Each active bridge session is tracked by a system-owned supervisor or cgroup
  so logout and broker failure can terminate descendants, not just the shell.
- Concurrent requests are serialized or assigned separate fixed TTYs under a
  strict configured limit. The caller cannot choose which policy applies.

## Audit and failure behavior

Write root-owned records for request, authenticated system administrator,
initiating user-environment session identity, allocated TTY, start/end time,
result, and termination reason. Never log passwords,
PAM response values, grants, or user-supplied command text. PR #7 records
timestamped authentication and session outcomes in
`/var/log/veyra/root-bridge.log` and syslog; success is denied if the local
audit file is unavailable. Authentication failures are delayed and visible in
syslog. Its process-group cleanup is not a substitute for the required
system-owned cgroup/supervisor that terminates detached descendants.
Failed setup must leave no shell, session grant, open TTY, or root-owned child
process behind.

The bridge is local-console-only in its first version. Remote SSH, graphical
password prompts rendered by user Plasma, and forwarding the user's session
PTY into a host-root shell are out of scope.

## Required disposable-QEMU acceptance

- An ordinary enrolled account, a retired account, a locked/expired account,
  and an account outside the administrator policy cannot obtain a root TTY.
- Wrong credentials, stale PAM sessions, replayed grants, malformed requests,
  invalid TTY state, and unavailable PAM/policy/audit services fail closed.
- A permitted administrator must complete fresh system-side PAM
  reauthentication before the initial-system root TTY appears.
- Requests from a hostile user root cannot supply a command, path, environment,
  terminal, or descriptor; cannot read the prompt or grant; and cannot access
  the root TTY before authorization.
- A hostile session cannot open the broker socket directly, forge another
  session's request, or force repeated console switches with duplicate or stale
  requests.
- Logout, client disconnect, timeout, concurrent requests, and broker restart
  leave no root shell or descendant alive and restore the expected console.
- Audit records contain identity and outcome metadata but no secret material.
- The tests also prove ordinary inner `sudo` remains user-namespace-local and
  cannot reach this bridge's host-only control surface.

Passing these checks proves only the specified disposable guest scenario. It
does not replace review of PAM policy, terminal ownership, kernel attack
surface, service supervision, or the installed system's full threat model.
PR #7's local PAM/PTTY tests are preliminary component tests; they are not the
required adversarial QEMU or installed-image proof.

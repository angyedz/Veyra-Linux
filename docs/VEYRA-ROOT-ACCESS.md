# Veyra system-root access bridge

**Status: design contract only.** No broker, authentication profile, privileged
TTY service, installer wiring, or QEMU proof currently implements this
contract. The feature must remain disabled until its implementation passes the
acceptance gates below and receives independent security review.

## Purpose and authority

The bridge gives a person already at the machine a deliberate route from a
Veyra user session to a root shell in the initial system environment. Normal
user-session processes and inner `sudo` remain confined to that user's
namespaces. The bridge is an explicit, separately authenticated system
administration session; it is not a namespace transition requested by a user
process.

The system administrator authenticates as an outer Linux account selected by
root-owned system policy. That policy is separate from ordinary dual-environment
account enrollment: an account that has host `wheel`/`sudo` authority must not
silently become an ordinary isolated account. A normal user's password by
itself never grants host-root access.

## Trusted flow

1. The system-owned session broker accepts a request to open the fixed
   administration surface. The request carries no username, command, path,
   environment, TTY number, file descriptor, or credential.
2. The broker allocates a system-owned console TTY from its fixed policy and
   switches the local display to it. The username/password prompt is rendered
   and read on this initial-system TTY, outside user namespaces and outside any
   client-controlled PTY or compositor surface.
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

The bridge may be requested from a user session, but the user's process only
requests the fixed action. It must never receive the administrator's password,
PAM conversation, one-use grant, root shell descriptors, or a host command
channel. A request must not switch to a root shell on the untrusted session's
PTY.

## Authentication and authorization

- Use a dedicated PAM service whose `auth` and `account` stacks use the system
  account database and enforce current account lock/expiry state.
- Require membership in a root-owned system-administrator policy. The exact
  policy storage and account-management UX must be chosen during implementation;
  user-root files, groups, and environment are never authoritative.
- Reject `root` direct login unless a separately reviewed policy explicitly
  enables it. The default route authenticates a named administrator and then
  enters the fixed root shell.
- Apply bounded retries, a delay or lockout policy, and a session timeout.
  Fail closed if PAM, the policy source, the system TTY, or the audit sink is
  unavailable.
- Do not pass reusable passwords or tokens between the PAM frontend, user
  session, and broker. If an internal grant is needed, keep it system-side,
  single-use, short-lived, and bound to the authenticated process and allocated
  TTY.

## Boundary rules

- The authentication prompt and root shell use only a TTY allocated by the
  initial-system broker. User namespaces cannot open or replace it.
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

Write root-owned records for request, authenticated outer account, allocated
TTY, start/end time, result, and termination reason. Never log passwords,
PAM response values, grants, or user-supplied command text. Authentication
failures are rate-limited and visible in the system journal. Failed setup must
leave no shell, session grant, open TTY, or root-owned child process behind.

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
- Logout, client disconnect, timeout, concurrent requests, and broker restart
  leave no root shell or descendant alive and restore the expected console.
- Audit records contain identity and outcome metadata but no secret material.
- The tests also prove ordinary inner `sudo` remains user-namespace-local and
  cannot reach this bridge's host-only control surface.

Passing these checks proves only the specified disposable guest scenario. It
does not replace review of PAM policy, terminal ownership, kernel attack
surface, service supervision, or the installed system's full threat model.

/* Disposable QEMU-only namespace smoke test; NOT full Veyra isolation. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void die(const char *what) {
    fprintf(stderr, "VEYRA_USERNS_QEMU_FAIL: %s (%d: %s)\n",
            what, errno, strerror(errno));
    fflush(stderr);
    _exit(1);
}
static void write_map(const char *path, const char *contents) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) die(path);
    size_t length = strlen(contents);
    if (write(fd, contents, length) != (ssize_t)length) die("write mapping");
    if (close(fd) < 0) die("close mapping");
}
static void ns_link(const char *name, char *out, size_t size) {
    char path[80];
    if (snprintf(path, sizeof(path), "/proc/self/ns/%s", name) >= (int)sizeof(path))
        die("long namespace path");
    ssize_t result = readlink(path, out, size - 1);
    if (result < 0) die("namespace readlink");
    out[result] = '\0';
}
static void assert_other_ns(const char *name, const char *old) {
    char now[128];
    ns_link(name, now, sizeof(now));
    if (!strcmp(now, old)) die("namespace failed to isolate");
}
static void wait_ok(pid_t child) {
    int status = 0;
    if (waitpid(child, &status, 0) != child) die("waitpid");
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        die("child exited without success");
}
static void rootless(const char *user, const char *mnt, const char *net,
                     const char *ipc, const char *pidns) {
    if (setgroups(0, NULL) || setgid(1000) || setuid(1000))
        die("drop guest root");
    if (geteuid() != 1000) die("expected nonroot outside userns");
    if (unshare(CLONE_NEWUSER) < 0) die("unprivileged user namespace");
    /* Map namespace UID 0 first: before uid_map is populated, opening
     * procfs setgroups may fail with EACCES because the process owner is
     * unmapped. setgroups must still be set to "deny" before gid_map.
     */
    write_map("/proc/self/uid_map", "0 1000 1\n");
    write_map("/proc/self/setgroups", "deny\n");
    write_map("/proc/self/gid_map", "0 1000 1\n");
    if (geteuid() != 0 || getegid() != 0) die("inner root mapping");
    assert_other_ns("user", user);

    int fd = open("/root/veyra-host-secret", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) { close(fd); die("inner root read host secret"); }
    if (errno != EACCES && errno != EPERM) die("unexpected host secret error");

    if (unshare(CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWIPC | CLONE_NEWUTS) < 0)
        die("mount/network/ipc namespaces");
    assert_other_ns("mnt", mnt);
    assert_other_ns("net", net);
    assert_other_ns("ipc", ipc);
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0)
        die("private mount propagation");
    if (unshare(CLONE_NEWPID) < 0) die("PID namespace");
    pid_t child = fork();
    if (child < 0) die("fork inner PID1");
    if (!child) {
        if (getpid() != 1) die("child PID is not 1");
        assert_other_ns("pid", pidns);
        puts("VEYRA_USERNS_QEMU_CHILD_PASS: isolated inner root and PID1");
        fflush(stdout);
        _exit(0);
    }
    wait_ok(child);
}
int main(void) {
    if (geteuid() != 0) die("guest initializer must start as root");
    char user[128], mnt[128], net[128], ipc[128], pidns[128];
    ns_link("user", user, sizeof(user));
    ns_link("mnt", mnt, sizeof(mnt));
    ns_link("net", net, sizeof(net));
    ns_link("ipc", ipc, sizeof(ipc));
    ns_link("pid", pidns, sizeof(pidns));
    pid_t child = fork();
    if (child < 0) die("fork rootless user");
    if (!child) {
        rootless(user, mnt, net, ipc, pidns);
        _exit(0);
    }
    wait_ok(child);
    puts("VEYRA_USERNS_QEMU_PRIMITIVES_PASS");
    fflush(stdout);
    return 0;
}

/* Disposable QEMU Stage 1 user environment: separate PID1, mapped UIDs,
 * persistent Alpine rootfs and OpenRC. NOT a production isolation boundary.
 * The privileged process exists ONLY inside a disposable, isolated VM.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define OUTER_ROOT_UID 100000
#define INNER_NORMAL_UID 1000
#define OUTER_NORMAL_UID (OUTER_ROOT_UID + INNER_NORMAL_UID)

struct child_args {
    int ready_write;
    int proceed_read;
    int pid_write;
    const char *root;
};

static void die(const char *message) {
    fprintf(stderr, "VEYRA_STAGE1_FAILURE: %s (errno=%d: %s)\n",
            message, errno, strerror(errno));
    fflush(stderr);
    _exit(1);
}
static void write_text(int fd, const char *message) {
    size_t length = strlen(message);
    while (length) {
        ssize_t n = write(fd, message, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) die("writing user namespace mapping or pipe");
        message += (size_t)n;
        length -= (size_t)n;
    }
}
static void install_map(pid_t pid, const char *key, const char *value) {
    char path[128];
    if (snprintf(path, sizeof(path), "/proc/%ld/%s", (long)pid, key)
            >= (int)sizeof(path)) die("mapping path too long");
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd == -1) die(path);
    write_text(fd, value);
    if (close(fd) == -1) die("closing namespace map");
}
static void proof_ordinary_user(void) {
    pid_t pid = fork();
    if (pid < 0) die("fork inner ordinary user");
    if (!pid) {
        if (setgid(INNER_NORMAL_UID) || setuid(INNER_NORMAL_UID))
            die("switch to inner uid/gid 1000");
        if (geteuid() != INNER_NORMAL_UID) die("inner uid mismatch");
        int fd = open("/home/veyrauser/normal-user-proof",
                      O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) die("inner normal user cannot write home");
        write_text(fd, "inner-user-id=1000\n");
        if (close(fd) < 0) die("normal user proof close");
        _exit(0);
    }
    int status;
    if (waitpid(pid, &status, 0) != pid ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        die("ordinary user proof child failed");
}
static void inner_pid_one(const char *root) {
    if (geteuid() != 0 || getegid() != 0 || getpid() != 1)
        die("inner uid/gid or PID1 mismatch");
    if (sethostname("veyra-user", 10) < 0) die("namespace hostname");
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0)
        die("private propagation");
    if (mount(root, root, NULL, MS_BIND, NULL) < 0)
        die("bind user rootfs");
    if (chdir(root) < 0) die("enter user rootfs");
    if (mkdir(".veyra-stage1-oldroot", 0700) < 0 && errno != EEXIST)
        die("prepare old root");
    if (syscall(SYS_pivot_root, ".", ".veyra-stage1-oldroot") < 0)
        die("pivot root");
    if (chdir("/") < 0) die("chdir /");
    if (umount2("/.veyra-stage1-oldroot", MNT_DETACH) < 0)
        die("detach system mount tree");
    if (rmdir("/.veyra-stage1-oldroot") < 0) die("remove old root");
    if (mount("proc", "/proc", "proc", MS_NODEV | MS_NOSUID | MS_NOEXEC, "") < 0)
        die("mount fresh proc");
    if (mount("tmpfs", "/run", "tmpfs", MS_NODEV | MS_NOSUID, "mode=0755") < 0)
        die("mount isolated run");
    if (mount("tmpfs", "/tmp", "tmpfs", MS_NODEV | MS_NOSUID, "mode=1777") < 0)
        die("mount isolated tmp");
    proof_ordinary_user();
    printf("VEYRA_STAGE1_USER_PID1_STARTED: pid=%ld\n", (long)getpid());
    fflush(stdout);
    execl("/sbin/init", "init", (char *)NULL);
    die("execute user root BusyBox init");
}
/* Launching clone(CLONE_NEWUSER) directly as outer UID 0 leaves the
 * process outside-UID 0, which is UNMAPPED by 0->100000. We therefore
 * first create a separate unprivileged launcher (outside UID 100000),
 * let it create its own user namespace, have the trusted VM system root
 * install the mapping, then create other namespaces and fork PID1.
 */
static void launch_user(const struct child_args *ctx) {
    if (setgroups(0, NULL) < 0 ||
        setgid(OUTER_ROOT_UID) < 0 ||
        setuid(OUTER_ROOT_UID) < 0)
        die("drop guest system root for unprivileged launcher");
    if (geteuid() != OUTER_ROOT_UID) die("outside launcher remains privileged");
    if (unshare(CLONE_NEWUSER) < 0) die("unprivileged user namespace");
    write_text(ctx->ready_write, "R");
    close(ctx->ready_write);
    char signal = 0;
    if (read(ctx->proceed_read, &signal, 1) != 1 || signal != 'G')
        die("trusted system guest never installed UID/GID mappings");
    close(ctx->proceed_read);
    if (geteuid() != 0 || getegid() != 0)
        die("namespace root mapping did not become active");
    if (unshare(CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWIPC |
                CLONE_NEWUTS | CLONE_NEWPID) < 0)
        die("scoped mount/network/IPC/UTS/PID namespaces");
    pid_t pid1 = fork();
    if (pid1 < 0) die("fork nested PID1");
    if (pid1 == 0) {
        close(ctx->pid_write);
        inner_pid_one(ctx->root);
    }
    char child_pid[48];
    if (snprintf(child_pid, sizeof(child_pid), "%ld\n", (long)pid1)
            >= (int)sizeof(child_pid)) die("PID string too long");
    write_text(ctx->pid_write, child_pid);
    close(ctx->pid_write);
    int status = 0;
    if (waitpid(pid1, &status, 0) != pid1) die("reap nested user PID1");
    _exit(0);
}
static int root_boot_count(const char *root) {
    char path[512];
    if (snprintf(path, sizeof(path), "%s/var/lib/veyra-user/boot-count", root)
            >= (int)sizeof(path)) die("boot count path too long");
    FILE *file = fopen(path, "r");
    if (!file) return -1;
    int value = -1;
    if (fscanf(file, "%d", &value) != 1) value = -1;
    fclose(file);
    return value;
}
int main(int argc, char **argv) {
    if (geteuid() != 0 || argc != 3)
        die("guest system supervisor requires ROOTFS EXPECTED_COUNT");
    char *end;
    long expected = strtol(argv[2], &end, 10);
    if (*end || expected < 1 || expected > 10)
        die("expected count must be 1..10");
    struct stat st;
    if (stat(argv[1], &st) < 0 || !S_ISDIR(st.st_mode))
        die("prepared rootfs directory missing");
    /* mkfs.ext4 -d copies all child ownership, but initializes ext4 inode 2
     * as system-root-owned. Only the trusted guest supervisor provisions
     * that single root inode before letting user-namespace PID1 start.
     */
    if (st.st_uid == 0) {
        if (chown(argv[1], OUTER_ROOT_UID, OUTER_ROOT_UID) < 0)
            die("provision persistent ext4 root inode owner");
        if (stat(argv[1], &st) < 0) die("restat user root inode");
    }
    if (st.st_uid != OUTER_ROOT_UID)
        die("rootfs owner must map to outside UID 100000");
    int ready[2], proceed[2], child_pid_pipe[2];
    if (pipe(ready) < 0 || pipe(proceed) < 0 ||
        pipe(child_pid_pipe) < 0) die("namespace synchronization pipes");
    pid_t launcher = fork();
    if (launcher < 0) die("create unprivileged namespace launcher");
    if (launcher == 0) {
        close(ready[0]);
        close(proceed[1]);
        close(child_pid_pipe[0]);
        struct child_args args = {
            .ready_write = ready[1], .proceed_read = proceed[0],
            .pid_write = child_pid_pipe[1], .root = argv[1],
        };
        launch_user(&args);
        _exit(1);
    }
    close(ready[1]);
    close(proceed[0]);
    close(child_pid_pipe[1]);
    char ready_byte = 0;
    if (read(ready[0], &ready_byte, 1) != 1 || ready_byte != 'R')
        die("unprivileged child failed before namespace mapping");
    close(ready[0]);
    /* Only VM system root configures namespace UID/GID ranges. */
    install_map(launcher, "uid_map", "0 100000 65536\n");
    install_map(launcher, "setgroups", "deny\n");
    install_map(launcher, "gid_map", "0 100000 65536\n");
    write_text(proceed[1], "G");
    close(proceed[1]);

    char child_pid_text[48] = {0};
    ssize_t bytes = read(child_pid_pipe[0], child_pid_text,
                         sizeof(child_pid_text) - 1);
    close(child_pid_pipe[0]);
    if (bytes <= 0) die("namespace launcher did not create user PID1");
    char *parse_end = NULL;
    long child_pid_number = strtol(child_pid_text, &parse_end, 10);
    if (parse_end == child_pid_text || child_pid_number <= 0)
        die("invalid nested PID1 number");
    pid_t child = (pid_t)child_pid_number;
    int actual = -1;
    for (int tick = 0; tick < 240; tick++) {
        actual = root_boot_count(argv[1]);
        if (actual == expected) break;
        if (actual > expected) die("boot count exceeded expected value");
        int status;
        pid_t result = waitpid(launcher, &status, WNOHANG);
        if (result < 0) die("wait namespace launcher");
        if (result == launcher) die("user PID1 exited before OpenRC startup");
        usleep(250000);
    }
    if (actual != expected) die("OpenRC did not signal expected boot count");
    char proof[512];
    if (snprintf(proof, sizeof(proof), "%s/home/veyrauser/normal-user-proof",
                 argv[1]) >= (int)sizeof(proof)) die("proof path overflow");
    if (stat(proof, &st) < 0 || st.st_uid != OUTER_NORMAL_UID)
        die("normal user proof is not mapped to outside UID 101000");
    printf("VEYRA_STAGE1_USER_OPENRC_READY count=%d outside-normal-uid=%u\n",
           actual, (unsigned)st.st_uid);
    fflush(stdout);
    sync();
    puts("VEYRA_STAGE1_USER_STATE_SYNCED");
    fflush(stdout);
    if (kill(child, SIGKILL) < 0) die("stop only nested PID1");
    if (waitpid(launcher, NULL, 0) != launcher)
        die("reap namespace launcher");
    return 0;
}

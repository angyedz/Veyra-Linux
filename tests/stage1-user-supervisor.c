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

#define STACK_SIZE (1024 * 1024)
#define OUTER_ROOT_UID 100000
#define INNER_NORMAL_UID 1000
#define OUTER_NORMAL_UID (OUTER_ROOT_UID + INNER_NORMAL_UID)

struct child_args { int read_fd; int write_fd; const char *root; };

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
static int inner_init(void *opaque) {
    struct child_args *ctx = opaque;
    char signal = 0;
    close(ctx->write_fd);
    if (read(ctx->read_fd, &signal, 1) != 1 || signal != 'G')
        die("trusted guest supervisor did not install mappings");
    close(ctx->read_fd);
    if (geteuid() != 0 || getegid() != 0 || getpid() != 1)
        die("inner uid/gid or PID1 mismatch");
    if (sethostname("veyra-user", 10) < 0) die("namespace hostname");
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0)
        die("private propagation");
    if (mount(ctx->root, ctx->root, NULL, MS_BIND, NULL) < 0)
        die("bind user rootfs");
    if (chdir(ctx->root) < 0) die("enter user rootfs");
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
    return 1;
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
    if (stat(argv[1], &st) < 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != OUTER_ROOT_UID) die("rootfs owner must be outside UID 100000");
    int pipe_fd[2];
    if (pipe(pipe_fd) < 0) die("namespace mapping pipe");
    void *stack = malloc(STACK_SIZE);
    if (!stack) die("allocate child stack");
    struct child_args ctx = {
        .read_fd = pipe_fd[0], .write_fd = pipe_fd[1], .root = argv[1],
    };
    int flags = CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNS |
                CLONE_NEWNET | CLONE_NEWIPC | CLONE_NEWUTS | SIGCHLD;
    pid_t child = clone(inner_init, (char *)stack + STACK_SIZE, flags, &ctx);
    if (child < 0) die("clone nested PID1/user namespace");
    close(pipe_fd[0]);
    /* The only authority mapping guest user UIDs is guest system root. */
    install_map(child, "uid_map", "0 100000 65536\n");
    install_map(child, "setgroups", "deny\n");
    install_map(child, "gid_map", "0 100000 65536\n");
    write_text(pipe_fd[1], "G");
    close(pipe_fd[1]);

    int actual = -1;
    for (int tick = 0; tick < 240; tick++) {
        actual = root_boot_count(argv[1]);
        if (actual == expected) break;
        if (actual > expected) die("boot count exceeded expected value");
        int status;
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result < 0) die("wait user PID1");
        if (result == child) die("user PID1 exited before OpenRC startup");
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
    if (waitpid(child, NULL, 0) != child) die("reap nested PID1");
    free(stack);
    return 0;
}

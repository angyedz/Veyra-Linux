/* Disposable QEMU Stage 1 system-side user-environment manager.
 * Test harness only: this is not a production host security boundary.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <stdint.h>
#include <linux/magic.h>
#include <linux/openat2.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define ROOT_PATH "/mnt/veyra-user"
#define RUN_DIR "/run/veyra-user-manager"
#define SOCKET_PATH RUN_DIR "/control.sock"
/* Root-owned (0711) staging parent: the namespace user can traverse
 * but cannot change the mount name. The initial-namespace manager
 * mounts the already-validated directory FD here before fork.
 */
#define PIN_PARENT "/run/veyra-user-rootfs-pin"
#define PIN_PATH PIN_PARENT "/rootfs"
#define OUTER_ROOT_UID 100000U
#define OUTER_NORMAL_UID 101000U
#define MAPPED_ID_LIMIT 165536U
#define MAX_TREE_ENTRIES 100000U
#define START_TIMEOUT_MS 90000
#define STOP_TIMEOUT_MS 5000

enum manager_state { STATE_STOPPED, STATE_STARTING, STATE_RUNNING,
                     STATE_STOPPING, STATE_FAILED };
struct child_args {
    int ready_write, proceed_read, pid_write;
    int root_fd;
    pid_t expected_parent;
};
struct scan_state {
    dev_t device;
    unsigned entries;
    char *error;
    size_t error_size;
};
static int listener_fd = -1;
static int client_fd = -1;
static volatile sig_atomic_t terminate_requested;
static enum manager_state state = STATE_STOPPED;
static pid_t launcher_pid;
static pid_t user_pid1;
/* Stable kernel process handle: do not signal a recycled numeric PID. */
static int user_pidfd = -1;
static int last_exit_code = -1;
static int boot_count;

static void set_error(char *error, size_t size, const char *message) {
    if (size) snprintf(error, size, "%s", message);
}
static void route_test_manager_stderr_to_console(void) {
    int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    if (dup2(fd, STDERR_FILENO) < 0) {
        close(fd);
        return;
    }
    close(fd);
}
static void die(const char *message) {
    int saved_errno = errno;
    int console_fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (console_fd >= 0) {
        dprintf(console_fd, "VEYRA_STAGE1_FAILURE: %s (errno=%d: %s)\n",
                message, saved_errno, strerror(saved_errno));
        close(console_fd);
    }
    errno = saved_errno;
    fprintf(stderr, "VEYRA_STAGE1_FAILURE: %s (errno=%d: %s)\n",
            message, saved_errno, strerror(saved_errno));
    fflush(stderr);
    _exit(1);
}
static int write_all(int fd, const void *buffer, size_t length) {
    const char *p = buffer;
    while (length) {
        ssize_t n = write(fd, p, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        length -= (size_t)n;
    }
    return 0;
}
static void write_text(int fd, const char *message) {
    if (write_all(fd, message, strlen(message)) < 0)
        die("write namespace mapping or synchronization pipe");
}
static int read_one_timeout(int fd, char *value, int timeout_ms) {
    struct pollfd item = { .fd = fd, .events = POLLIN };
    int result;
    do { result = poll(&item, 1, timeout_ms); } while (result < 0 && errno == EINTR);
    if (result <= 0) return -1;
    ssize_t n;
    do { n = read(fd, value, 1); } while (n < 0 && errno == EINTR);
    return n == 1 ? 0 : -1;
}
static void install_map(pid_t pid, const char *key, const char *value) {
    char path[128];
    if (snprintf(path, sizeof(path), "/proc/%ld/%s", (long)pid, key)
        >= (int)sizeof(path)) die("mapping path too long");
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) die(path);
    write_text(fd, value);
    if (close(fd) < 0) die("close namespace map");
}
static int open_in_root(int rootfd, const char *path, int flags) {
    struct open_how how = {
        .flags = (unsigned long long)(flags | O_CLOEXEC),
        .resolve = RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS,
    };
    return (int)syscall(SYS_openat2, rootfd, path, &how, sizeof(how));
}
static int valid_owner(const struct stat *st) {
    return st->st_uid >= OUTER_ROOT_UID && st->st_uid < MAPPED_ID_LIMIT &&
           st->st_gid >= OUTER_ROOT_UID && st->st_gid < MAPPED_ID_LIMIT;
}
static int safe_device(const char *path, const struct stat *st) {
    if (!S_ISCHR(st->st_mode)) return 0;
    if (!strcmp(path, "dev/console")) return major(st->st_rdev) == 5 && minor(st->st_rdev) == 1;
    if (!strcmp(path, "dev/null")) return major(st->st_rdev) == 1 && minor(st->st_rdev) == 3;
    if (!strcmp(path, "dev/zero")) return major(st->st_rdev) == 1 && minor(st->st_rdev) == 5;
    if (!strcmp(path, "dev/tty")) return major(st->st_rdev) == 5 && minor(st->st_rdev) == 0;
    if (!strcmp(path, "dev/random")) return major(st->st_rdev) == 1 && minor(st->st_rdev) == 8;
    if (!strcmp(path, "dev/urandom")) return major(st->st_rdev) == 1 && minor(st->st_rdev) == 9;
    return 0;
}
static int scan_directory(int fd, const char *parent, int depth,
                          struct scan_state *scan) {
    if (depth > 64) {
        set_error(scan->error, scan->error_size, "rootfs directory nesting exceeds 64");
        return -1;
    }
    DIR *dir = fdopendir(dup(fd));
    if (!dir) {
        set_error(scan->error, scan->error_size, "cannot enumerate rootfs directory");
        return -1;
    }
    struct dirent *entry;
    for (;;) {
        errno = 0;
        entry = readdir(dir);
        if (!entry) {
            if (errno) {
                set_error(scan->error, scan->error_size, "error while enumerating rootfs");
                closedir(dir);
                return -1;
            }
            break;
        }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (++scan->entries > MAX_TREE_ENTRIES) {
            set_error(scan->error, scan->error_size, "rootfs contains too many entries");
            closedir(dir);
            return -1;
        }
        char path[PATH_MAX];
        int n = parent[0]
            ? snprintf(path, sizeof(path), "%s/%s", parent, entry->d_name)
            : snprintf(path, sizeof(path), "%s", entry->d_name);
        if (n < 0 || n >= (int)sizeof(path)) {
            set_error(scan->error, scan->error_size, "rootfs path exceeds PATH_MAX");
            closedir(dir);
            return -1;
        }
        struct stat st;
        if (fstatat(dirfd(dir), entry->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0) {
            set_error(scan->error, scan->error_size, "rootfs changed during validation");
            closedir(dir);
            return -1;
        }
        if (!valid_owner(&st)) {
            snprintf(scan->error, scan->error_size,
                     "rootfs entry owner lies outside mapped UID/GID range: %s uid=%lu gid=%lu",
                     path, (unsigned long)st.st_uid, (unsigned long)st.st_gid);
            closedir(dir);
            return -1;
        }
        if (st.st_dev != scan->device) {
            set_error(scan->error, scan->error_size, "nested filesystem in user rootfs");
            closedir(dir);
            return -1;
        }
        if (S_ISDIR(st.st_mode)) {
            int child = openat(dirfd(dir), entry->d_name,
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0 || scan_directory(child, path, depth + 1, scan) < 0) {
                if (child >= 0) close(child);
                closedir(dir);
                return -1;
            }
            close(child);
            continue;
        }
        if (S_ISREG(st.st_mode) || S_ISLNK(st.st_mode)) {
            if (st.st_mode & (S_ISUID | S_ISGID)) {
                if (strcmp(path, "usr/bin/sudo") || !S_ISREG(st.st_mode) ||
                    st.st_uid != OUTER_ROOT_UID ||
                    (st.st_mode & 07777) != 04755) {
                    set_error(scan->error, scan->error_size,
                              "unexpected setuid/setgid file in user rootfs");
                    closedir(dir);
                    return -1;
                }
            }
            continue;
        }
        if (safe_device(path, &st)) continue;
        set_error(scan->error, scan->error_size,
                  "unsupported special file or device in user rootfs");
        closedir(dir);
        return -1;
    }
    closedir(dir);
    return 0;
}
static int check_mount_table(char *error, size_t error_size) {
    FILE *mounts = fopen("/proc/self/mountinfo", "r");
    if (!mounts) {
        set_error(error, error_size, "cannot read mount table");
        return -1;
    }
    char *line = NULL;
    size_t capacity = 0;
    int exact = 0, nested = 0;
    while (getline(&line, &capacity, mounts) >= 0) {
        char *save = NULL, *field = NULL;
        for (int index = 0; index < 5; index++) {
            field = strtok_r(index == 0 ? line : NULL, " ", &save);
            if (!field) break;
        }
        if (!field) continue;
        size_t root_len = strlen(ROOT_PATH);
        if (!strcmp(field, ROOT_PATH)) exact++;
        else if (!strncmp(field, ROOT_PATH, root_len) && field[root_len] == '/')
            nested++;
    }
    free(line);
    fclose(mounts);
    if (exact != 1 || nested) {
        set_error(error, error_size, "rootfs must be one mount with no child mounts");
        return -1;
    }
    return 0;
}
static int validate_rootfs(int *rootfd_out, char *error, size_t error_size) {
    struct stat path_st, parent_st, root_st;
    struct statfs fs;
    if (lstat(ROOT_PATH, &path_st) < 0 || !S_ISDIR(path_st.st_mode)) {
        set_error(error, error_size, "persistent rootfs mountpoint is missing or not a directory");
        return -1;
    }
    int parentfd = open("/mnt", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parentfd < 0 || fstat(parentfd, &parent_st) < 0) {
        if (parentfd >= 0) close(parentfd);
        set_error(error, error_size, "cannot inspect rootfs mount parent");
        return -1;
    }
    close(parentfd);
    int rootfd = open(ROOT_PATH, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (rootfd < 0 || fstat(rootfd, &root_st) < 0 || fstatfs(rootfd, &fs) < 0) {
        if (rootfd >= 0) close(rootfd);
        set_error(error, error_size, "cannot open persistent rootfs safely");
        return -1;
    }
    if (root_st.st_dev == parent_st.st_dev ||
        fs.f_type == TMPFS_MAGIC || fs.f_type == RAMFS_MAGIC) {
        close(rootfd);
        set_error(error, error_size, "user rootfs is not on a separate persistent filesystem");
        return -1;
    }
    if (root_st.st_uid != OUTER_ROOT_UID || root_st.st_gid != OUTER_ROOT_UID ||
        (root_st.st_mode & 0022)) {
        close(rootfd);
        set_error(error, error_size, "rootfs inode must be mapped root-owned and not group/world writable");
        return -1;
    }
    if (check_mount_table(error, error_size) < 0) {
        close(rootfd);
        return -1;
    }
    struct scan_state scan = {
        .device = root_st.st_dev, .entries = 0, .error = error,
        .error_size = error_size,
    };
    if (scan_directory(rootfd, "", 0, &scan) < 0) {
        close(rootfd);
        return -1;
    }
    int marker = openat(rootfd, ".veyra-stage1-rootfs", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    char marker_text[32] = {0};
    ssize_t marker_len = marker >= 0 ? read(marker, marker_text, sizeof(marker_text) - 1) : -1;
    if (marker >= 0) close(marker);
    if (marker_len != 14 || memcmp(marker_text, "format=stage1\n", 14)) {
        close(rootfd);
        set_error(error, error_size, "rootfs format marker is missing or invalid");
        return -1;
    }
    int initfd = open_in_root(rootfd, "sbin/init", O_PATH);
    struct stat init_st;
    if (initfd < 0 || fstat(initfd, &init_st) < 0 ||
        !S_ISREG(init_st.st_mode) || !(init_st.st_mode & 0111)) {
        if (initfd >= 0) close(initfd);
        close(rootfd);
        set_error(error, error_size, "rootfs does not contain an executable /sbin/init");
        return -1;
    }
    close(initfd);
    int sudofd = open_in_root(rootfd, "usr/bin/sudo", O_PATH);
    struct stat sudo_st;
    if (sudofd < 0 || fstat(sudofd, &sudo_st) < 0 ||
        !S_ISREG(sudo_st.st_mode) || sudo_st.st_uid != OUTER_ROOT_UID ||
        (sudo_st.st_mode & 04755) != 04755) {
        if (sudofd >= 0) close(sudofd);
        close(rootfd);
        set_error(error, error_size, "rootfs test sudo is not mapped-root-owned setuid");
        return -1;
    }
    close(sudofd);
    *rootfd_out = rootfd;
    return 0;
}
static int read_boot_count(int rootfd) {
    int fd = open_in_root(rootfd, "var/lib/veyra-user/boot-count", O_RDONLY);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    char buffer[64] = {0};
    ssize_t n = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    if (n <= 0) return -1;
    char *end = NULL;
    errno = 0;
    long value = strtol(buffer, &end, 10);
    if (errno || end == buffer || value < 0 || value > 1000000) return -1;
    while (*end == '\n' || *end == '\r' || *end == ' ') end++;
    return *end ? -1 : (int)value;
}
static int check_proofs(int rootfd, char *error, size_t error_size) {
    struct stat st;
    int fd = open_in_root(rootfd, "home/veyrauser/normal-user-proof", O_RDONLY);
    if (fd < 0 || fstat(fd, &st) < 0 || st.st_uid != OUTER_NORMAL_UID) {
        if (fd >= 0) close(fd);
        set_error(error, error_size, "ordinary user write did not map to outside UID 101000");
        return -1;
    }
    close(fd);
    fd = open_in_root(rootfd, "home/veyrauser/inner-sudo-proof", O_RDONLY);
    char value[16] = {0};
    ssize_t n = fd >= 0 ? read(fd, value, sizeof(value) - 1) : -1;
    if (fd >= 0) close(fd);
    if (n < 2 || value[0] != '0' || value[1] != '\n') {
        set_error(error, error_size, "namespace-local sudo did not create inner UID 0 proof");
        return -1;
    }
    fd = open_in_root(rootfd, "home/veyrauser/inner-sudo-proof", O_PATH);
    if (fd < 0 || fstat(fd, &st) < 0 || st.st_uid != OUTER_ROOT_UID) {
        if (fd >= 0) close(fd);
        set_error(error, error_size, "namespace-local sudo escaped mapped outside UID 100000");
        return -1;
    }
    close(fd);
    return 0;
}
static void proof_ordinary_user(void) {
    pid_t pid = fork();
    if (pid < 0) die("fork normal-user proof");
    if (!pid) {
        if (setgid(1000) || setuid(1000)) die("switch to inner UID/GID 1000");
        int fd = open("/home/veyrauser/normal-user-proof",
                      O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) die("normal user cannot write home");
        write_text(fd, "inner-user-id=1000\n");
        if (close(fd) < 0) die("close normal-user proof");
        _exit(0);
    }
    int status;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) ||
        WEXITSTATUS(status) != 0) die("ordinary user proof failed");
}
static void proof_user_sudo(void) {
    pid_t pid = fork();
    if (pid < 0) die("fork namespace-local sudo probe");
    if (!pid) {
        if (setgid(1000) || setuid(1000)) die("drop to inner ordinary account");
        execl("/usr/bin/sudo", "sudo", "-n", "/bin/sh", "-c",
              "id -u > /home/veyrauser/inner-sudo-proof", (char *)NULL);
        die("execute namespace-local sudo");
    }
    int status;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) ||
        WEXITSTATUS(status) != 0) die("inner sudo privilege elevation failed");
}
static int directory_identity_matches(int validated_fd, const char *path) {
    struct stat validated_st, candidate_st;
    if (fstat(validated_fd, &validated_st) < 0 || stat(path, &candidate_st) < 0)
        return -1;
    return validated_st.st_dev == candidate_st.st_dev &&
           validated_st.st_ino == candidate_st.st_ino;
}
/* Bind mount from a validated, open directory FD, never from the
 * mutable configured rootfs pathname. The procfd refers to the pinned
 * opened mount/dentry even if the original name is replaced meanwhile.
 * Production still needs immutable content and storage policy.
 */
static int bind_directory_fd(int fd, const char *target) {
    char pinned_source[64];
    int n = snprintf(pinned_source, sizeof(pinned_source),
                     "/proc/self/fd/%d", fd);
    if (n <= 0 || n >= (int)sizeof(pinned_source)) {
        errno = EINVAL;
        return -1;
    }
    return mount(pinned_source, target, NULL, MS_BIND, NULL);
}

/* Deny inheritance of ALL system-side descriptor capabilities except
 * explicitly needed startup descriptors. This is deliberately fail-closed
 * if close_range(2) is unavailable on the running kernel.
 */
static void close_unlisted_fds(const int *allow, size_t allowed) {
    unsigned int first = 3;
    for (;;) {
        unsigned int next = UINT_MAX;
        for (size_t i = 0; i < allowed; i++) {
            if (allow[i] >= 3 && (unsigned int)allow[i] >= first &&
                (unsigned int)allow[i] < next)
                next = (unsigned int)allow[i];
        }
        if (next == UINT_MAX) {
            if (syscall(SYS_close_range, first, UINT_MAX, 0) < 0)
                die("close untrusted inherited descriptors");
            return;
        }
        if (next > first &&
            syscall(SYS_close_range, first, next - 1, 0) < 0)
            die("close system descriptors before namespace launch");
        first = next + 1;
    }
}

/* Actual hostile-name-swap test: pin the first mount via FD, cover the
 * exposed name with a DIFFERENT bind mount, and prove the FD bind still
 * selects the original inode. Only runs in the disposable QEMU system.
 */
static int test_fd_bind_after_name_swap(void) {
    char workspace[] = RUN_DIR "/.fd-bind-XXXXXX";
    if (!mkdtemp(workspace)) { perror("mkdtemp fd-bind"); return 1; }
    char original[PATH_MAX], alternate[PATH_MAX], visible[PATH_MAX], target[PATH_MAX];
    if (snprintf(original, sizeof(original), "%s/original", workspace) >= (int)sizeof(original) ||
        snprintf(alternate, sizeof(alternate), "%s/alternate", workspace) >= (int)sizeof(alternate) ||
        snprintf(visible, sizeof(visible), "%s/visible", workspace) >= (int)sizeof(visible) ||
        snprintf(target, sizeof(target), "%s/target", workspace) >= (int)sizeof(target))
        return 2;
    if (mkdir(original, 0700) < 0 || mkdir(alternate, 0700) < 0 ||
        mkdir(visible, 0700) < 0 || mkdir(target, 0700) < 0)
        { perror("fd-bind fixture mkdir"); return 2; }

    if (mount(original, visible, NULL, MS_BIND, NULL) < 0)
        { perror("original mount"); return 2; }
    int validated = open(visible, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (validated < 0) { perror("pin original mount"); return 2; }
    if (mount(alternate, visible, NULL, MS_BIND, NULL) < 0)
        { perror("replace original mount"); return 2; }
    if (directory_identity_matches(validated, visible) != 0) {
        fprintf(stderr, "VEYRA_STAGE1_FAILURE: mount name swap fixture did not replace inode\n");
        return 1;
    }
    if (bind_directory_fd(validated, target) < 0) {
        perror("bind pinned original descriptor");
        return 1;
    }
    if (directory_identity_matches(validated, target) != 1 ||
        directory_identity_matches(validated, visible) != 0) {
        fprintf(stderr, "VEYRA_STAGE1_FAILURE: FD bind selected swapped rootfs mount\n");
        return 1;
    }
    close(validated);
    if (umount(target) < 0 || umount(visible) < 0 ||
        umount(visible) < 0)
        { perror("fd-bind cleanup unmount"); return 2; }
    if (rmdir(original) < 0 || rmdir(alternate) < 0 ||
        rmdir(visible) < 0 || rmdir(target) < 0 ||
        rmdir(workspace) < 0)
        { perror("fd-bind cleanup dirs"); return 2; }
    puts("VEYRA_STAGE1_ROOTFS_FD_BIND_SWAP_PASS");
    return 0;
}

/* Unit-test the deny-by-default inherited descriptor policy while keeping
 * only a single explicitly approved communication FD.
 */
static int test_fd_close_policy(void) {
    pid_t pid = fork();
    if (pid < 0) return 2;
    if (!pid) {
        int rejected[2];
        int allowed = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (allowed < 3 || pipe2(rejected, O_CLOEXEC) < 0) _exit(2);
        int keep[] = { allowed };
        close_unlisted_fds(keep, 1);
        if (fcntl(allowed, F_GETFD) < 0 ||
            fcntl(rejected[0], F_GETFD) != -1 || errno != EBADF ||
            fcntl(rejected[1], F_GETFD) != -1 || errno != EBADF)
            _exit(1);
        /* A pipe with its only read end closed would trigger SIGPIPE here,
         * falsely failing descriptor sanitization. /dev/null gives a
         * safe writable, still-open allowlisted descriptor instead.
         */
        if (write_all(allowed, "K", 1) < 0) _exit(1);
        _exit(0);
    }
    int status;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) ||
        WEXITSTATUS(status) != 0) return 1;
    puts("VEYRA_STAGE1_FD_SANITIZATION_PASS");
    return 0;
}


/* Exercise both live pidfd signalling and the stale/dead-process case.
 * A reaped PID may be reused; its OLD pidfd must never signal a replacement.
 */
static int test_pidfd_signals(void) {
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        for (;;) pause();
    }
    int fd = (int)syscall(SYS_pidfd_open, child, 0);
    if (fd < 0) {
        (void)kill(child, SIGKILL); (void)waitpid(child, NULL, 0);
        perror("pidfd_open test");
        return 2;
    }
    int sent = (int)syscall(SYS_pidfd_send_signal, fd, SIGTERM, NULL, 0);
    int status = 0;
    if (sent < 0 || waitpid(child, &status, 0) != child ||
        !WIFSIGNALED(status) || WTERMSIG(status) != SIGTERM) {
        close(fd);
        fprintf(stderr, "VEYRA_STAGE1_FAILURE: pidfd did not terminate its pinned child\n");
        return 1;
    }
    errno = 0;
    int stale = (int)syscall(SYS_pidfd_send_signal, fd, SIGKILL, NULL, 0);
    int stale_errno = errno;
    close(fd);
    if (stale != -1 || stale_errno != ESRCH) {
        fprintf(stderr, "VEYRA_STAGE1_FAILURE: stale pidfd did not fail closed\n");
        return 1;
    }
    puts("VEYRA_STAGE1_PIDFD_STALE_SIGNAL_REJECTED");
    return 0;
}

/* A pinned procfd source cannot be bind-mounted directly by the
 * unprivileged user namespace on our tested Alpine kernel (EINVAL).
 * Instead, initial-namespace root prepares the mount from the validated
 * FD in a trusted root-owned directory before creating the child.
 * The user namespace receives a locked inherited mount and may bind
 * only this staged path. No untrusted user may rename the stage path.
 */
static int ensure_pin_directory(void) {
    if (mkdir(PIN_PARENT, 0711) < 0 && errno != EEXIST) return -1;
    struct stat st;
    if (lstat(PIN_PARENT, &st) < 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != 0 || (st.st_mode & 07777) != 0711) {
        errno = EPERM;
        return -1;
    }
    if (mkdir(PIN_PATH, 0700) < 0 && errno != EEXIST) return -1;
    return 0;
}
static int stage_validated_rootfs(int rootfd) {
    /* A killed manager may leave a previous system-side staging mount.
     * Detach just that controlled mountpoint; never the real root disk.
     */
    if (umount2(PIN_PATH, MNT_DETACH) < 0 && errno != EINVAL)
        return -1;
    struct stat st;
    if (lstat(PIN_PATH, &st) < 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != 0 || (st.st_mode & 07777) != 0700) {
        errno = EPERM;
        return -1;
    }
    if (bind_directory_fd(rootfd, PIN_PATH) < 0) return -1;
    if (directory_identity_matches(rootfd, PIN_PATH) != 1) {
        (void)umount2(PIN_PATH, MNT_DETACH);
        errno = ESTALE;
        return -1;
    }
    return 0;
}
static int test_directory_identity_guard(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "rootfs inode guard test requires system-side UID 0\n");
        return 2;
    }
    int rootfd = open(ROOT_PATH, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (rootfd < 0) { perror("open validated rootfs for inode guard test"); return 2; }
    int same = directory_identity_matches(rootfd, ROOT_PATH);
    int different = directory_identity_matches(rootfd, "/run");
    close(rootfd);
    if (same != 1 || different != 0) {
        fprintf(stderr, "VEYRA_STAGE1_FAILURE: rootfs inode identity guard self-test failed\n");
        return 1;
    }
    puts("VEYRA_STAGE1_ROOTFS_INODE_GUARD_PASS");
    if (test_fd_bind_after_name_swap() != 0 ||
        test_fd_close_policy() != 0 ||
        test_pidfd_signals() != 0)
        return 1;
    return 0;
}
static void inner_pid_one(int root_fd, int ready_fd) {
    /* The launcher waits for this acknowledgment before reporting the PID.
     * If the launcher dies before this signal is armed, the pipe is closed
     * and this process exits instead of becoming an orphaned environment.
     */
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 ||
        write_all(ready_fd, "D", 1) < 0)
        _exit(1);
    close(ready_fd);
    if (geteuid() != 0 || getegid() != 0 || getpid() != 1)
        die("inner UID/GID or PID 1 mismatch");
    if (sethostname("veyra-user", 10) < 0) die("namespace hostname");
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0)
        die("private mount propagation");
    const char *bootstrap = "/mnt/veyra-stage1-bootstrap";
    const char *newroot = "/mnt/veyra-stage1-bootstrap/root";
    const char *oldroot = "/mnt/veyra-stage1-bootstrap/root/.veyra-stage1-oldroot";
    if (mkdir(bootstrap, 0700) < 0 && errno != EEXIST)
        die("create private intermediate mountpoint");
    struct stat bootstrap_st;
    if (lstat(bootstrap, &bootstrap_st) < 0 || !S_ISDIR(bootstrap_st.st_mode) ||
        bootstrap_st.st_uid != 0 || (bootstrap_st.st_mode & 0777) != 0700) {
        errno = EPERM;
        die("private intermediate mountpoint is not root-owned and private");
    }
    if (mount("tmpfs", bootstrap, "tmpfs", MS_NOSUID | MS_NODEV, "mode=0700") < 0)
        die("mount private intermediate tmpfs root");
    if (mkdir(newroot, 0700) < 0) die("create temporary newroot");
    /* The system manager attached the pinned descriptor to this
     * protected mountpoint before fork. Using a procfd as the source
     * here can fail in a less-privileged mount namespace with EINVAL.
     */
    if (mount(PIN_PATH, newroot, NULL, MS_BIND, NULL) < 0)
        die("bind trusted system-staged rootfs");
    int identity_matches = directory_identity_matches(root_fd, newroot);
    if (identity_matches != 1) {
        if (identity_matches < 0) die("inspect bound user rootfs identity");
        errno = ESTALE;
        die("bound user rootfs is not the validated directory inode");
    }
    close(root_fd);
    if (mkdir(oldroot, 0700) < 0 && errno != EEXIST) die("create oldroot directory");
    if (chroot(bootstrap) < 0 || chdir("/") < 0) die("enter intermediate root");
    if (syscall(SYS_pivot_root, "/root", "/root/.veyra-stage1-oldroot") < 0)
        die("pivot into persistent user rootfs");
    if (chdir("/") < 0) die("chdir to user root");
    if (umount2("/.veyra-stage1-oldroot", MNT_DETACH) < 0) die("detach old system root");
    if (rmdir("/.veyra-stage1-oldroot") < 0) die("remove oldroot");
    struct stat manager_socket;
    if (lstat("/run/veyra-user-manager/control.sock", &manager_socket) == 0 ||
        errno != ENOENT)
        die("system-side manager socket leaked into user rootfs");
    if (mount("proc", "/proc", "proc", MS_NODEV | MS_NOSUID | MS_NOEXEC, "") < 0)
        die("mount user procfs");
    struct stat devpts_target;
    if (lstat("/dev/pts", &devpts_target) < 0 ||
        !S_ISDIR(devpts_target.st_mode))
        die("user /dev/pts must be a real directory");
    char ptmx_target[32] = {0};
    ssize_t ptmx_length = readlink("/dev/ptmx", ptmx_target,
                                   sizeof(ptmx_target) - 1);
    if (ptmx_length < 0 ||
        (size_t)ptmx_length != strlen("pts/ptmx"))
        die("user /dev/ptmx must point to isolated devpts");
    ptmx_target[ptmx_length] = '\0';
    if (strcmp(ptmx_target, "pts/ptmx"))
        die("user /dev/ptmx must point to isolated devpts");
    if (mount("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC,
              "newinstance,ptmxmode=0666,mode=0620") < 0)
        die("mount isolated user devpts");
    if (mount("tmpfs", "/run", "tmpfs", MS_NODEV | MS_NOSUID, "mode=0755") < 0)
        die("mount user /run");
    if (mount("tmpfs", "/tmp", "tmpfs", MS_NODEV | MS_NOSUID, "mode=1777") < 0)
        die("mount user /tmp");
    /* No manager socket, validated rootfs FD, mount FD, startup pipe or
     * unrelated system capability may reach ordinary user-side processes.
     */
    close_unlisted_fds(NULL, 0);
    proof_ordinary_user();
    proof_user_sudo();
    close_unlisted_fds(NULL, 0);
    printf("VEYRA_STAGE1_USER_PID1_STARTED pid=%ld\n", (long)getpid());
    fflush(stdout);
    execl("/sbin/init", "init", (char *)NULL);
    die("execute user BusyBox init");
}
static void launch_user(const struct child_args *ctx) {
    const int permitted_fds[] = {
        ctx->ready_write, ctx->proceed_read, ctx->pid_write, ctx->root_fd
    };
    close_unlisted_fds(permitted_fds,
                       sizeof(permitted_fds) / sizeof(permitted_fds[0]));
    if (setgroups(0, NULL) < 0 || setgid(OUTER_ROOT_UID) < 0 ||
        setuid(OUTER_ROOT_UID) < 0) die("drop to unprivileged outside UID 100000");
    /* Credential changes clear PR_SET_PDEATHSIG, so arm it again after the
     * drop and verify that the system-side manager is still our parent.
     */
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 ||
        getppid() != ctx->expected_parent)
        _exit(1);
    if (geteuid() != OUTER_ROOT_UID) die("launcher remains privileged");
    if (unshare(CLONE_NEWUSER) < 0) die("create user namespace");
    write_text(ctx->ready_write, "R");
    close(ctx->ready_write);
    char signal = 0;
    if (read_one_timeout(ctx->proceed_read, &signal, 10000) < 0 || signal != 'G')
        die("system manager did not install UID/GID mappings");
    close(ctx->proceed_read);
    if (geteuid() != 0 || getegid() != 0) die("mapped namespace root unavailable");
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 ||
        getppid() != ctx->expected_parent)
        _exit(1);
    if (unshare(CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWIPC |
                CLONE_NEWUTS | CLONE_NEWPID) < 0)
        die("create mount/network/IPC/UTS/PID namespaces");
    int init_ready[2];
    if (pipe2(init_ready, O_CLOEXEC) < 0) die("create PID 1 death-signal handshake");
    pid_t pid1 = fork();
    if (pid1 < 0) die("fork nested PID 1");
    if (!pid1) {
        close(init_ready[0]);
        close(ctx->pid_write);
        inner_pid_one(ctx->root_fd, init_ready[1]);
        _exit(1);
    }
    close(init_ready[1]);
    close(ctx->root_fd);
    char init_ready_signal = 0;
    if (read_one_timeout(init_ready[0], &init_ready_signal, 10000) < 0 ||
        init_ready_signal != 'D') {
        close(init_ready[0]);
        (void)kill(pid1, SIGKILL);
        (void)waitpid(pid1, NULL, 0);
        die("nested PID 1 death-signal setup failed");
    }
    close(init_ready[0]);
    char value[48];
    int n = snprintf(value, sizeof(value), "%ld\n", (long)pid1);
    if (n <= 0 || n >= (int)sizeof(value)) die("format user PID 1");
    write_text(ctx->pid_write, value);
    close(ctx->pid_write);
    int status = 0;
    if (waitpid(pid1, &status, 0) != pid1) die("wait for nested PID 1");
    if (WIFSIGNALED(status)) _exit(128 + WTERMSIG(status));
    if (WIFEXITED(status)) _exit(WEXITSTATUS(status));
    _exit(1);
}
static void close_user_pidfd(void) {
    if (user_pidfd >= 0) {
        close(user_pidfd);
        user_pidfd = -1;
    }
}
/* The manager must NEVER signal a mere numeric PID returned over a pipe.
 * pidfd_send_signal targets the kernel-pinned task, not a future PID reuse.
 */
static int signal_user_pid1(int signo) {
    if (user_pid1 <= 1 || user_pid1 == getpid() || user_pidfd < 0) {
        errno = EPERM;
        return -1;
    }
    return (int)syscall(SYS_pidfd_send_signal, user_pidfd, signo, NULL, 0);
}

static void reap_child(void) {
    if (launcher_pid <= 0) return;
    int status = 0;
    pid_t result = waitpid(launcher_pid, &status, WNOHANG);
    if (result == 0 || (result < 0 && errno == EINTR)) return;
    if (result < 0 && errno != ECHILD) return;
    if (result == launcher_pid) {
        if (WIFEXITED(status)) last_exit_code = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) last_exit_code = 128 + WTERMSIG(status);
        else last_exit_code = 1;
    }
    close_user_pidfd();
    launcher_pid = 0;
    user_pid1 = 0;
    if (state == STATE_STOPPING) state = STATE_STOPPED;
    else state = STATE_FAILED;
}
static int wait_for_child(int timeout_ms) {
    int elapsed = 0;
    while (launcher_pid > 0 && elapsed < timeout_ms) {
        reap_child();
        if (!launcher_pid) return 0;
        usleep(100000);
        elapsed += 100;
    }
    reap_child();
    return launcher_pid == 0 ? 0 : -1;
}
static int stop_environment(void) {
    reap_child();
    if (!launcher_pid) return state == STATE_FAILED ? -1 : 0;
    /* A host PID 1/manager signalling bug must NEVER trigger a system-wide
     * shutdown. Refuse dangerous target PIDs and leave the environment
     * visibly FAILED, rather than signalling the initial PID namespace.
     */
    if (user_pid1 <= 1 || user_pid1 == getpid() || user_pidfd < 0) {
        state = STATE_FAILED;
        fprintf(stderr, "VEYRA_STAGE1_STOP_REFUSED_INVALID_PID target=%ld manager=%ld\n",
                (long)user_pid1, (long)getpid());
        fflush(stderr);
        return -1;
    }
    fprintf(stderr, "VEYRA_STAGE1_STOP_TARGET pid=%ld manager=%ld\n",
            (long)user_pid1, (long)getpid());
    fflush(stderr);
    state = STATE_STOPPING;
    if (signal_user_pid1(SIGTERM) < 0 && errno != ESRCH) {
        state = STATE_RUNNING;
        return -1;
    }
    if (wait_for_child(STOP_TIMEOUT_MS) == 0) {
        state = STATE_STOPPED;
        return 0;
    }
    if (user_pidfd >= 0) (void)signal_user_pid1(SIGKILL);
    if (wait_for_child(STOP_TIMEOUT_MS) == 0) {
        state = STATE_STOPPED;
        return 0;
    }
    state = STATE_FAILED;
    return -1;
}
static int start_environment(char *response, size_t response_size) {
    reap_child();
    if (launcher_pid > 0) {
        snprintf(response, response_size, "RUNNING pid=%ld count=%d",
                 (long)user_pid1, boot_count);
        return 0;
    }
    int rootfd = -1;
    char error[256] = {0};
    if (validate_rootfs(&rootfd, error, sizeof(error)) < 0) {
        snprintf(response, response_size, "ERROR rootfs: %s", error);
        return -1;
    }
    if (stage_validated_rootfs(rootfd) < 0) {
        close(rootfd);
        snprintf(response, response_size,
                 "ERROR rootfs: cannot mount validated FD into trusted system stage");
        return -1;
    }
    int baseline = read_boot_count(rootfd);
    if (baseline < 0) {
        close(rootfd);
        snprintf(response, response_size, "ERROR rootfs: invalid persistent boot counter");
        return -1;
    }
    int ready[2], proceed[2], pid_pipe[2];
    if (pipe2(ready, O_CLOEXEC) < 0 || pipe2(proceed, O_CLOEXEC) < 0 ||
        pipe2(pid_pipe, O_CLOEXEC) < 0) {
        close(rootfd);
        snprintf(response, response_size, "ERROR manager: cannot create launch pipes");
        return -1;
    }
    pid_t expected_parent = getpid();
    pid_t pid = fork();
    if (pid < 0) {
        close(rootfd);
        snprintf(response, response_size, "ERROR manager: cannot fork launcher");
        return -1;
    }
    if (!pid) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 ||
            getppid() != expected_parent)
            _exit(1);
        close(ready[0]); close(proceed[1]); close(pid_pipe[0]);
        struct child_args args = {
            .ready_write = ready[1], .proceed_read = proceed[0],
            .pid_write = pid_pipe[1], .root_fd = rootfd,
            .expected_parent = expected_parent,
        };
        launch_user(&args);
        _exit(1);
    }
    close(ready[1]); close(proceed[0]); close(pid_pipe[1]);
    /* Hold the validated directory FD throughout readiness checks.
     * Re-opening ROOT_PATH here would reintroduce path-replacement TOCTOU.
     */
    launcher_pid = pid;
    state = STATE_STARTING;
    char signal = 0;
    if (read_one_timeout(ready[0], &signal, 10000) < 0 || signal != 'R') {
        close(ready[0]); close(proceed[1]); close(pid_pipe[0]);
        if (launcher_pid > 0) (void)kill(launcher_pid, SIGKILL);
        (void)wait_for_child(STOP_TIMEOUT_MS);
        state = STATE_FAILED;
        snprintf(response, response_size, "ERROR launch: user-namespace launcher failed");
        close(rootfd);
        return -1;
    }
    close(ready[0]);
    install_map(pid, "uid_map", "0 100000 65536\n");
    install_map(pid, "gid_map", "0 100000 65536\n");
    write_text(proceed[1], "G");
    close(proceed[1]);
    char pid_text[48] = {0};
    struct pollfd pfd = { .fd = pid_pipe[0], .events = POLLIN };
    int polled;
    do { polled = poll(&pfd, 1, 10000); } while (polled < 0 && errno == EINTR);
    ssize_t bytes = polled > 0 ? read(pid_pipe[0], pid_text, sizeof(pid_text) - 1) : -1;
    close(pid_pipe[0]);
    char *end = NULL;
    long nested_pid = bytes > 0 ? strtol(pid_text, &end, 10) : -1;
    if (bytes <= 0 || end == pid_text || nested_pid <= 0) {
        if (launcher_pid > 0) (void)kill(launcher_pid, SIGKILL);
        (void)wait_for_child(STOP_TIMEOUT_MS);
        state = STATE_FAILED;
        snprintf(response, response_size, "ERROR launch: user PID 1 did not start");
        close(rootfd);
        return -1;
    }
    /* pidfd_open is mandatory, not an optional optimisation. If the nested
     * PID disappeared already, fail closed and terminate its launcher.
     */
    if (nested_pid <= 1 || nested_pid == (long)getpid()) {
        if (launcher_pid > 0) (void)kill(launcher_pid, SIGKILL);
        (void)wait_for_child(STOP_TIMEOUT_MS);
        state = STATE_FAILED;
        snprintf(response, response_size, "ERROR launch: invalid user PID 1");
        close(rootfd);
        return -1;
    }
    int pinned_pid = (int)syscall(SYS_pidfd_open, (pid_t)nested_pid, 0);
    if (pinned_pid < 0) {
        if (launcher_pid > 0) (void)kill(launcher_pid, SIGKILL);
        (void)wait_for_child(STOP_TIMEOUT_MS);
        state = STATE_FAILED;
        snprintf(response, response_size, "ERROR launch: cannot pin user PID 1");
        close(rootfd);
        return -1;
    }
    user_pid1 = (pid_t)nested_pid;
    user_pidfd = pinned_pid;
    state = STATE_STARTING;
    for (int elapsed = 0; elapsed < START_TIMEOUT_MS; elapsed += 100) {
        reap_child();
        if (!launcher_pid) {
            snprintf(response, response_size,
                     "ERROR launch: user PID 1 exited before readiness (launcher exit=%d)",
                     last_exit_code);
            close(rootfd);
            return -1;
        }
        int count = read_boot_count(rootfd);
        if (count == baseline + 1 && check_proofs(rootfd, error, sizeof(error)) == 0) {
                boot_count = count;
                state = STATE_RUNNING;
                printf("VEYRA_STAGE1_SUDO_READY count=%d inside-uid=0 outside-uid=100000\n",
                       boot_count);
                printf("VEYRA_STAGE1_USER_OPENRC_READY count=%d\n", boot_count);
                fflush(stdout);
                snprintf(response, response_size, "RUNNING pid=%ld count=%d",
                         (long)user_pid1, boot_count);
                close(rootfd);
                return 0;
        }
        if (count > baseline + 1) {
            (void)signal_user_pid1(SIGKILL);
            (void)wait_for_child(STOP_TIMEOUT_MS);
            state = STATE_FAILED;
            snprintf(response, response_size, "ERROR launch: persistent boot counter jumped unexpectedly");
            close(rootfd);
            return -1;
        }
        usleep(100000);
    }
    (void)signal_user_pid1(SIGKILL);
    (void)wait_for_child(STOP_TIMEOUT_MS);
    state = STATE_FAILED;
    snprintf(response, response_size, "ERROR launch: OpenRC readiness timed out");
    close(rootfd);
    return -1;
}
static const char *state_name(void) {
    switch (state) {
    case STATE_STOPPED: return "STOPPED";
    case STATE_STARTING: return "STARTING";
    case STATE_RUNNING: return "RUNNING";
    case STATE_STOPPING: return "STOPPING";
    case STATE_FAILED: return "FAILED";
    }
    return "FAILED";
}
static int format_status(char *response, size_t size) {
    reap_child();
    if (state == STATE_RUNNING && launcher_pid > 0)
        snprintf(response, size, "RUNNING pid=%ld count=%d",
                 (long)user_pid1, boot_count);
    else if (state == STATE_FAILED)
        snprintf(response, size, "FAILED exit=%d", last_exit_code);
    else snprintf(response, size, "%s", state_name());
    return 0;
}
static void reply(int fd, const char *message) {
    (void)write_all(fd, message, strlen(message));
    (void)write_all(fd, "\n", 1);
}
static void handle_client(int fd) {
    struct ucred peer;
    socklen_t peer_len = sizeof(peer);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &peer_len) < 0 ||
        peer.uid != 0) {
        reply(fd, "ERROR permission: system-side UID 0 is required");
        return;
    }
    char command[64] = {0};
    ssize_t n;
    do { n = read(fd, command, sizeof(command) - 1); } while (n < 0 && errno == EINTR);
    if (n <= 0) { reply(fd, "ERROR protocol: empty command"); return; }
    command[strcspn(command, "\r\n")] = '\0';
    char response[512] = {0};
    if (!strcmp(command, "start")) {
        (void)start_environment(response, sizeof(response));
    } else if (!strcmp(command, "status")) {
        (void)format_status(response, sizeof(response));
    } else if (!strcmp(command, "stop")) {
        int result = stop_environment();
        if (result < 0) snprintf(response, sizeof(response), "ERROR stop: environment failed to stop");
        else snprintf(response, sizeof(response), "STOPPED");
    } else {
        snprintf(response, sizeof(response), "ERROR protocol: use start, status, or stop");
    }
    reply(fd, response);
}
static void on_signal(int signo) {
    (void)signo;
    terminate_requested = 1;
}
static int prepare_socket(void) {
    struct stat st;
    if (mkdir("/run", 0755) < 0 && errno != EEXIST) return -1;
    if (lstat("/run", &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 ||
        (st.st_mode & 0022)) { errno = EPERM; return -1; }
    if (mkdir(RUN_DIR, 0700) < 0 && errno != EEXIST) return -1;
    if (lstat(RUN_DIR, &st) < 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != 0 || (st.st_mode & 07777) != 0700) {
        errno = EPERM;
        return -1;
    }
    if (lstat(SOCKET_PATH, &st) == 0) {
        if (!S_ISSOCK(st.st_mode) || st.st_uid != 0) {
            errno = EPERM;
            return -1;
        }
        int probe = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        struct sockaddr_un address = { .sun_family = AF_UNIX };
        snprintf(address.sun_path, sizeof(address.sun_path), "%s", SOCKET_PATH);
        int connected = probe >= 0 && connect(probe, (struct sockaddr *)&address,
                                               sizeof(address)) == 0;
        if (probe >= 0) close(probe);
        if (connected) { errno = EADDRINUSE; return -1; }
        if (unlink(SOCKET_PATH) < 0) return -1;
    } else if (errno != ENOENT) return -1;
    listener_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listener_fd < 0) return -1;
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%s", SOCKET_PATH)
        >= (int)sizeof(address.sun_path)) { errno = ENAMETOOLONG; return -1; }
    if (bind(listener_fd, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        chmod(SOCKET_PATH, 0600) < 0 || listen(listener_fd, 8) < 0) return -1;
    return 0;
}
static int manager_service(void) {
    if (geteuid() != 0) { errno = EPERM; return -1; }
    int rootfd = -1;
    char error[256] = {0};
    if (validate_rootfs(&rootfd, error, sizeof(error)) < 0) {
        fprintf(stderr, "VEYRA_STAGE1_FAILURE: rootfs rejected: %s\n", error);
        return -1;
    }
    close(rootfd);
    if (ensure_pin_directory() < 0 || prepare_socket() < 0)
        return -1;
    struct sigaction action = {0};
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
    puts("VEYRA_STAGE1_MANAGER_READY");
    fflush(stdout);
    while (!terminate_requested) {
        struct pollfd item = { .fd = listener_fd, .events = POLLIN };
        int ready = poll(&item, 1, 250);
        if (ready < 0 && errno != EINTR) break;
        reap_child();
        if (ready > 0 && (item.revents & POLLIN)) {
            client_fd = accept4(listener_fd, NULL, NULL, SOCK_CLOEXEC);
            if (client_fd >= 0) {
                handle_client(client_fd);
                close(client_fd);
                client_fd = -1;
            }
        }
    }
    if (launcher_pid > 0) (void)stop_environment();
    if (client_fd >= 0) close(client_fd);
    if (listener_fd >= 0) close(listener_fd);
    /* Normal shutdown drops the trusted mount. A SIGKILL leaves it
     * to be safely detached on the next start.
     */
    if (umount2(PIN_PATH, MNT_DETACH) < 0 && errno != EINVAL)
        perror("detach trusted rootfs stage");
    (void)unlink(SOCKET_PATH);
    return 0;
}
static int manager_client(const char *command) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { perror("socket"); return 2; }
    struct timeval timeout = { .tv_sec = 120, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%s", SOCKET_PATH)
        >= (int)sizeof(address.sun_path)) { close(fd); return 2; }
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("connect manager"); close(fd); return 2;
    }
    if (write_all(fd, command, strlen(command)) < 0 ||
        write_all(fd, "\n", 1) < 0) { close(fd); return 2; }
    char response[512] = {0};
    ssize_t n;
    do { n = read(fd, response, sizeof(response) - 1); } while (n < 0 && errno == EINTR);
    close(fd);
    if (n <= 0) { perror("read manager response"); return 2; }
    response[strcspn(response, "\r\n")] = '\0';
    puts(response);
    return !strncmp(response, "ERROR", 5) ? 1 : 0;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "test-inode-guard"))
        return test_directory_identity_guard();
    if (argc == 3 && !strcmp(argv[1], "serve") &&
        !strcmp(argv[2], ROOT_PATH)) {
        route_test_manager_stderr_to_console();
        if (manager_service() < 0) die("system-side user manager failed");
        return 0;
    }
    if (argc == 2 && (!strcmp(argv[1], "start") ||
                      !strcmp(argv[1], "status") ||
                      !strcmp(argv[1], "stop")))
        return manager_client(argv[1]);
    fprintf(stderr, "usage: %s serve %s | start | status | stop\n",
            argv[0], ROOT_PATH);
    return 2;
}

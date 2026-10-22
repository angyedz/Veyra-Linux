#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/vfs.h>
#include <unistd.h>

#define VEYRA_EXT4_SUPER_MAGIC 0xEF53

static void power_off(void) {
    (void)sync();
    (void)reboot(RB_POWER_OFF);
    _exit(1);
}

static void fail(const char *operation) {
    int saved_errno = errno;
    dprintf(STDERR_FILENO,
            "VEYRA_SNAPCORE_FAILURE: full root deletion: %s (errno=%d: %s)\n",
            operation, saved_errno, strerror(saved_errno));
    errno = saved_errno;
    power_off();
}

static int is_pseudo_mount(const char *name) {
    return !strcmp(name, "dev") || !strcmp(name, "proc") ||
           !strcmp(name, "sys") || !strcmp(name, "run") ||
           !strcmp(name, "tmp");
}

static int remove_directory_contents(int directory_fd, int top_level) {
    int copy_fd = fcntl(directory_fd, F_DUPFD_CLOEXEC, 3);
    if (copy_fd < 0) return -1;
    DIR *directory = fdopendir(copy_fd);
    if (!directory) {
        close(copy_fd);
        return -1;
    }

    int result = 0;
    errno = 0;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;
        if (top_level && is_pseudo_mount(entry->d_name))
            continue;

        struct stat st;
        if (fstatat(directory_fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0) {
            result = -1;
            break;
        }

        if (S_ISDIR(st.st_mode)) {
            int child_fd = openat(directory_fd, entry->d_name,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child_fd < 0) {
                result = -1;
                break;
            }
            result = remove_directory_contents(child_fd, 0);
            int saved_errno = errno;
            close(child_fd);
            errno = saved_errno;
            if (result < 0 ||
                unlinkat(directory_fd, entry->d_name, AT_REMOVEDIR) < 0) {
                result = -1;
                break;
            }
        } else if (unlinkat(directory_fd, entry->d_name, 0) < 0) {
            result = -1;
            break;
        }
        errno = 0;
    }
    if (!entry && errno != 0) result = -1;
    int saved_errno = errno;
    closedir(directory);
    errno = saved_errno;
    return result;
}

static int require_absent(int root_fd, const char *name) {
    struct stat st;
    if (fstatat(root_fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
        errno = EEXIST;
        return -1;
    }
    return errno == ENOENT ? 0 : -1;
}


static int has_fixture_marker(void) {
    static const char expected[] = "DISPOSABLE_QEMU_ROOT_V1\n";
    int fd = open("/etc/veyra-snapcore-root-fixture", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char actual[sizeof(expected)];
    ssize_t length = read(fd, actual, sizeof(actual));
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    return length == (ssize_t)(sizeof(expected) - 1) &&
           !memcmp(actual, expected, sizeof(expected) - 1);
}

static int has_qemu_fixture_argument(void) {
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char command_line[4096];
    ssize_t length = read(fd, command_line, sizeof(command_line) - 1);
    close(fd);
    if (length <= 0) return 0;
    command_line[length] = '\0';
    return strstr(command_line, "veyra_snapcore_fixture=booted-root-test") != NULL;
}

static int has_ublk_fixture_argument(void) {
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char command_line[4096];
    ssize_t length = read(fd, command_line, sizeof(command_line) - 1);
    close(fd);
    if (length <= 0) return 0;
    command_line[length] = '\0';
    return strstr(command_line, "veyra_snapcore_ublk_fixture=1") != NULL;
}

static int is_ext4_qemu_root(void) {
    FILE *mounts = fopen("/proc/mounts", "r");
    if (!mounts) return 0;
    char source[256], target[256], type[64], options[1024];
    unsigned long dump, pass;
    int valid = 0;
    while (fscanf(mounts, "%255s %255s %63s %1023s %lu %lu",
                  source, target, type, options, &dump, &pass) == 6) {
        if (!strcmp(target, "/")) {
            int expected_source = has_ublk_fixture_argument()
                ? !strcmp(source, "/dev/ublkb0")
                : !strcmp(source, "/dev/vda");
            valid = expected_source && !strcmp(type, "ext4");
            break;
        }
    }
    fclose(mounts);
    return valid;
}

static int fixture_guard(int root_fd) {
    struct statfs filesystem;
    if (fstatfs(root_fd, &filesystem) < 0) return 0;
    return filesystem.f_type == VEYRA_EXT4_SUPER_MAGIC &&
           has_fixture_marker() && has_qemu_fixture_argument() &&
           is_ext4_qemu_root();
}

int main(void) {
    static const char *const removed[] = {
        "bin", "etc", "home", "lib", "lib64", "opt", "root",
        "sbin", "usr", "var", "lost+found",
    };
    int root_fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (root_fd < 0) fail("open root directory");
    if (!fixture_guard(root_fd)) {
        errno = EPERM;
        fail("refuse deletion outside the disposable QEMU ext4 fixture");
    }
    if (remove_directory_contents(root_fd, 1) < 0)
        fail("remove root entries outside mounted pseudo-filesystems");
    for (size_t i = 0; i < sizeof(removed) / sizeof(removed[0]); ++i) {
        if (require_absent(root_fd, removed[i]) < 0)
            fail("verify that root entries were removed");
    }
    if (syncfs(root_fd) < 0) fail("sync deleted ext4 root");
    const char *root_device = has_ublk_fixture_argument()
        ? "/dev/ublkb0" : "/dev/vda";
    char message[160];
    int message_length = snprintf(
        message, sizeof(message),
        "VEYRA_SNAPCORE_BOOTED_ROOT_FULL_DELETE_PASS root=%s "
        "remaining=/dev,/proc,/sys,/run,/tmp\\n",
        root_device);
    if (message_length < 0 || (size_t)message_length >= sizeof(message))
        fail("format full-delete serial marker");
    if (write(STDOUT_FILENO, message, (size_t)message_length) != message_length)
        fail("write full-delete serial marker");
    power_off();
}

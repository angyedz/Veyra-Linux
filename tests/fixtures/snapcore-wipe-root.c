#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

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

int main(void) {
    static const char *const removed[] = {
        "bin", "etc", "home", "lib", "lib64", "opt", "root",
        "sbin", "usr", "var", "lost+found",
    };
    int root_fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (root_fd < 0) fail("open root directory");
    if (remove_directory_contents(root_fd, 1) < 0)
        fail("remove root entries outside mounted pseudo-filesystems");
    for (size_t i = 0; i < sizeof(removed) / sizeof(removed[0]); ++i) {
        if (require_absent(root_fd, removed[i]) < 0)
            fail("verify that root entries were removed");
    }
    if (syncfs(root_fd) < 0) fail("sync deleted ext4 root");
    static const char message[] =
        "VEYRA_SNAPCORE_BOOTED_ROOT_FULL_DELETE_PASS root=/dev/vda "
        "remaining=/dev,/proc,/sys,/run,/tmp\n";
    if (write(STDOUT_FILENO, message, sizeof(message) - 1) !=
        (ssize_t)(sizeof(message) - 1))
        fail("write full-delete serial marker");
    power_off();
}

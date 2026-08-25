#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define CONFIG_DIR "/etc/omarchy-admin-toggle"
#define CONFIG_FILE CONFIG_DIR "/config"
#define SUDO_TEMPLATE CONFIG_DIR "/sudoers.template"
#define SUDO_DISABLED CONFIG_DIR "/sudoers.disabled"
#define OFF_TEMPLATE CONFIG_DIR "/10-omarchy-admin-toggle-off.rules.template"
#define RECOVERY_TEMPLATE CONFIG_DIR "/05-omarchy-admin-toggle-recovery.rules.template"
#define MANAGE_TEMPLATE CONFIG_DIR "/20-omarchy-admin-toggle-manage.rules.template"
#define POLICY_TEMPLATE CONFIG_DIR "/com.github.andrewbacon.omarchy-admin-toggle.policy.template"
#define LOCK_FILE CONFIG_DIR "/lock"

#define SUDOERS_MAIN "/etc/sudoers"
#define SUDOERS_DIR "/etc/sudoers.d"
#define OFF_RULE "/etc/polkit-1/rules.d/10-omarchy-admin-toggle-off.rules"
#define RECOVERY_RULE "/etc/polkit-1/rules.d/05-omarchy-admin-toggle-recovery.rules"
#define MANAGE_RULE "/etc/polkit-1/rules.d/20-omarchy-admin-toggle-manage.rules"
#define POLICY_FILE "/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-admin-toggle.policy"
#define HELPER_FILE "/usr/local/libexec/omarchy-admin-toggle-helper"

#define ENABLE_ACTION "com.github.andrewbacon.omarchy-admin-toggle.enable"
#define DISABLE_ACTION "com.github.andrewbacon.omarchy-admin-toggle.disable"

#define VISUDO "/usr/bin/visudo"
#define PKACTION "/usr/bin/pkaction"
#define MAX_FILE_SIZE (1024U * 1024U)

struct config {
    char user[128];
    uid_t uid;
    char grant_path[PATH_MAX];
};

struct blob {
    char *data;
    size_t len;
};

enum mode_state {
    MODE_ENABLED,
    MODE_DISABLED,
    MODE_INCONSISTENT
};

static char path_config_dir[PATH_MAX];
static char path_config[PATH_MAX];
static char path_sudo_template[PATH_MAX];
static char path_sudo_disabled[PATH_MAX];
static char path_off_template[PATH_MAX];
static char path_recovery_template[PATH_MAX];
static char path_manage_template[PATH_MAX];
static char path_policy_template[PATH_MAX];
static char path_lock[PATH_MAX];
static char path_sudoers_main[PATH_MAX];
static char path_sudoers_dir[PATH_MAX];
static char path_off_rule[PATH_MAX];
static char path_recovery_rule[PATH_MAX];
static char path_manage_rule[PATH_MAX];
static char path_policy_file[PATH_MAX];
static char path_helper_file[PATH_MAX];

_Noreturn static void fail(const char *fmt, ...)
{
    va_list ap;

    fputs("omarchy-admin-toggle-helper: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(EXIT_FAILURE);
}

_Noreturn static void fail_errno(const char *operation, const char *path)
{
    fail("%s %s: %s", operation, path, strerror(errno));
}

static void checked_snprintf(char *dest, size_t size, const char *fmt, ...)
{
    va_list ap;
    int written;

    va_start(ap, fmt);
    written = vsnprintf(dest, size, fmt, ap);
    va_end(ap);
    if (written < 0 || (size_t)written >= size)
        fail("constructed path or value is too long");
}

static void set_path(char *dest, size_t size, const char *absolute)
{
#ifdef TESTING
    const char *root = getenv("OMARCHY_ADMIN_TOGGLE_TEST_ROOT");
    if (root != NULL && root[0] == '/') {
        checked_snprintf(dest, size, "%s%s", root, absolute);
        return;
    }
#endif
    checked_snprintf(dest, size, "%s", absolute);
}

static void initialize_paths(void)
{
    set_path(path_config_dir, sizeof(path_config_dir), CONFIG_DIR);
    set_path(path_config, sizeof(path_config), CONFIG_FILE);
    set_path(path_sudo_template, sizeof(path_sudo_template), SUDO_TEMPLATE);
    set_path(path_sudo_disabled, sizeof(path_sudo_disabled), SUDO_DISABLED);
    set_path(path_off_template, sizeof(path_off_template), OFF_TEMPLATE);
    set_path(path_recovery_template, sizeof(path_recovery_template), RECOVERY_TEMPLATE);
    set_path(path_manage_template, sizeof(path_manage_template), MANAGE_TEMPLATE);
    set_path(path_policy_template, sizeof(path_policy_template), POLICY_TEMPLATE);
    set_path(path_lock, sizeof(path_lock), LOCK_FILE);
    set_path(path_sudoers_main, sizeof(path_sudoers_main), SUDOERS_MAIN);
    set_path(path_sudoers_dir, sizeof(path_sudoers_dir), SUDOERS_DIR);
    set_path(path_off_rule, sizeof(path_off_rule), OFF_RULE);
    set_path(path_recovery_rule, sizeof(path_recovery_rule), RECOVERY_RULE);
    set_path(path_manage_rule, sizeof(path_manage_rule), MANAGE_RULE);
    set_path(path_policy_file, sizeof(path_policy_file), POLICY_FILE);
    set_path(path_helper_file, sizeof(path_helper_file), HELPER_FILE);
}

static uid_t trusted_uid(void)
{
#ifdef TESTING
    return geteuid();
#else
    return 0;
#endif
}

static gid_t trusted_gid(void)
{
#ifdef TESTING
    return getegid();
#else
    return 0;
#endif
}

static bool valid_username(const char *name)
{
    size_t i;

    if (name[0] == '\0' || strlen(name) >= 128U)
        return false;
    if (!((name[0] >= 'a' && name[0] <= 'z') || name[0] == '_'))
        return false;
    for (i = 1U; name[i] != '\0'; ++i) {
        char c = name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
              c == '_' || c == '-'))
            return false;
    }
    return true;
}

static bool parse_uid(const char *text, uid_t *result)
{
    char *end = NULL;
    unsigned long value;

    if (text == NULL || text[0] == '\0')
        return false;
    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value > UINT32_MAX)
        return false;
    *result = (uid_t)value;
    return (unsigned long)*result == value;
}

static bool metadata_is(const struct stat *st, mode_t mode)
{
    return S_ISREG(st->st_mode) && st->st_uid == trusted_uid() &&
           st->st_gid == trusted_gid() && (st->st_mode & 07777) == mode;
}

static bool config_directory_is_secure(void)
{
    struct stat st;

    return lstat(path_config_dir, &st) == 0 && S_ISDIR(st.st_mode) &&
           st.st_uid == trusted_uid() && st.st_gid == trusted_gid() &&
           (st.st_mode & 07777) == 0700;
}

static bool load_file(const char *path, mode_t mode, struct blob *out)
{
    struct stat st;
    ssize_t amount;
    size_t offset = 0U;
    int fd;

    out->data = NULL;
    out->len = 0U;
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return false;
    if (fstat(fd, &st) != 0 || !metadata_is(&st, mode) || st.st_size < 0 ||
        (uintmax_t)st.st_size > MAX_FILE_SIZE) {
        close(fd);
        return false;
    }
    out->len = (size_t)st.st_size;
    out->data = malloc(out->len + 1U);
    if (out->data == NULL) {
        close(fd);
        fail("out of memory");
    }
    while (offset < out->len) {
        amount = read(fd, out->data + offset, out->len - offset);
        if (amount < 0 && errno == EINTR)
            continue;
        if (amount <= 0) {
            free(out->data);
            out->data = NULL;
            close(fd);
            return false;
        }
        offset += (size_t)amount;
    }
    out->data[out->len] = '\0';
    if (close(fd) != 0) {
        free(out->data);
        out->data = NULL;
        return false;
    }
    return true;
}

static void free_blob(struct blob *blob)
{
    free(blob->data);
    blob->data = NULL;
    blob->len = 0U;
}

static bool path_absent(const char *path)
{
    struct stat st;

    if (lstat(path, &st) == 0)
        return false;
    return errno == ENOENT;
}

static bool file_equals_blob(const char *path, mode_t mode, const struct blob *expected)
{
    struct blob actual;
    bool equal;

    if (!load_file(path, mode, &actual))
        return false;
    equal = actual.len == expected->len &&
            memcmp(actual.data, expected->data, expected->len) == 0;
    free_blob(&actual);
    return equal;
}

static bool load_config(struct config *cfg)
{
    struct blob content;
    char *first_end;
    char *second_end;
    const char user_prefix[] = "TARGET_USER=";
    const char uid_prefix[] = "TARGET_UID=";
    struct passwd *pw;

    memset(cfg, 0, sizeof(*cfg));
    if (!load_file(path_config, 0600, &content))
        return false;

    first_end = strchr(content.data, '\n');
    if (first_end == NULL) {
        free_blob(&content);
        return false;
    }
    *first_end = '\0';
    second_end = strchr(first_end + 1, '\n');
    if (second_end == NULL || second_end[1] != '\0' ||
        strncmp(content.data, user_prefix, sizeof(user_prefix) - 1U) != 0 ||
        strncmp(first_end + 1, uid_prefix, sizeof(uid_prefix) - 1U) != 0) {
        free_blob(&content);
        return false;
    }
    *second_end = '\0';
    checked_snprintf(cfg->user, sizeof(cfg->user), "%s",
                     content.data + sizeof(user_prefix) - 1U);
    if (!valid_username(cfg->user) ||
        !parse_uid(first_end + 1 + sizeof(uid_prefix) - 1U, &cfg->uid)) {
        free_blob(&content);
        return false;
    }
    free_blob(&content);

    pw = getpwnam(cfg->user);
    if (pw == NULL || pw->pw_uid != cfg->uid)
        return false;
    checked_snprintf(cfg->grant_path, sizeof(cfg->grant_path), "%s/00_%s",
                     path_sudoers_dir, cfg->user);
    return true;
}

static bool expected_sudo_template(const struct config *cfg, const struct blob *blob)
{
    char expected[256];
    int len = snprintf(expected, sizeof(expected), "%s ALL=(ALL) ALL\n", cfg->user);

    return len > 0 && (size_t)len == blob->len &&
           memcmp(expected, blob->data, blob->len) == 0;
}

static bool infrastructure_files_good(void)
{
    const char *templates[] = {
        path_recovery_template, path_manage_template, path_policy_template
    };
    const char *installed[] = {
        path_recovery_rule, path_manage_rule, path_policy_file
    };
    size_t i;

    for (i = 0U; i < sizeof(templates) / sizeof(templates[0]); ++i) {
        struct blob expected;
        if (!load_file(templates[i], 0644, &expected))
            return false;
        if (!file_equals_blob(installed[i], 0644, &expected)) {
            free_blob(&expected);
            return false;
        }
        free_blob(&expected);
    }

#ifndef TESTING
    {
        struct stat st;
        if (lstat(path_helper_file, &st) != 0 || !S_ISREG(st.st_mode) ||
            st.st_uid != 0 || st.st_gid != 0 || (st.st_mode & 07777) != 04755)
            return false;
    }
#endif
    return true;
}

static enum mode_state current_state(const struct config *cfg)
{
    struct blob sudo_template;
    struct blob off_template;
    bool grant_good;
    bool disabled_good;
    bool off_good;

    if (!infrastructure_files_good() ||
        !load_file(path_sudo_template, 0440, &sudo_template))
        return MODE_INCONSISTENT;
    if (!expected_sudo_template(cfg, &sudo_template)) {
        free_blob(&sudo_template);
        return MODE_INCONSISTENT;
    }
    if (!load_file(path_off_template, 0644, &off_template)) {
        free_blob(&sudo_template);
        return MODE_INCONSISTENT;
    }

    grant_good = file_equals_blob(cfg->grant_path, 0440, &sudo_template);
    disabled_good = file_equals_blob(path_sudo_disabled, 0440, &sudo_template);
    off_good = file_equals_blob(path_off_rule, 0644, &off_template);

    free_blob(&off_template);
    free_blob(&sudo_template);

    if (grant_good && path_absent(path_sudo_disabled) && path_absent(path_off_rule))
        return MODE_ENABLED;
    if (path_absent(cfg->grant_path) && disabled_good && off_good)
        return MODE_DISABLED;
    return MODE_INCONSISTENT;
}

static const char *state_name(enum mode_state state)
{
    switch (state) {
    case MODE_ENABLED:
        return "enabled";
    case MODE_DISABLED:
        return "disabled";
    default:
        return "inconsistent";
    }
}

static int run_fixed(char *const argv[])
{
    pid_t child;
    int status;

    child = fork();
    if (child < 0)
        return -1;
    if (child == 0) {
        int null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (null_fd < 0 || dup2(null_fd, STDOUT_FILENO) < 0 ||
            dup2(null_fd, STDERR_FILENO) < 0)
            _exit(125);
        if (null_fd > STDERR_FILENO)
            close(null_fd);
        if (clearenv() != 0)
            _exit(125);
        if (setenv("PATH", "/usr/bin", 1) != 0)
            _exit(125);
        execv(argv[0], argv);
        _exit(125);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR)
            return -1;
    }
    if (!WIFEXITED(status))
        return -1;
    return WEXITSTATUS(status);
}

static bool validate_sudo_file(const char *path)
{
    char *const argv[] = { (char *)VISUDO, "-cf", (char *)path, NULL };
    return run_fixed(argv) == 0;
}

static bool actions_registered(void)
{
#ifdef TESTING
    return true;
#else
    char *const enable_argv[] = {
        (char *)PKACTION, "--action-id", (char *)ENABLE_ACTION, NULL
    };
    char *const disable_argv[] = {
        (char *)PKACTION, "--action-id", (char *)DISABLE_ACTION, NULL
    };
    return run_fixed(enable_argv) == 0 && run_fixed(disable_argv) == 0;
#endif
}

static void fsync_parent(const char *path)
{
    char parent[PATH_MAX];
    char *slash;
    int fd;

    checked_snprintf(parent, sizeof(parent), "%s", path);
    slash = strrchr(parent, '/');
    if (slash == NULL || slash == parent)
        fail("invalid managed path: %s", path);
    *slash = '\0';
    fd = open(parent, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0)
        fail_errno("open", parent);
    if (fsync(fd) != 0) {
        close(fd);
        fail_errno("fsync", parent);
    }
    if (close(fd) != 0)
        fail_errno("close", parent);
}

static void write_all(int fd, const char *data, size_t len, const char *path)
{
    size_t offset = 0U;

    while (offset < len) {
        ssize_t amount = write(fd, data + offset, len - offset);
        if (amount < 0 && errno == EINTR)
            continue;
        if (amount <= 0)
            fail_errno("write", path);
        offset += (size_t)amount;
    }
}

static void write_atomic(const char *destination, const struct blob *content,
                         mode_t mode)
{
    char temporary[PATH_MAX];
    int fd;

    checked_snprintf(temporary, sizeof(temporary), "%s.tmp.XXXXXX", destination);
    fd = mkstemp(temporary);
    if (fd < 0)
        fail_errno("create temporary file for", destination);
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 ||
        fchown(fd, trusted_uid(), trusted_gid()) != 0 || fchmod(fd, mode) != 0) {
        int saved = errno;
        close(fd);
        unlink(temporary);
        errno = saved;
        fail_errno("secure temporary file for", destination);
    }
    write_all(fd, content->data, content->len, temporary);
    if (fsync(fd) != 0) {
        int saved = errno;
        close(fd);
        unlink(temporary);
        errno = saved;
        fail_errno("fsync", temporary);
    }
    if (close(fd) != 0) {
        int saved = errno;
        unlink(temporary);
        errno = saved;
        fail_errno("close", temporary);
    }
    if (rename(temporary, destination) != 0) {
        int saved = errno;
        unlink(temporary);
        errno = saved;
        fail_errno("install", destination);
    }
    fsync_parent(destination);
}

static void remove_managed(const char *path)
{
    if (unlink(path) != 0 && errno != ENOENT)
        fail_errno("remove", path);
    fsync_parent(path);
}

static void rename_managed(const char *source, const char *destination)
{
    if (rename(source, destination) != 0)
        fail_errno("rename", source);
    fsync_parent(source);
    fsync_parent(destination);
}

static bool try_rename_managed(const char *source, const char *destination)
{
    if (rename(source, destination) != 0)
        return false;
    fsync_parent(source);
    fsync_parent(destination);
    return true;
}

static int lock_state(void)
{
    int fd = open(path_lock, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);

    if (fd < 0)
        fail_errno("open", path_lock);
    if (fchown(fd, trusted_uid(), trusted_gid()) != 0 || fchmod(fd, 0600) != 0) {
        close(fd);
        fail_errno("secure", path_lock);
    }
    if (flock(fd, LOCK_EX) != 0) {
        close(fd);
        fail_errno("lock", path_lock);
    }
    return fd;
}

static bool mutation_caller_is_valid(const struct config *cfg)
{
#ifdef TESTING
    const char *test = getenv("OMARCHY_ADMIN_TOGGLE_TEST_PKEXEC");
    if (test != NULL && strcmp(test, "1") == 0 && getuid() == cfg->uid)
        return true;
#endif
    {
        uid_t caller = (uid_t)-1;
        const char *pkexec_uid = getenv("PKEXEC_UID");
        return getuid() == 0 && geteuid() == 0 &&
               parse_uid(pkexec_uid, &caller) && caller == cfg->uid;
    }
}

static bool status_caller_is_valid(const struct config *cfg)
{
    uid_t pk_uid = (uid_t)-1;
    const char *pkexec_uid = getenv("PKEXEC_UID");

#ifdef TESTING
    if (getuid() == cfg->uid)
        return true;
#endif
    if (geteuid() != 0)
        return false;
    if (getuid() == cfg->uid)
        return true;
    return getuid() == 0 && parse_uid(pkexec_uid, &pk_uid) && pk_uid == cfg->uid;
}

static void verify_disable_preflight(const struct config *cfg)
{
    struct blob sudo_template;

    if (!infrastructure_files_good())
        fail("recovery infrastructure is missing, modified, or has unsafe permissions");
    if (!actions_registered())
        fail("custom Polkit actions are not registered");
    if (!load_file(path_sudo_template, 0440, &sudo_template) ||
        !expected_sudo_template(cfg, &sudo_template))
        fail("the known sudo template is missing, modified, or unsafe");
    free_blob(&sudo_template);
    if (!validate_sudo_file(path_sudo_template))
        fail("the known sudo template failed visudo validation");
    if (!validate_sudo_file(path_sudoers_main))
        fail("the complete sudoers configuration is invalid before disable");
}

static void rollback_disable(const struct config *cfg)
{
    if (path_absent(cfg->grant_path) && !path_absent(path_sudo_disabled))
        rename_managed(path_sudo_disabled, cfg->grant_path);
    remove_managed(path_off_rule);
}

static void disable_mode(const struct config *cfg)
{
    enum mode_state state = current_state(cfg);
    struct blob off_template;

    if (state == MODE_DISABLED) {
        puts("disabled");
        return;
    }
    if (state != MODE_ENABLED)
        fail("refusing to disable from an inconsistent state");
    verify_disable_preflight(cfg);
    if (!load_file(path_off_template, 0644, &off_template))
        fail("the OFF rule template is missing, modified, or unsafe");

    write_atomic(path_off_rule, &off_template, 0644);
    free_blob(&off_template);
    if (!try_rename_managed(cfg->grant_path, path_sudo_disabled)) {
        int saved = errno;
        remove_managed(path_off_rule);
        errno = saved;
        fail_errno("preserve sudo grant", cfg->grant_path);
    }

    if (!validate_sudo_file(path_sudoers_main) || current_state(cfg) != MODE_DISABLED) {
        rollback_disable(cfg);
        if (!validate_sudo_file(path_sudoers_main))
            fail("disable failed and rollback left sudoers invalid; use emergency recovery");
        fail("disable verification failed; the original enabled state was restored");
    }
    syslog(LOG_AUTHPRIV | LOG_NOTICE,
           "administrator mode disabled for uid %lu (%s)",
           (unsigned long)cfg->uid, cfg->user);
    puts("disabled");
}

static void rollback_enable(const struct config *cfg)
{
    struct blob off_template;

    if (!path_absent(cfg->grant_path) && path_absent(path_sudo_disabled))
        rename_managed(cfg->grant_path, path_sudo_disabled);
    if (path_absent(path_off_rule) && load_file(path_off_template, 0644, &off_template)) {
        write_atomic(path_off_rule, &off_template, 0644);
        free_blob(&off_template);
    }
}

static void enable_mode(const struct config *cfg)
{
    enum mode_state state = current_state(cfg);
    struct blob sudo_template;

    if (state == MODE_ENABLED) {
        puts("enabled");
        return;
    }
    if (state != MODE_DISABLED)
        fail("refusing to enable from an inconsistent state; use documented emergency recovery");
    if (!load_file(path_sudo_template, 0440, &sudo_template) ||
        !expected_sudo_template(cfg, &sudo_template))
        fail("the known sudo template is missing, modified, or unsafe");
    free_blob(&sudo_template);
    if (!validate_sudo_file(path_sudo_template))
        fail("the known sudo template failed visudo validation");

    rename_managed(path_sudo_disabled, cfg->grant_path);
    if (!validate_sudo_file(path_sudoers_main)) {
        rename_managed(cfg->grant_path, path_sudo_disabled);
        fail("restored sudo grant failed full visudo validation; OFF state retained");
    }
    remove_managed(path_off_rule);
    if (current_state(cfg) != MODE_ENABLED) {
        rollback_enable(cfg);
        fail("enable verification failed; OFF state was restored where possible");
    }
    syslog(LOG_AUTHPRIV | LOG_NOTICE,
           "administrator mode enabled for uid %lu (%s)",
           (unsigned long)cfg->uid, cfg->user);
    puts("enabled");
}

int main(int argc, char **argv)
{
    struct config cfg;
    int lock_fd = -1;

    initialize_paths();
    umask(077);
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0)
        fail("could not disable process dumps");
    openlog("omarchy-admin-toggle", LOG_PID, LOG_AUTHPRIV);
    if (argc != 2 || (strcmp(argv[1], "status") != 0 &&
                      strcmp(argv[1], "enable") != 0 &&
                      strcmp(argv[1], "disable") != 0))
        fail("usage: omarchy-admin-toggle-helper {status|enable|disable}");
    if (!config_directory_is_secure() || !load_config(&cfg)) {
        if (strcmp(argv[1], "status") == 0) {
            puts("inconsistent");
            return 2;
        }
        fail("trusted configuration is missing, invalid, or does not match the account database");
    }

    if (strcmp(argv[1], "status") == 0) {
        if (!status_caller_is_valid(&cfg))
            fail("status is available only to the configured local user");
        puts(state_name(current_state(&cfg)));
        return 0;
    }
    if (!mutation_caller_is_valid(&cfg))
        fail("state changes must come from pkexec for the configured local user");

    lock_fd = lock_state();
    if (strcmp(argv[1], "enable") == 0)
        enable_mode(&cfg);
    else
        disable_mode(&cfg);
    if (close(lock_fd) != 0)
        fail_errno("close", path_lock);
    return 0;
}

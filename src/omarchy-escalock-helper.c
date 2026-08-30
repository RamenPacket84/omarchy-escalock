#define _GNU_SOURCE

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define CONFIG_DIR "/etc/omarchy-escalock"
#define CONFIG_FILE CONFIG_DIR "/config"
#define SUDO_TEMPLATE CONFIG_DIR "/sudoers.template"
#define SUDO_DISABLED CONFIG_DIR "/sudoers.disabled"
#define WHEEL_ORIGINAL_TEMPLATE CONFIG_DIR "/omarchy-wheel.original"
#define WHEEL_MANAGED_TEMPLATE CONFIG_DIR "/omarchy-wheel.managed"
#define RULE_ON_TEMPLATE CONFIG_DIR "/00-00-omarchy-escalock-on.rules.template"
#define RULE_OFF_TEMPLATE CONFIG_DIR "/00-00-omarchy-escalock-off.rules.template"
#define POLICY_TEMPLATE CONFIG_DIR "/com.github.andrewbacon.omarchy-escalock.policy.template"
#define SUDO_POLICY_ENABLED CONFIG_DIR "/sudo-policy.enabled.json"
#define SUDO_POLICY_DISABLED CONFIG_DIR "/sudo-policy.disabled.json"
#define LOCK_FILE CONFIG_DIR "/lock"

#define SUDOERS_MAIN "/etc/sudoers"
#define SUDOERS_DIR "/etc/sudoers.d"
#define WHEEL_GRANT SUDOERS_DIR "/00-omarchy-wheel"
#define RULE_FILE "/etc/polkit-1/rules.d/00-00-omarchy-escalock.rules"
#define ETC_RULES_DIR "/etc/polkit-1/rules.d"
#define SHARE_RULES_DIR "/usr/share/polkit-1/rules.d"
#define POLICY_FILE "/usr/share/polkit-1/actions/com.github.andrewbacon.omarchy-escalock.policy"
#define HELPER_FILE "/usr/local/libexec/omarchy-escalock-helper"

#define ENABLE_ACTION "com.github.andrewbacon.omarchy-escalock.enable"
#define DISABLE_ACTION "com.github.andrewbacon.omarchy-escalock.disable"

#define VISUDO "/usr/bin/visudo"
#define PKACTION "/usr/bin/pkaction"
#define PKCHECK "/usr/bin/pkcheck"
#ifndef CVTSUDOERS
#define CVTSUDOERS "/usr/bin/cvtsudoers"
#endif
#define JQ "/usr/bin/jq"
#define RULE_BASENAME "00-00-omarchy-escalock.rules"
#define MAX_FILE_SIZE (1024U * 1024U)
#define ESCALOCK_VERSION "2.0.7"

enum grant_mode {
    GRANT_DEDICATED,
    GRANT_OMARCHY_WHEEL
};

struct config {
    char user[128];
    uid_t uid;
    char grant_basename[256];
    char grant_path[PATH_MAX];
    enum grant_mode grant_mode;
};

struct blob {
    char *data;
    size_t len;
};

static bool sudo_policy_matches(const struct config *cfg, const char *expected_path);

enum mode_state {
    MODE_ENABLED,
    MODE_DISABLED,
    MODE_INCONSISTENT
};

static char path_config_dir[PATH_MAX];
static char path_config[PATH_MAX];
static char path_sudo_template[PATH_MAX];
static char path_sudo_disabled[PATH_MAX];
static char path_wheel_original_template[PATH_MAX];
static char path_wheel_managed_template[PATH_MAX];
static char path_rule_on_template[PATH_MAX];
static char path_rule_off_template[PATH_MAX];
static char path_policy_template[PATH_MAX];
static char path_sudo_policy_enabled[PATH_MAX];
static char path_sudo_policy_disabled[PATH_MAX];
static char path_lock[PATH_MAX];
static char path_sudoers_main[PATH_MAX];
static char path_sudoers_dir[PATH_MAX];
static char path_wheel_grant[PATH_MAX];
static char path_rule_file[PATH_MAX];
static char path_etc_rules_dir[PATH_MAX];
static char path_share_rules_dir[PATH_MAX];
static char path_policy_file[PATH_MAX];
static char path_helper_file[PATH_MAX];

_Noreturn static void fail(const char *fmt, ...)
{
    va_list ap;

    fputs("omarchy-escalock-helper: ", stderr);
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
    const char *root = getenv("OMARCHY_ESCALOCK_TEST_ROOT");
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
    set_path(path_wheel_original_template, sizeof(path_wheel_original_template),
             WHEEL_ORIGINAL_TEMPLATE);
    set_path(path_wheel_managed_template, sizeof(path_wheel_managed_template),
             WHEEL_MANAGED_TEMPLATE);
    set_path(path_rule_on_template, sizeof(path_rule_on_template), RULE_ON_TEMPLATE);
    set_path(path_rule_off_template, sizeof(path_rule_off_template), RULE_OFF_TEMPLATE);
    set_path(path_policy_template, sizeof(path_policy_template), POLICY_TEMPLATE);
    set_path(path_sudo_policy_enabled, sizeof(path_sudo_policy_enabled), SUDO_POLICY_ENABLED);
    set_path(path_sudo_policy_disabled, sizeof(path_sudo_policy_disabled), SUDO_POLICY_DISABLED);
    set_path(path_lock, sizeof(path_lock), LOCK_FILE);
    set_path(path_sudoers_main, sizeof(path_sudoers_main), SUDOERS_MAIN);
    set_path(path_sudoers_dir, sizeof(path_sudoers_dir), SUDOERS_DIR);
    set_path(path_wheel_grant, sizeof(path_wheel_grant), WHEEL_GRANT);
    set_path(path_rule_file, sizeof(path_rule_file), RULE_FILE);
    set_path(path_etc_rules_dir, sizeof(path_etc_rules_dir), ETC_RULES_DIR);
    set_path(path_share_rules_dir, sizeof(path_share_rules_dir), SHARE_RULES_DIR);
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

static bool valid_grant_basename(const char *basename, const char *user,
                                 enum grant_mode mode)
{
    const char *cursor = basename;
    size_t digit_count = 0U;
    char expected[256];
    int written;

    if (mode == GRANT_OMARCHY_WHEEL) {
        written = snprintf(expected, sizeof(expected), "00_%s", user);
        return written > 0 && (size_t)written < sizeof(expected) &&
               strcmp(basename, expected) == 0;
    }
    while (*cursor >= '0' && *cursor <= '9') {
        ++cursor;
        ++digit_count;
    }
    return digit_count >= 2U && *cursor == '_' &&
           strcmp(cursor + 1, user) == 0;
}

static bool parse_uid(const char *text, uid_t *result)
{
    char *end = NULL;
    unsigned long value;
    size_t i;

    if (text == NULL || text[0] == '\0')
        return false;
    for (i = 0U; text[i] != '\0'; ++i) {
        if (text[i] < '0' || text[i] > '9')
            return false;
    }
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
    char *cursor;
    char *end;
    char *lines[4];
    size_t line_count = 0U;
    const char *value;
    int written;
    const char user_prefix[] = "TARGET_USER=";
    const char uid_prefix[] = "TARGET_UID=";
    const char mode_prefix[] = "GRANT_MODE=";
    const char basename_prefix[] = "GRANT_BASENAME=";
    struct passwd *pw;

    memset(cfg, 0, sizeof(*cfg));
    if (!load_file(path_config, 0600, &content))
        return false;
    if (strlen(content.data) != content.len)
        goto invalid;
    cursor = content.data;
    while (*cursor != '\0') {
        if (line_count == sizeof(lines) / sizeof(lines[0]))
            goto invalid;
        end = strchr(cursor, '\n');
        if (end == NULL)
            goto invalid;
        *end = '\0';
        lines[line_count++] = cursor;
        cursor = end + 1;
    }
    if (line_count < 2U ||
        strncmp(lines[0], user_prefix, sizeof(user_prefix) - 1U) != 0 ||
        strncmp(lines[1], uid_prefix, sizeof(uid_prefix) - 1U) != 0)
        goto invalid;

    value = lines[0] + sizeof(user_prefix) - 1U;
    if (strlen(value) >= sizeof(cfg->user))
        goto invalid;
    memcpy(cfg->user, value, strlen(value) + 1U);
    if (!valid_username(cfg->user) ||
        !parse_uid(lines[1] + sizeof(uid_prefix) - 1U, &cfg->uid))
        goto invalid;

    cfg->grant_mode = GRANT_DEDICATED;
    if (line_count >= 3U) {
        if (strncmp(lines[2], mode_prefix, sizeof(mode_prefix) - 1U) != 0)
            goto invalid;
        value = lines[2] + sizeof(mode_prefix) - 1U;
        if (strcmp(value, "omarchy-wheel") == 0)
            cfg->grant_mode = GRANT_OMARCHY_WHEEL;
        else if (strcmp(value, "dedicated") != 0)
            goto invalid;
    }

    written = snprintf(cfg->grant_basename, sizeof(cfg->grant_basename),
                       "00_%s", cfg->user);
    if (written < 0 || (size_t)written >= sizeof(cfg->grant_basename))
        goto invalid;
    if (line_count == 4U) {
        if (strncmp(lines[3], basename_prefix, sizeof(basename_prefix) - 1U) != 0)
            goto invalid;
        value = lines[3] + sizeof(basename_prefix) - 1U;
        if (strlen(value) >= sizeof(cfg->grant_basename))
            goto invalid;
        memcpy(cfg->grant_basename, value, strlen(value) + 1U);
    }
    if (!valid_grant_basename(cfg->grant_basename, cfg->user, cfg->grant_mode))
        goto invalid;
    free_blob(&content);

    pw = getpwnam(cfg->user);
    if (pw == NULL || pw->pw_uid != cfg->uid)
        return false;
    checked_snprintf(cfg->grant_path, sizeof(cfg->grant_path), "%s/%s",
                     path_sudoers_dir, cfg->grant_basename);
    return true;

invalid:
    free_blob(&content);
    return false;
}

static bool expected_sudo_template(const struct config *cfg, const struct blob *blob)
{
    char expected[256];
    int len;

    if (cfg->grant_mode == GRANT_OMARCHY_WHEEL)
        len = snprintf(expected, sizeof(expected), "%s ALL=(ALL:ALL) ALL\n",
                       cfg->user);
    else
        len = snprintf(expected, sizeof(expected), "%s ALL=(ALL) ALL\n",
                       cfg->user);

    return len > 0 && (size_t)len == blob->len &&
           memcmp(expected, blob->data, blob->len) == 0;
}

static bool wheel_grant_layout_good(const struct config *cfg)
{
    struct blob original = { 0 };
    struct blob managed = { 0 };
    const char expected_original[] = "%wheel ALL=(ALL:ALL) ALL\n";
    char expected_managed[256];
    int managed_len;
    bool good;

    if (cfg->grant_mode == GRANT_DEDICATED)
        return path_absent(path_wheel_original_template) &&
               path_absent(path_wheel_managed_template);

    if (!load_file(path_wheel_original_template, 0440, &original) ||
        !load_file(path_wheel_managed_template, 0440, &managed)) {
        free_blob(&original);
        free_blob(&managed);
        return false;
    }
    managed_len = snprintf(expected_managed, sizeof(expected_managed),
                           "%%wheel, !%s ALL=(ALL:ALL) ALL\n", cfg->user);
    good = original.len == sizeof(expected_original) - 1U &&
           memcmp(original.data, expected_original, original.len) == 0 &&
           managed_len > 0 && (size_t)managed_len == managed.len &&
           memcmp(managed.data, expected_managed, managed.len) == 0 &&
           file_equals_blob(path_wheel_grant, 0440, &managed);
    free_blob(&managed);
    free_blob(&original);
    return good;
}

static bool name_has_suffix(const char *name, const char *suffix)
{
    size_t name_len = strlen(name);
    size_t suffix_len = strlen(suffix);

    return name_len >= suffix_len &&
           strcmp(name + name_len - suffix_len, suffix) == 0;
}

static bool no_preempting_polkit_rules_in(const char *directory,
                                          bool allow_project_rule)
{
    struct dirent *entry;
    struct stat st;
    DIR *stream;
    int fd;
    bool good = true;

    fd = open(directory, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0)
        return false;
    if (fstat(fd, &st) != 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != trusted_uid() || (st.st_mode & 0022) != 0) {
        close(fd);
        return false;
    }
    stream = fdopendir(fd);
    if (stream == NULL) {
        close(fd);
        return false;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        if (!name_has_suffix(entry->d_name, ".rules"))
            continue;
        if (strcmp(entry->d_name, RULE_BASENAME) < 0 ||
            (!allow_project_rule && strcmp(entry->d_name, RULE_BASENAME) == 0)) {
            good = false;
            break;
        }
    }
    if (entry == NULL && errno != 0)
        good = false;
    if (closedir(stream) != 0)
        good = false;
    return good;
}

static bool infrastructure_files_good(void)
{
    struct blob expected;
    struct blob ignored;

    if (!load_file(path_rule_on_template, 0644, &ignored))
        return false;
    free_blob(&ignored);
    if (!load_file(path_rule_off_template, 0644, &ignored))
        return false;
    free_blob(&ignored);
    if (!load_file(path_policy_template, 0644, &expected))
        return false;
    if (!file_equals_blob(path_policy_file, 0644, &expected)) {
        free_blob(&expected);
        return false;
    }
    free_blob(&expected);
    if (!no_preempting_polkit_rules_in(path_etc_rules_dir, true) ||
        !no_preempting_polkit_rules_in(path_share_rules_dir, false))
        return false;

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
    struct blob rule_on_template;
    struct blob rule_off_template;
    bool grant_good;
    bool disabled_good;
    bool rule_on_good;
    bool rule_off_good;

    if (!infrastructure_files_good() || !wheel_grant_layout_good(cfg) ||
        !load_file(path_sudo_template, 0440, &sudo_template))
        return MODE_INCONSISTENT;
    if (!expected_sudo_template(cfg, &sudo_template)) {
        free_blob(&sudo_template);
        return MODE_INCONSISTENT;
    }
    if (!load_file(path_rule_on_template, 0644, &rule_on_template) ||
        !load_file(path_rule_off_template, 0644, &rule_off_template)) {
        free_blob(&sudo_template);
        free_blob(&rule_on_template);
        return MODE_INCONSISTENT;
    }

    grant_good = file_equals_blob(cfg->grant_path, 0440, &sudo_template);
    disabled_good = file_equals_blob(path_sudo_disabled, 0440, &sudo_template);
    rule_on_good = file_equals_blob(path_rule_file, 0644, &rule_on_template);
    rule_off_good = file_equals_blob(path_rule_file, 0644, &rule_off_template);

    free_blob(&rule_off_template);
    free_blob(&rule_on_template);
    free_blob(&sudo_template);

    if (grant_good && path_absent(path_sudo_disabled) && rule_on_good &&
        sudo_policy_matches(cfg, path_sudo_policy_enabled))
        return MODE_ENABLED;
    if (path_absent(cfg->grant_path) && disabled_good && rule_off_good &&
        sudo_policy_matches(cfg, path_sudo_policy_disabled))
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

static bool run_fixed_capture(char *const argv[], struct blob *out)
{
    int pipe_fds[2];
    pid_t child;
    int status;
    size_t offset = 0U;
    bool too_large = false;

    out->data = NULL;
    out->len = 0U;
    if (pipe2(pipe_fds, O_CLOEXEC) != 0)
        return false;
    child = fork();
    if (child < 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        return false;
    }
    if (child == 0) {
        int null_fd;

        close(pipe_fds[0]);
        null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (null_fd < 0 || dup2(pipe_fds[1], STDOUT_FILENO) < 0 ||
            dup2(null_fd, STDERR_FILENO) < 0)
            _exit(125);
        close(pipe_fds[1]);
        if (null_fd > STDERR_FILENO)
            close(null_fd);
        if (clearenv() != 0 || setenv("PATH", "/usr/bin", 1) != 0)
            _exit(125);
        execv(argv[0], argv);
        _exit(125);
    }

    close(pipe_fds[1]);
    out->data = malloc(MAX_FILE_SIZE + 1U);
    if (out->data == NULL) {
        close(pipe_fds[0]);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR)
            ;
        fail("out of memory");
    }
    for (;;) {
        char extra;
        ssize_t amount;

        if (offset == MAX_FILE_SIZE) {
            amount = read(pipe_fds[0], &extra, 1U);
            if (amount > 0)
                too_large = true;
        } else {
            amount = read(pipe_fds[0], out->data + offset,
                          MAX_FILE_SIZE - offset);
            if (amount > 0)
                offset += (size_t)amount;
        }
        if (amount < 0) {
            if (errno == EINTR)
                continue;
            too_large = true;
        }
        if (amount <= 0 || too_large)
            break;
    }
    close(pipe_fds[0]);
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            free_blob(out);
            return false;
        }
    }
    if (too_large || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        free_blob(out);
        return false;
    }
    out->len = offset;
    out->data[offset] = '\0';
    return true;
}

static bool sudo_policy_matches(const struct config *cfg, const char *expected_path)
{
    struct blob expected;
    struct blob actual_raw;
    struct blob actual;
    char filter[160];
#ifdef TESTING
    char *const argv[] = {
        (char *)CVTSUDOERS, "-c", "/dev/null", "-f", "JSON", "-e", "-M",
        "-m", filter, path_sudoers_main, NULL
    };
#else
    char *const argv[] = {
        (char *)CVTSUDOERS, "-f", "JSON", "-e", "-M", "-m", filter,
        path_sudoers_main, NULL
    };
#endif
    bool equal;

    checked_snprintf(filter, sizeof(filter), "user=%s", cfg->user);
    if (!load_file(expected_path, 0600, &expected))
        return false;
    if (!run_fixed_capture(argv, &actual_raw)) {
        free_blob(&expected);
        return false;
    }
    {
        int input_fd = memfd_create("omarchy-escalock-sudo-policy", MFD_CLOEXEC);
        int output_pipe[2];
        pid_t child;
        int status;
        size_t offset = 0U;
        bool failed = false;

        actual.data = NULL;
        actual.len = 0U;
        if (input_fd < 0 || pipe2(output_pipe, O_CLOEXEC) != 0) {
            if (input_fd >= 0)
                close(input_fd);
            free_blob(&actual_raw);
            free_blob(&expected);
            return false;
        }
        while (offset < actual_raw.len) {
            ssize_t amount = write(input_fd, actual_raw.data + offset,
                                   actual_raw.len - offset);
            if (amount < 0 && errno == EINTR)
                continue;
            if (amount <= 0) {
                failed = true;
                break;
            }
            offset += (size_t)amount;
        }
        if (!failed && lseek(input_fd, 0, SEEK_SET) < 0)
            failed = true;
        child = failed ? (pid_t)-1 : fork();
        if (child == 0) {
            int null_fd;
            char *const jq_argv[] = { (char *)JQ, "-S", ".", NULL };

            close(output_pipe[0]);
            null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
            if (null_fd < 0 || dup2(input_fd, STDIN_FILENO) < 0 ||
                dup2(output_pipe[1], STDOUT_FILENO) < 0 ||
                dup2(null_fd, STDERR_FILENO) < 0)
                _exit(125);
            close(input_fd);
            close(output_pipe[1]);
            if (null_fd > STDERR_FILENO)
                close(null_fd);
            if (clearenv() != 0 || setenv("PATH", "/usr/bin", 1) != 0)
                _exit(125);
            execv(jq_argv[0], jq_argv);
            _exit(125);
        }
        close(input_fd);
        close(output_pipe[1]);
        free_blob(&actual_raw);
        if (child < 0) {
            close(output_pipe[0]);
            free_blob(&expected);
            return false;
        }
        actual.data = malloc(MAX_FILE_SIZE + 1U);
        if (actual.data == NULL) {
            close(output_pipe[0]);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR)
                ;
            free_blob(&expected);
            fail("out of memory");
        }
        offset = 0U;
        for (;;) {
            ssize_t amount = read(output_pipe[0], actual.data + offset,
                                  MAX_FILE_SIZE - offset);
            if (amount < 0) {
                if (errno == EINTR)
                    continue;
                failed = true;
            }
            if (amount <= 0)
                break;
            offset += (size_t)amount;
            if (offset == MAX_FILE_SIZE) {
                failed = true;
                break;
            }
        }
        close(output_pipe[0]);
        while (waitpid(child, &status, 0) < 0) {
            if (errno != EINTR) {
                failed = true;
                break;
            }
        }
        if (failed || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            free_blob(&actual);
            free_blob(&expected);
            return false;
        }
        actual.len = offset;
        actual.data[offset] = '\0';
    }
    equal = actual.len == expected.len &&
            memcmp(actual.data, expected.data, expected.len) == 0;
    free_blob(&actual);
    free_blob(&expected);
    return equal;
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

#ifndef TESTING
static bool process_start_time(pid_t pid, unsigned long long *start_time)
{
    char path[64];
    char buffer[4096];
    char *cursor;
    char *right_paren;
    ssize_t amount;
    int fd;
    unsigned int field;

    checked_snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return false;
    do {
        amount = read(fd, buffer, sizeof(buffer) - 1U);
    } while (amount < 0 && errno == EINTR);
    if (close(fd) != 0 || amount <= 0)
        return false;
    buffer[(size_t)amount] = '\0';
    right_paren = strrchr(buffer, ')');
    if (right_paren == NULL || right_paren[1] != ' ')
        return false;
    cursor = right_paren + 2;
    for (field = 3U; field <= 22U; ++field) {
        char *end = cursor;

        while (*end != '\0' && *end != ' ' && *end != '\n')
            ++end;
        if (end == cursor)
            return false;
        if (field == 22U) {
            char saved = *end;
            char *number_end = NULL;
            unsigned long long value;

            *end = '\0';
            errno = 0;
            value = strtoull(cursor, &number_end, 10);
            if (errno != 0 || number_end == cursor || *number_end != '\0') {
                *end = saved;
                return false;
            }
            *end = saved;
            *start_time = value;
            return true;
        }
        if (*end != ' ')
            return false;
        cursor = end + 1;
    }
    return false;
}

static bool start_policy_subject(const struct config *cfg, pid_t *subject_pid,
                                 int *hold_fd, unsigned long long *start_time)
{
    int ready[2];
    int hold[2];
    pid_t child;
    char marker;
    ssize_t amount;
    struct passwd *pw;

    pw = getpwnam(cfg->user);
    if (pw == NULL || pw->pw_uid != cfg->uid)
        return false;
    if (pipe2(ready, O_CLOEXEC) != 0)
        return false;
    if (pipe2(hold, O_CLOEXEC) != 0) {
        close(ready[0]);
        close(ready[1]);
        return false;
    }
    child = fork();
    if (child < 0) {
        close(ready[0]);
        close(ready[1]);
        close(hold[0]);
        close(hold[1]);
        return false;
    }
    if (child == 0) {
        close(ready[0]);
        close(hold[1]);
        if (initgroups(cfg->user, pw->pw_gid) != 0 ||
            setresgid(pw->pw_gid, pw->pw_gid, pw->pw_gid) != 0 ||
            setresuid(cfg->uid, cfg->uid, cfg->uid) != 0)
            _exit(125);
        marker = '1';
        if (write(ready[1], &marker, 1U) != 1)
            _exit(125);
        close(ready[1]);
        do {
            amount = read(hold[0], &marker, 1U);
        } while (amount < 0 && errno == EINTR);
        close(hold[0]);
        _exit(0);
    }

    close(ready[1]);
    close(hold[0]);
    do {
        amount = read(ready[0], &marker, 1U);
    } while (amount < 0 && errno == EINTR);
    close(ready[0]);
    if (amount != 1 || marker != '1' || !process_start_time(child, start_time)) {
        int status;
        close(hold[1]);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR)
            ;
        return false;
    }
    *subject_pid = child;
    *hold_fd = hold[1];
    return true;
}

static void stop_policy_subject(pid_t subject_pid, int hold_fd)
{
    int status;

    close(hold_fd);
    while (waitpid(subject_pid, &status, 0) < 0 && errno == EINTR)
        ;
}

static int check_authorization(const char *action, const char *subject,
                               bool exec_details)
{
    char *const simple_argv[] = {
        (char *)PKCHECK, "--action-id", (char *)action,
        "--process", (char *)subject, NULL
    };
    char *const exec_argv[] = {
        (char *)PKCHECK, "--action-id", (char *)action,
        "--process", (char *)subject,
        "--detail", "program", "/usr/bin/true", NULL
    };

    return run_fixed(exec_details ? exec_argv : simple_argv);
}
#endif

static bool polkit_state_active(const struct config *cfg, bool administrator_enabled)
{
#ifdef TESTING
    (void)cfg;
    (void)administrator_enabled;
    return true;
#else
    pid_t subject_pid;
    int hold_fd;
    unsigned long long start_time;
    char subject[128];
    struct timespec pause_time = { .tv_sec = 0, .tv_nsec = 50000000L };
    unsigned int attempt;
    bool active = false;

    if (!start_policy_subject(cfg, &subject_pid, &hold_fd, &start_time))
        return false;
    checked_snprintf(subject, sizeof(subject), "%ld,%llu,%lu",
                     (long)subject_pid, start_time, (unsigned long)cfg->uid);
    for (attempt = 0U; attempt < 60U; ++attempt) {
        int enable_result = check_authorization(ENABLE_ACTION, subject, false);
        int disable_result = check_authorization(DISABLE_ACTION, subject, false);

        if (administrator_enabled) {
            active = enable_result == 2 && disable_result == 2;
        } else {
            int generic_result = check_authorization(
                "org.freedesktop.policykit.exec", subject, true);
            active = enable_result == 2 && disable_result == 1 &&
                     generic_result == 1;
        }
        if (active)
            break;
        while (nanosleep(&pause_time, &pause_time) != 0 && errno == EINTR)
            ;
        pause_time.tv_sec = 0;
        pause_time.tv_nsec = 50000000L;
    }
    stop_policy_subject(subject_pid, hold_fd);
    return active;
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
    const char *test = getenv("OMARCHY_ESCALOCK_TEST_PKEXEC");
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
    if (!wheel_grant_layout_good(cfg))
        fail("the Omarchy wheel grant no longer matches the protected installation state");
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
    struct blob rule_on_template;

    if (path_absent(cfg->grant_path) && !path_absent(path_sudo_disabled))
        rename_managed(path_sudo_disabled, cfg->grant_path);
    if (load_file(path_rule_on_template, 0644, &rule_on_template)) {
        write_atomic(path_rule_file, &rule_on_template, 0644);
        free_blob(&rule_on_template);
    }
}

static void disable_mode(const struct config *cfg)
{
    enum mode_state state = current_state(cfg);
    struct blob rule_off_template;

    if (state == MODE_DISABLED) {
        puts("disabled");
        return;
    }
    if (state != MODE_ENABLED)
        fail("refusing to disable from an inconsistent state");
    verify_disable_preflight(cfg);
    if (!load_file(path_rule_off_template, 0644, &rule_off_template))
        fail("the OFF Polkit rule template is missing, modified, or unsafe");

    write_atomic(path_rule_file, &rule_off_template, 0644);
    free_blob(&rule_off_template);
    if (!polkit_state_active(cfg, false)) {
        rollback_disable(cfg);
        fail("Polkit did not activate the verified OFF policy; Administrator Mode remains enabled");
    }
    if (!try_rename_managed(cfg->grant_path, path_sudo_disabled)) {
        int saved = errno;
        rollback_disable(cfg);
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
    struct blob rule_off_template;

    if (!path_absent(cfg->grant_path) && path_absent(path_sudo_disabled))
        rename_managed(cfg->grant_path, path_sudo_disabled);
    if (load_file(path_rule_off_template, 0644, &rule_off_template)) {
        write_atomic(path_rule_file, &rule_off_template, 0644);
        free_blob(&rule_off_template);
    }
}

static void enable_mode(const struct config *cfg)
{
    enum mode_state state = current_state(cfg);
    struct blob sudo_template;
    struct blob rule_on_template;

    if (state == MODE_ENABLED) {
        if (!actions_registered() || !polkit_state_active(cfg, true))
            fail("Administrator Mode files are enabled but Polkit has not activated the verified ON policy");
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
    if (!load_file(path_rule_on_template, 0644, &rule_on_template))
        fail("the ON Polkit rule template is missing, modified, or unsafe");

    rename_managed(path_sudo_disabled, cfg->grant_path);
    if (!validate_sudo_file(path_sudoers_main)) {
        free_blob(&rule_on_template);
        rename_managed(cfg->grant_path, path_sudo_disabled);
        fail("restored sudo grant failed full visudo validation; OFF state retained");
    }
    write_atomic(path_rule_file, &rule_on_template, 0644);
    free_blob(&rule_on_template);
    if (!polkit_state_active(cfg, true)) {
        rollback_enable(cfg);
        fail("Polkit did not activate the verified ON policy; OFF state was restored");
    }
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
    openlog("omarchy-escalock", LOG_PID, LOG_AUTHPRIV);
    if (argc != 2 || (strcmp(argv[1], "version") != 0 &&
                      strcmp(argv[1], "status") != 0 &&
                      strcmp(argv[1], "enable") != 0 &&
                      strcmp(argv[1], "disable") != 0))
        fail("usage: omarchy-escalock-helper {version|status|enable|disable}");
    if (strcmp(argv[1], "version") == 0) {
        puts(ESCALOCK_VERSION);
        return 0;
    }
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

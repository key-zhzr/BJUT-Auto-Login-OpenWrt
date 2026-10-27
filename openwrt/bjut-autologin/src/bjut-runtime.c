// SPDX-License-Identifier: MIT
// Bounded process waits and read-only views. No credentials or network requests.
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <json-c/json.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define JSON_LIMIT (8U * 1024U * 1024U)
#define MAX_CHILDREN 64
typedef struct json_object J;
static const char *state_dir, *sys_net;
static int64_t now;

static J *get(J *o, const char *key) {
    J *v = NULL;
    if (o)
        json_object_object_get_ex(o, key, &v);
    return v;
}
static const char *str(J *o, const char *key) {
    const char *v = json_object_get_string(get(o, key));
    return v ? v : "";
}
static int64_t num(J *o, const char *key) { return json_object_get_int64(get(o, key)); }
static void text(J *o, const char *key, const char *value) {
    json_object_object_add(o, key, json_object_new_string(value ? value : ""));
}
static void number(J *o, const char *key, int64_t value) {
    json_object_object_add(o, key, json_object_new_int64(value));
}
static void boolean(J *o, const char *key, int value) {
    json_object_object_add(o, key, json_object_new_boolean(value));
}
static int safe_name(const char *s) {
    if (!s || !*s || strlen(s) > 256)
        return 0;
    for (; *s; s++)
        if (!isalnum((unsigned char)*s) && !strchr("_.:@,-", *s))
            return 0;
    return 1;
}
static void path(char *out, size_t n, const char *dir, const char *file) {
    if (snprintf(out, n, "%s/%s", dir, file) >= (int)n)
        out[0] = 0;
}
static J *load(const char *file) {
    struct stat st;
    if (lstat(file, &st) || !S_ISREG(st.st_mode) || st.st_size < 1 || st.st_size > JSON_LIMIT)
        return NULL;
    return json_object_from_file(file);
}
static J *state_json(const char *pattern, const char *id) {
    char name[512], file[PATH_MAX];
    snprintf(name, sizeof(name), pattern, id);
    path(file, sizeof(file), state_dir, name);
    return load(file);
}
static int read_line(const char *file, char *out, size_t n) {
    FILE *f = fopen(file, "r");
    if (!f)
        return 0;
    int ok = fgets(out, (int)n, f) != NULL;
    fclose(f);
    if (ok)
        out[strcspn(out, "\r\n")] = 0;
    return ok;
}
static int64_t read_int(const char *file) {
    char s[128], *end;
    if (!read_line(file, s, sizeof(s)))
        return 0;
    errno = 0;
    int64_t v = strtoll(s, &end, 10);
    return errno || *end ? 0 : v;
}
static uint64_t hash_file(uint64_t h, const char *file) {
    FILE *f = fopen(file, "rb");
    unsigned char buffer[4096];
    size_t n;
    // Include path/presence, then content; same-second edits also invalidate.
    for (const char *p = file; *p; p++) {
        h ^= (unsigned char)*p;
        h *= UINT64_C(1099511628211);
    }
    h ^= f ? 1 : 0;
    h *= UINT64_C(1099511628211);
    if (!f)
        return h;
    size_t total = 0;
    while ((n = fread(buffer, 1, sizeof(buffer), f))) {
        total += n;
        if (total > 1048576) {
            h = 0;
            break;
        }
        for (size_t i = 0; i < n; i++) {
            h ^= buffer[i];
            h *= UINT64_C(1099511628211);
        }
    }
    if (ferror(f))
        h = 0;
    fclose(f);
    return h;
}
static void fingerprint(const char *config, const char *delta, char out[17]) {
    uint64_t h = hash_file(UINT64_C(14695981039346656037), config);
    if (h)
        h = hash_file(h, delta);
    if (!h) {
        out[0] = 0;
        return;
    }
    snprintf(out, 17, "%016" PRIx64, h);
}

typedef struct {
    pid_t pid;
    unsigned long long start;
} Child;
static int proc_info(pid_t pid, unsigned long long *start, pid_t *parent, char *state) {
#ifdef __linux__
    char file[64], line[8192], *p, *end;
    snprintf(file, sizeof(file), "/proc/%ld/stat", (long)pid);
    if (!read_line(file, line, sizeof(line)) || !(p = strrchr(line, ')')))
        return 0;
    p += 2;
    *state = *p;
    p += 2;
    *parent = (pid_t)strtol(p, &end, 10);
    if (p == end)
        return 0;
    p = end;
    // starttime is field 22; p currently follows field 4.
    for (int field = 5; field <= 22; field++) {
        while (*p == ' ')
            p++;
        unsigned long long v = strtoull(p, &end, 10);
        if (p == end)
            return 0;
        if (field == 22)
            *start = v;
        p = end;
    }
    return 1;
#else
    *start = 0;
    *parent = 0;
    *state = 'S';
    return kill(pid, 0) == 0;
#endif
}
static int alive(Child child) {
    unsigned long long start = 0;
    pid_t parent = 0;
    char state = 0;
    return child.pid > 1 && proc_info(child.pid, &start, &parent, &state) && start == child.start &&
           state != 'Z' && state != 'X';
}
static int child_token(const char *s, Child *child) {
    long pid;
    char end;
    return sscanf(s, "%ld:%llu%c", &pid, &child->start, &end) == 2 && pid > 1 && pid <= INT_MAX &&
           (child->pid = (pid_t)pid) > 1;
}
static int64_t monotonic_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t))
        return 0;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void pause_ms(long ms) {
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000};
    while (nanosleep(&t, &t) && errno == EINTR) {
    }
}
static int wait_children(int argc, char **argv) {
    if (argc < 1)
        return 2;
    char *end;
    long ms = strtol(argv[0], &end, 10);
    if (*end || ms < 0 || ms > 5000)
        return 2;
    int64_t deadline = monotonic_ms() + ms;
    do {
        int living = 0;
        for (int i = 1; i < argc; i++) {
            Child c;
            if (child_token(argv[i], &c) && alive(c))
                living++;
        }
        if (!living)
            return 0;
        pause_ms(20);
    } while (monotonic_ms() < deadline);
    return 1;
}
static int wait_probes(int argc, char **argv) {
    if (argc < 3 || argc > MAX_CHILDREN + 3)
        return 2;
    const char *directory = argv[0];
    char *end;
    long seconds = strtol(argv[1], &end, 10);
    Child owner;
    if (*end || seconds < 1 || seconds > 35 || !child_token(argv[2], &owner))
        return 2;
    int64_t deadline = monotonic_ms() + seconds * 1000;
    const char *targets[] = {"configured", "ustc", "alidns"};
    do {
        struct stat st;
        if (!alive(owner) || stat(directory, &st) || !S_ISDIR(st.st_mode))
            return 1;
        int done = 0;
        char file[PATH_MAX];
        for (int i = 0; i < 3; i++) {
            snprintf(file, sizeof(file), "%s/%s/ok", directory, targets[i]);
            if (!access(file, F_OK))
                return 0;
            snprintf(file, sizeof(file), "%s/%s/done", directory, targets[i]);
            if (!access(file, F_OK))
                done++;
        }
        if (done == 3)
            return 1;
        int living = 0;
        for (int i = 3; i < argc; i++) {
            Child c;
            if (child_token(argv[i], &c) && alive(c))
                living++;
        }
        if (!living)
            return 1;
        pause_ms(50);
    } while (monotonic_ms() < deadline);
    return 1;
}

// One-time recovery of old releases: only PID-1 children of this executable
// whose probe output still names a deleted private work directory qualify.
static int reap_probes(const char *directory, const char *executable) {
#ifdef __linux__
    char base[PATH_MAX], file[PATH_MAX], target[PATH_MAX], cmd[4096];
    if (!realpath(directory, base))
        return 1;
    DIR *d = opendir("/proc");
    if (!d)
        return 1;
    struct dirent *entry;
    Child children[MAX_CHILDREN];
    int count = 0;
    while ((entry = readdir(d)) && count < MAX_CHILDREN) {
        char *end;
        long pid = strtol(entry->d_name, &end, 10);
        if (*end || pid <= 1 || pid > INT_MAX)
            continue;
        unsigned long long start = 0;
        pid_t parent = 0;
        char state = 0;
        if (!proc_info((pid_t)pid, &start, &parent, &state) || parent != 1)
            continue;
        snprintf(file, sizeof(file), "/proc/%ld/fd/1", pid);
        ssize_t n = readlink(file, target, sizeof(target) - 1);
        if (n < 0)
            continue;
        target[n] = 0;
        size_t len = strlen(base);
        if (strncmp(target, base, len) || strncmp(target + len, "/work.", 6))
            continue;
        const char *suffix = strrchr(target, '/');
        if (!suffix || (strcmp(suffix, "/probe4 (deleted)") && strcmp(suffix, "/probe6 (deleted)")))
            continue;
        snprintf(file, sizeof(file), "/proc/%ld/cmdline", pid);
        FILE *f = fopen(file, "rb");
        if (!f)
            continue;
        n = (ssize_t)fread(cmd, 1, sizeof(cmd) - 1, f);
        fclose(f);
        if (n < 1)
            continue;
        cmd[n] = 0;
        int ours = 0;
        for (ssize_t offset = 0; offset < n;) {
            size_t length = strnlen(cmd + offset, (size_t)(n - offset));
            if (!strcmp(cmd + offset, executable))
                ours = 1;
            offset += (ssize_t)length + 1;
        }
        if (!ours)
            continue;
        Child c = {(pid_t)pid, start};
        if (alive(c)) {
            kill(c.pid, SIGTERM);
            children[count++] = c;
        }
    }
    closedir(d);
    if (count)
        pause_ms(200);
    for (int i = 0; i < count; i++)
        if (alive(children[i]))
            kill(children[i].pid, SIGKILL);
    printf("%d\n", count);
    return 0;
#else
    (void)directory;
    (void)executable;
    return 0;
#endif
}

static int active(J *s) {
    const char *v = str(s, "state");
    return !strcmp(str(s, "session"), "online") || !strcmp(v, "online") ||
           !strcmp(v, "authenticated_limited") || !strcmp(v, "probe_uncertain") ||
           !strcmp(v, "login_accepted");
}
static J *status_one(J *ctx, J *u) {
    const char *id = str(u, "id");
    char file[PATH_MAX], line[512];
    J *s = state_json(!strcmp(id, "main") && !num(ctx, "configured") ? "%s.json" : "uplink-%s.json",
                      !strcmp(id, "main") && !num(ctx, "configured") ? "status" : id);
    if (s && !json_object_is_type(s, json_type_object)) {
        json_object_put(s);
        s = NULL;
    }
    if (!s) {
        s = json_object_new_object();
        text(s, "id", id);
        text(s, "state", "stopped");
        text(s, "message", "等待检测");
    }
    int checking = 0;
    const char *message = "";
    char phase[512] = "";
    snprintf(line, sizeof(line), "phase-%s", id);
    path(file, sizeof(file), state_dir, line);
    FILE *f = fopen(file, "r");
    if (f) {
        long pid = 0;
        long long started = 0;
        if (fscanf(f, "%ld %lld\n", &pid, &started) == 2 && pid > 1 && kill((pid_t)pid, 0) == 0 &&
            now - started < 180) {
            checking = 1;
            if (fgets(phase, sizeof(phase), f)) {
                phase[strcspn(phase, "\r\n")] = 0;
                message = phase;
            }
        }
        fclose(f);
    }
    snprintf(line, sizeof(line), "manual-%s", id);
    path(file, sizeof(file), state_dir, line);
    struct stat st;
    if (!stat(file, &st) && st.st_size) {
        checking = 1;
        message = "操作已排队，即将处理";
    }
    number(s, "checking", checking);
    text(s, "check_message", message);
    int64_t updated = num(s, "updated_at"), age = updated > 0 && now >= updated ? now - updated : 0,
            valid = num(ctx, "interval") * 3 + 30;
    number(s, "age_seconds", age);
    number(s, "valid_for", valid);
    number(s, "stale", updated <= 0 || now < updated || age > valid);
    J *op = state_json("operation-%s.json", id);
    if (op && !json_object_is_type(op, json_type_object)) {
        json_object_put(op);
        op = NULL;
    }
    if (!op)
        op = json_object_new_object();
    const char *state = str(op, "state");
    if ((!strcmp(state, "queued") || !strcmp(state, "running") || !strcmp(state, "verifying")) &&
        num(op, "deadline") > 0 && now >= num(op, "deadline")) {
        text(op, "state", "timeout");
        text(op, "phase", "操作等待超时，请刷新状态后再决定是否重试");
    }
    J *public_op = json_object_new_object();
    const char *op_keys[] = {"id",         "action",     "account",  "state",   "phase",
                             "created_at", "updated_at", "deadline", "duration"};
    for (size_t i = 0; i < sizeof(op_keys) / sizeof(op_keys[0]); i++)
        if (*str(op, op_keys[i]))
            text(public_op, op_keys[i], str(op, op_keys[i]));
    json_object_put(op);
    json_object_object_add(s, "operation", public_op);
    return s;
}
static J *statuses(J *ctx) {
    static const char *features[] = {
        "dashboard",          "ports",           "billing",        "logs",
        "settings",           "account_set",     "account_manage", "uplink_manage",
        "billing_records",    "log_settings",    "pushplus",       "pushplus_status",
        "uplink_actions",     "billing_actions", "operations",     "account_limits",
        "billing_background", "device_usage",    "traffic_charts", "traffic_compression",
        "billing_center",     "maintenance"};
    J *o = json_object_new_object(), *caps = json_object_new_array(),
      *rows = json_object_new_array(), *uplinks = get(ctx, "uplinks");
    number(o, "generated_at", now);
    number(o, "apiVersion", 1);
    text(o, "version", str(ctx, "version"));
    for (size_t i = 0; i < sizeof(features) / sizeof(features[0]); i++)
        json_object_array_add(caps, json_object_new_string(features[i]));
    json_object_object_add(o, "capabilities", caps);
    for (size_t i = 0; i < json_object_array_length(uplinks); i++)
        json_object_array_add(rows, status_one(ctx, json_object_array_get_idx(uplinks, i)));
    json_object_object_add(o, "uplinks", rows);
    return o;
}
static J *ports(J *ctx, J *status) {
    J *out = json_object_new_object(), *rows = json_object_new_array(),
      *uplinks = get(ctx, "uplinks"), *states = get(status, "uplinks");
    for (size_t i = 0; i < json_object_array_length(uplinks); i++) {
        J *u = json_object_array_get_idx(uplinks, i), *s = json_object_array_get_idx(states, i),
          *o = json_object_new_object();
        const char *device = str(s, "device");
        if (!safe_name(device))
            device = str(u, "device");
        if (!safe_name(device))
            device = "";
        text(o, "uplink", str(u, "id"));
        text(o, "device", device);
        const char *metrics[] = {"carrier", "speed", "statistics/rx_bytes", "statistics/tx_bytes"},
                   *keys[] = {"linkUp", "speedMbps", "rxBytes", "txBytes"};
        for (int j = 0; j < 4; j++) {
            char file[PATH_MAX], value[128] = "0";
            snprintf(file, sizeof(file), "%s/%s/%s", sys_net, device, metrics[j]);
            if (*device && !read_line(file, value, sizeof(value)))
                strcpy(value, "0");
            int valid = *value != 0;
            for (char *p = value; *p; p++)
                if (!isdigit((unsigned char)*p))
                    valid = 0;
            if (!valid)
                strcpy(value, "0");
            if (!j)
                number(o, keys[j], strtoll(value, NULL, 10));
            else
                text(o, keys[j], value);
        }
        json_object_array_add(rows, o);
    }
    json_object_object_add(out, "ports", rows);
    return out;
}
static J *accounts(J *ctx, J *status) {
    J *out = json_object_new_object(), *rows = json_object_new_array(),
      *accts = get(ctx, "accounts"), *states = get(status, "uplinks");
    for (size_t i = 0; i < json_object_array_length(accts); i++) {
        J *a = json_object_array_get_idx(accts, i), *o = json_object_new_object();
        const char *user = str(a, "user");
        text(o, "id", str(a, "id"));
        text(o, "user", user);
        text(o, "loginType", str(a, "loginType"));
        number(o, "enabled", num(a, "enabled"));
        number(o, "hasPassword", num(a, "hasPassword"));
        number(o, "configuredMaxSessions", num(a, "configuredMaxSessions"));
        int limit = 3, count = 0;
        char name[256], file[PATH_MAX], signature[128], at[128], plan[512];
        snprintf(name, sizeof(name), "account-plan-%s", str(a, "key"));
        path(file, sizeof(file), state_dir, name);
        FILE *f = fopen(file, "r");
        if (f) {
            if (fgets(signature, sizeof(signature), f) && fgets(at, sizeof(at), f) &&
                fgets(plan, sizeof(plan), f)) {
                signature[strcspn(signature, "\r\n")] = 0;
                plan[strcspn(plan, "\r\n")] = 0;
                int64_t updated = strtoll(at, NULL, 10);
                if (!strcmp(signature, str(a, "signature")) && now >= updated &&
                    now - updated <= 86400 && !strcmp(plan, "VIP套餐"))
                    limit = 5;
            }
            fclose(f);
        }
        int requested = (int)num(a, "configuredMaxSessions");
        if (requested > 0 && requested < limit)
            limit = requested;
        for (size_t j = 0; j < json_object_array_length(states); j++) {
            J *s = json_object_array_get_idx(states, j);
            if (active(s) && !strcmp(str(s, "account"), user))
                count++;
        }
        number(o, "maxSessions", limit);
        number(o, "onlineCount", count);
        json_object_array_add(rows, o);
    }
    json_object_object_add(out, "accounts", rows);
    return out;
}
static J *billing_cached(J *ctx) {
    J *out = json_object_new_object(), *rows = json_object_new_array(),
      *accts = get(ctx, "accounts");
    for (size_t i = 0; i < json_object_array_length(accts); i++) {
        J *a = json_object_array_get_idx(accts, i),
          *o = state_json("billing-latest/%s.json", str(a, "key")),
          *error = state_json("billing-latest/%s-error.json", str(a, "key"));
        if (!o && !error)
            continue;
        if (!o) {
            o = json_object_new_object();
            text(o, "account", str(a, "user"));
            text(o, "state", "error");
        }
        if (error) {
            text(o, "backgroundState", str(error, "state"));
            text(o, "backgroundMessage", str(error, "message"));
            json_object_put(error);
        }
        json_object_array_add(rows, o);
    }
    json_object_object_add(out, "items", rows);
    return out;
}

// Traffic assembly lives here so UI polling never forks per account/field/row.
static int fields(char *line, char **v, int max) {
    int n = 0;
    char *p = line;
    line[strcspn(line, "\r\n")] = 0;
    while (n < max) {
        v[n++] = p;
        p = strchr(p, '\t');
        if (!p)
            break;
        *p++ = 0;
    }
    return n;
}
static int digits(const char *s) {
    if (!*s)
        return 0;
    for (; *s; s++)
        if (!isdigit((unsigned char)*s))
            return 0;
    return 1;
}
static int decimal(const char *s) {
    int dot = 0;
    if (!isdigit((unsigned char)*s))
        return 0;
    for (; *s; s++) {
        if (*s == '.' && !dot) {
            if (!isdigit((unsigned char)s[1]))
                return 0;
            dot = 1;
            continue;
        }
        if (!isdigit((unsigned char)*s))
            return 0;
    }
    return 1;
}
static J *account_map(J *ctx, int short_key) {
    J *map = json_object_new_object(), *a = get(ctx, "accounts");
    for (size_t i = 0; i < json_object_array_length(a); i++) {
        J *v = json_object_array_get_idx(a, i);
        char key[65];
        snprintf(key, sizeof(key), short_key ? "%.16s" : "%s", str(v, "key"));
        json_object_object_add(map, key, json_object_get(v));
    }
    return map;
}
static int history(J *out, J *ctx, J *request, int all) {
    char file[PATH_MAX], line[4096], *v[12], key[1024];
    J *daily = json_object_new_array(), *channels = json_object_new_array(),
      *buckets = json_object_new_array(), *timeline = json_object_new_object(),
      *map = account_map(ctx, 0), *short_map = account_map(ctx, 1),
      *totals = json_object_new_object(), *ids = json_object_new_object();
    path(file, sizeof(file), state_dir, "usage-samples.tsv");
    FILE *f = fopen(file, "r");
    if (!f)
        goto missing;
    while (fgets(line, sizeof(line), f)) {
        int n = fields(line, v, 12);
        if ((n != 6 && n != 7) || (!all && (n != 7 || strcmp(v[6], "1"))) || !decimal(v[4]) ||
            !digits(v[5]))
            continue;
        J *a = get(map, v[1]);
        if (!a)
            continue;
        snprintf(key, sizeof(key), "%s|%s|%s|%s|%d", v[1], v[0], v[2], v[3],
                 n == 7 && !strcmp(v[6], "1"));
        J *row = get(totals, key);
        if (!row) {
            row = json_object_new_object();
            text(row, "account", str(a, "user"));
            text(row, "day", v[0]);
            text(row, "device", v[2]);
            text(row, "label", v[3]);
            boolean(row, "local", n == 7 && !strcmp(v[6], "1"));
            json_object_object_add(totals, key, row);
            json_object_array_add(daily, json_object_get(row));
        }
        double amount = json_object_get_double(get(row, "usedMb")) + strtod(v[4], NULL);
        char formatted[128];
        snprintf(formatted, sizeof(formatted), "%.3f", amount);
        json_object_object_add(row, "usedMb", json_object_new_double_s(amount, formatted));
        number(row, "sampledSeconds", num(row, "sampledSeconds") + strtoll(v[5], NULL, 10));
    }
    fclose(f);
    int64_t first = num(request, "start"),
            last = get(request, "end") ? num(request, "end") : INT64_C(41024448000),
            resolution = num(request, "resolution");
    if (first < 0)
        first = 0;
    if (last < 0)
        last = INT64_C(41024448000);
    if (resolution != 60 && resolution != 3600 && resolution != 86400)
        resolution = 0;
    int monthly = !strcmp(str(request, "monthly"), "true") || !strcmp(str(request, "monthly"), "1");
    int64_t day = (first + 28800) / 86400 * 86400 - 28800,
            hour = (first + 28800) / 3600 * 3600 - 28800;
    path(file, sizeof(file), state_dir, "usage-curves.tsv");
    f = fopen(file, "r");
    if (!f)
        goto missing;
    while (fgets(line, sizeof(line), f)) {
        int n = fields(line, v, 12);
        if ((n != 9 && n != 11) || (!all && strcmp(v[6], "1")) || !digits(v[0]) || !digits(v[1]) ||
            !decimal(v[7]) || !digits(v[8]) || !safe_name(v[4]) || !safe_name(v[5]))
            continue;
        J *a = get(short_map, v[2]);
        if (!a)
            continue;
        int64_t r = strtoll(v[0], NULL, 10), at = strtoll(v[1], NULL, 10);
        if (r != 60 && r != 3600 && r != 86400)
            continue;
        int selected = !resolution ||
                       (r == resolution &&
                        at >= (first + 28800) / resolution * resolution - 28800 && at <= last),
            prefix = monthly && at < first && at >= first - 2764800 &&
                     ((r == 86400 && at < day) || (r == 3600 && at >= day && at < hour) ||
                      (r == 60 && at >= hour));
        if (!selected && !prefix)
            continue;
        snprintf(key, sizeof(key), "%s|%s|%s|%s|%s", v[2], v[3], v[4], v[5], v[6]);
        J *id = get(ids, key);
        int index;
        if (!id) {
            index = (int)json_object_array_length(channels);
            J *c = json_object_new_object();
            text(c, "account", str(a, "user"));
            text(c, "device", v[3]);
            text(c, "interfaceId", v[4]);
            text(c, "interfaceName", v[5]);
            boolean(c, "local", !strcmp(v[6], "1"));
            json_object_array_add(channels, c);
            json_object_object_add(ids, key, json_object_new_int(index));
        } else
            index = json_object_get_int(id);
        J *b = json_object_new_array();
        json_object_array_add(b, json_object_new_int(index));
        json_object_array_add(b, json_object_new_int64(r));
        json_object_array_add(b, json_object_new_int64(at));
        json_object_array_add(b, json_object_new_double(strtod(v[7], NULL)));
        json_object_array_add(b, json_object_new_int64(strtoll(v[8], NULL, 10)));
        if (n == 11 && digits(v[9]) && digits(v[10]) && strtoll(v[9], NULL, 10) > 0 &&
            strtoll(v[10], NULL, 10) > 0) {
            json_object_array_add(b, json_object_new_int64(strtoll(v[9], NULL, 10)));
            json_object_array_add(b, json_object_new_int64(strtoll(v[10], NULL, 10)));
        }
        json_object_array_add(buckets, b);
    }
    fclose(f);
    json_object_object_add(out, "history", daily);
    json_object_object_add(timeline, "channels", channels);
    json_object_object_add(timeline, "buckets", buckets);
    json_object_object_add(out, "timeline", timeline);
    json_object_put(map);
    json_object_put(short_map);
    json_object_put(totals);
    json_object_put(ids);
    return 1;
missing:
    json_object_put(daily);
    json_object_put(channels);
    json_object_put(buckets);
    json_object_put(timeline);
    json_object_put(map);
    json_object_put(short_map);
    json_object_put(totals);
    json_object_put(ids);
    return 0;
}
static J *traffic(J *ctx, J *status, J *request) {
    J *out = json_object_new_object(), *rows = json_object_new_array(),
      *accts = get(ctx, "accounts"), *states = get(status, "uplinks"),
      *seen = json_object_new_object();
    int enabled = (int)num(ctx, "trafficEnabled"), all = !strcmp(str(ctx, "scope"), "all");
    boolean(out, "enabled", enabled);
    text(out, "scope", str(ctx, "scope"));
    json_object_object_add(out, "accounts", rows);
    json_object_object_add(out, "series", json_object_new_array());
    if (!enabled) {
        json_object_object_add(out, "history", json_object_new_array());
        json_object_put(seen);
        return out;
    }
    for (size_t i = 0; i < json_object_array_length(accts); i++) {
        J *a = json_object_array_get_idx(accts, i);
        const char *user = str(a, "user"), *key = str(a, "key");
        int selected = all;
        if (!all)
            for (size_t j = 0; j < json_object_array_length(states); j++) {
                J *s = json_object_array_get_idx(states, j);
                const char *v = str(s, "state");
                if (strcmp(v, "online") && strcmp(v, "authenticated_limited") &&
                    strcmp(v, "login_accepted") && strcmp(v, "probe_uncertain"))
                    continue;
                char u1[257], u2[257];
                snprintf(u1, sizeof(u1), "%s", user);
                snprintf(u2, sizeof(u2), "%s", str(s, "account"));
                char *p = strstr(u1, "@campus");
                if (p && !p[7])
                    *p = 0;
                p = strstr(u2, "@campus");
                if (p && !p[7])
                    *p = 0;
                if (!strcmp(u1, u2))
                    selected = 1;
            }
        if (!selected || get(seen, key))
            continue;
        boolean(seen, key, 1);
        J *o = json_object_new_object(), *meta = state_json("traffic/%s-meta.json", key);
        char name[256], file[PATH_MAX], error[4096];
        text(o, "account", user);
        snprintf(name, sizeof(name), "traffic/%s-at", key);
        path(file, sizeof(file), state_dir, name);
        number(o, "updatedAt", read_int(file));
        text(o, "remainingFlow",
             num(meta, "remainingFlowUnlimited") == 1 ? "无限" : str(meta, "remainingFlow"));
        text(o, "balance", str(meta, "balance"));
        json_object_put(meta);
        snprintf(name, sizeof(name), "traffic/%s-error", key);
        path(file, sizeof(file), state_dir, name);
        if (read_line(file, error, sizeof(error)) && *error)
            text(o, "error", error);
        snprintf(name, sizeof(name), "traffic/%%s-devices-%s.json", all ? "all" : "local");
        J *devices = state_json(name, key);
        json_object_object_add(o, "devices", devices ? devices : json_object_new_array());
        json_object_array_add(rows, o);
    }
    json_object_put(seen);
    json_object_object_add(out, "retention", json_object_get(get(ctx, "retention")));
    if (!history(out, ctx, request, all)) {
        json_object_put(out);
        return NULL;
    }
    J *switches = json_object_new_array();
    char file[PATH_MAX], line[2048], *v[7];
    path(file, sizeof(file), state_dir, "traffic-switches.tsv");
    FILE *f = fopen(file, "r");
    if (f) {
        int count = 0;
        while (fgets(line, sizeof(line), f) && ++count <= 2000) {
            int n = fields(line, v, 7);
            if (n < 5 || !digits(v[0]) || !safe_name(v[1]) || !safe_name(v[2]) ||
                (*v[3] && !safe_name(v[3])) || (*v[4] && !safe_name(v[4])))
                continue;
            J *s = json_object_new_object();
            number(s, "at", strtoll(v[0], NULL, 10));
            text(s, "interfaceId", v[1]);
            text(s, "interfaceName", v[2]);
            text(s, "from", v[3]);
            text(s, "to", v[4]);
            text(s, "reason", n >= 6 && *v[5] ? v[5] : "原因未记录");
            json_object_array_add(switches, s);
        }
        fclose(f);
    }
    json_object_object_add(out, "switches", switches);
    return out;
}

static int snapshot(int argc, char **argv) {
    if (argc != 6)
        return 2;
    const char *method = argv[0];
    state_dir = argv[2];
    sys_net = argv[3];
    char file[PATH_MAX], signature[17];
    fingerprint(argv[4], argv[5], signature);
    path(file, sizeof(file), state_dir, "view-context.json");
    J *ctx = load(file);
    if (!*signature || !ctx || num(ctx, "schema") != 1 ||
        strcmp(str(ctx, "fingerprint"), signature) ||
        !json_object_is_type(get(ctx, "uplinks"), json_type_array) ||
        !json_object_is_type(get(ctx, "accounts"), json_type_array) ||
        json_object_array_length(get(ctx, "uplinks")) > 64 ||
        json_object_array_length(get(ctx, "accounts")) > 256) {
        json_object_put(ctx);
        return 75;
    }
    now = (int64_t)time(NULL);
    J *out = NULL, *status = NULL, *request = NULL;
    if (!strcmp(method, "billing_cached"))
        out = billing_cached(ctx);
    else {
        status = statuses(ctx);
        if (!strcmp(method, "status"))
            out = json_object_get(status);
        else if (!strcmp(method, "ports"))
            out = ports(ctx, status);
        else if (!strcmp(method, "accounts"))
            out = accounts(ctx, status);
        else if (!strcmp(method, "dashboard")) {
            out = json_object_new_object();
            json_object_object_add(out, "status", json_object_get(status));
            json_object_object_add(out, "ports", ports(ctx, status));
            json_object_object_add(out, "accounts", accounts(ctx, status));
        } else if (!strcmp(method, "traffic")) {
            request = load(argv[1]);
            out = traffic(ctx, status, request);
        }
    }
    int rc = 75;
    if (out) {
        const char *s = json_object_to_json_string_ext(out, JSON_C_TO_STRING_PLAIN);
        if (strlen(s) <= JSON_LIMIT) {
            puts(s);
            rc = 0;
        }
    }
    json_object_put(out);
    json_object_put(request);
    json_object_put(status);
    json_object_put(ctx);
    return rc;
}
int main(int argc, char **argv) {
    if (argc < 2)
        return 2;
    if (!strcmp(argv[1], "snapshot"))
        return snapshot(argc - 2, argv + 2);
    if (!strcmp(argv[1], "fingerprint") && argc == 4) {
        char value[17];
        fingerprint(argv[2], argv[3], value);
        if (!*value)
            return 1;
        puts(value);
        return 0;
    }
    if (!strcmp(argv[1], "wait-probes"))
        return wait_probes(argc - 2, argv + 2);
    if (!strcmp(argv[1], "wait-children"))
        return wait_children(argc - 2, argv + 2);
    if (!strcmp(argv[1], "reap-probes") && argc == 4)
        return reap_probes(argv[2], argv[3]);
    if (!strcmp(argv[1], "pause") && argc == 3) {
        char *end;
        long ms = strtol(argv[2], &end, 10);
        if (*end || ms < 1 || ms > 1000)
            return 2;
        pause_ms(ms);
        return 0;
    }
    return 2;
}

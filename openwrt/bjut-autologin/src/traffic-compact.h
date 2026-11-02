/* Checkpoint maintenance runs at low priority once per 15 minutes. No row
 * quotas, uncompressed-size quota, or per-resolution capacity partitions. */
typedef struct {
    int64_t at, amount, start, end;
    uint64_t seconds;
    uint32_t channel, resolution;
    unsigned char kind, legacy;
} StoreRow;
typedef struct {
    StoreRow *rows;
    size_t count, capacity;
    TioDictionary dict[3];
} StoreRows;

static int store_path(char *out, const char *directory, const char *name) {
    return snprintf(out, PATH_MAX, "%s/%s", directory, name) < PATH_MAX;
}
static int store_copy(const char *from, const char *to) {
    FILE *in = tio_file(from);
    if (!in) return 0;
    int fd = open(to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) { fclose(in); return 0; }
    FILE *out = fdopen(fd, "wb");
    if (!out) { close(fd); fclose(in); unlink(to); return 0; }
    char buffer[32768]; size_t n; int ok = 1;
    while ((n = fread(buffer, 1, sizeof(buffer), in)))
        if (fwrite(buffer, 1, n, out) != n) { ok = 0; break; }
    if (ferror(in)) ok = 0;
    if (fclose(in)) ok = 0;
    if (fclose(out)) ok = 0;
    if (!ok) unlink(to);
    return ok;
}
static int store_empty(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return 0;
    return close(fd) == 0;
}
static int store_verify(const char *kind, const char *packed) {
    TioReader reader; char line[TIO_LINE]; int code;
    if (!tio_open(&reader, kind, packed, "/dev/null")) return 0;
    do { code = tio_next(&reader, line, sizeof(line)); } while (code > 0);
    tio_close(&reader);
    return code == 0;
}
static void store_remove_directory(const char *directory) {
    const char *names[] = {"usage-curves.tsv.dict.gz", "usage-samples.tsv.dict.gz", "usage-curves.tsv.index", "usage-curves.tsv", "usage-samples.tsv", NULL};
    char path[PATH_MAX];
    for (int i = 0; names[i]; i++) if (store_path(path, directory, names[i])) unlink(path);
    rmdir(directory);
}
static int store_publish(const char *state, const char *directory, int initial) {
    char temporary[PATH_MAX], current[PATH_MAX];
    if (!store_path(current, state, "traffic-store-current") ||
        snprintf(temporary, sizeof(temporary), "%s/traffic-manifest.XXXXXX", state) >= (int)sizeof(temporary)) return 0;
    int fd = mkstemp(temporary);
    if (fd < 0) return 0;
    const char *base = strrchr(directory, '/');
    base = base ? base + 1 : directory;
    size_t length = strlen(base);
    int ok = write(fd, base, length) == (ssize_t)length && write(fd, "\n", 1) == 1;
    if (close(fd)) ok = 0;
    if (ok) ok = initial ? link(temporary, current) == 0 : rename(temporary, current) == 0;
    unlink(temporary);
    return ok;
}
static int store_init(const char *state, const char *samples, const char *curves) {
    char directory[PATH_MAX], input[PATH_MAX], raw[PATH_MAX], packed[PATH_MAX];
    if (tio_directory(state, directory, sizeof(directory))) return 0;
    if (snprintf(directory, sizeof(directory), "%s/traffic-store.XXXXXX", state) >= (int)sizeof(directory) || !mkdtemp(directory)) return 1;
    const char *names[] = {"samples", "curves"}, *persisted[] = {samples, curves};
    int ok = 1;
    for (int i = 0; i < 2 && ok; i++) {
        snprintf(raw, sizeof(raw), "%s/usage-%s.tsv", state, names[i]);
        snprintf(packed, sizeof(packed), "%s/usage-%s.tsv.dict.gz", directory, names[i]);
        struct stat st, gzst, rawst;
        snprintf(input, sizeof(input), "%s.dict.gz", persisted[i]);
        int have_raw = lstat(raw, &st) == 0 && S_ISREG(st.st_mode);
        int have_gz = lstat(input, &gzst) == 0 && S_ISREG(gzst.st_mode);
        int have_legacy = lstat(persisted[i], &rawst) == 0 && S_ISREG(rawst.st_mode);
        if (have_raw) ok = pack(names[i], raw, packed) == 0;
        else if (have_gz && (!have_legacy || gzst.st_mtime >= rawst.st_mtime)) {
            ok = store_copy(input, packed);
            if (i == 1) {
                snprintf(input, sizeof(input), "%s.index", persisted[i]);
                snprintf(raw, sizeof(raw), "%s/usage-curves.tsv.index", directory);
                if (!access(input, F_OK)) ok = ok && store_copy(input, raw);
            }
        }
        else if (have_legacy) ok = pack(names[i], persisted[i], packed) == 0;
        else {
            snprintf(input, sizeof(input), "%s/usage-%s.tsv", directory, names[i]);
            ok = store_empty(input) && pack(names[i], input, packed) == 0;
        }
        snprintf(input, sizeof(input), "%s/usage-%s.tsv", directory, names[i]);
        if (access(input, F_OK) && !store_empty(input)) ok = 0;
        if (ok) ok = store_verify(names[i], packed);
    }
    if (ok && !store_publish(state, directory, 1)) {
        /* Another initializer may have published the same legacy data. */
        ok = tio_directory(state, input, sizeof(input));
        store_remove_directory(directory);
    } else if (!ok) store_remove_directory(directory);
    return ok ? 0 : 1;
}
static int store_stream(const char *kind, const char *state, int64_t first, int64_t last) {
    if (strcmp(kind, "curves") && strcmp(kind, "samples")) return 2;
    TioReader reader; char line[TIO_LINE]; int code = 0;
    if (!tio_open_state(&reader, state, kind)) return 1;
    if (!tio_seek(&reader, first, last)) { tio_close(&reader); return 1; }
    while ((code = tio_next(&reader, line, sizeof(line))) > 0)
        if (fputs(line, stdout) == EOF) { code = -1; break; }
    tio_close(&reader);
    return code == 0 && !ferror(stdout) ? 0 : 1;
}
static int store_uint(const char *text, int64_t *out) {
    if (!*text) return 0;
    uint64_t n = 0;
    for (; *text; text++) {
        if (*text < '0' || *text > '9' || n > (uint64_t)(INT64_MAX - (*text - '0')) / 10) return 0;
        n = n * 10 + (unsigned)(*text - '0');
    }
    *out = (int64_t)n; return 1;
}
static int store_amount(const char *text, int64_t *out) {
    char *end; errno = 0; double n = strtod(text, &end);
    if (!*text || *end || errno || !(n >= 0) || n >= (double)INT64_MAX / 1000) return 0;
    *out = (int64_t)(n * 1000 + .5); return 1;
}
static int64_t store_day(const char *text) {
    int y, m, d; char suffix;
    if (sscanf(text, "%4d-%2d-%2d%c", &y, &m, &d, &suffix) != 3 || y < 1970 || m < 1 || m > 12 || d < 1 || d > 31) return -1;
    /* Civil date to Unix day, without process-local timezone or 32-bit time. */
    y -= m <= 2;
    int era = y / 400, year = y - era * 400;
    int doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    return ((int64_t)era * 146097 + year * 365 + year / 4 - year / 100 + doy - 719468) * 86400 - 28800;
}
static int store_channel(TioDictionary *dict, const char *meta) {
    for (size_t i = 0; i < dict->count; i++) if (!strcmp(dict->items[i], meta)) return (int)i;
    return tio_dict_add(dict, meta);
}
static int store_append(StoreRows *rows, StoreRow row) {
    if (rows->count == rows->capacity) {
        size_t capacity = rows->capacity ? rows->capacity + rows->capacity / 2 : 4096;
        if (capacity > SIZE_MAX / sizeof(row)) return 0;
        StoreRow *values = realloc(rows->rows, capacity * sizeof(row));
        if (!values) return 0;
        rows->rows = values; rows->capacity = capacity;
    }
    rows->rows[rows->count++] = row; return 1;
}
static int store_load(StoreRows *rows, const char *state, int kind, int64_t now, const int64_t *retention) {
    TioReader reader; char line[TIO_LINE], meta[TIO_LINE], *p[12]; int code;
    if (!tio_open_state(&reader, state, kind ? "samples" : "curves")) return 0;
    while ((code = tio_next(&reader, line, sizeof(line))) > 0) {
        int n = tio_fields(line, p, 12), channel; StoreRow row = {0}; int64_t seconds, res;
        row.kind = (unsigned char)kind;
        if (!kind) {
            if ((n != 9 && n != 11) || !store_uint(p[0], &res) || !store_uint(p[1], &row.at) ||
                (res != 60 && res != 3600 && res != 86400) || !store_amount(p[7], &row.amount) || !store_uint(p[8], &seconds)) goto bad;
            if (row.at > now || now - row.at > retention[res == 60 ? 0 : (res == 3600 ? 1 : 2)]) continue;
            row.resolution = (uint32_t)res; row.legacy = n == 9;
            if (n == 11 && (!store_uint(p[9], &row.start) || !store_uint(p[10], &row.end))) goto bad;
            snprintf(meta, sizeof(meta), "%s\t%s\t%s\t%s\t%s", p[2], p[3], p[4], p[5], p[6]);
        } else {
            if ((n != 6 && n != 7) || (row.at = store_day(p[0])) < 0 || !store_amount(p[4], &row.amount) || !store_uint(p[5], &seconds)) goto bad;
            int64_t day = (now + 28800 - retention[2]) / 86400 * 86400 - 28800;
            if (row.at > now || row.at < day) continue;
            snprintf(meta, sizeof(meta), "%s\t%s\t%s\t%s", p[1], p[2], p[3], n == 7 ? p[6] : "-");
        }
        row.seconds = (uint64_t)seconds;
        channel = store_channel(&rows->dict[kind], meta);
        if (channel < 0) goto bad;
        row.channel = (uint32_t)channel;
        if (!store_append(rows, row)) goto bad;
    }
    tio_close(&reader); return code == 0;
bad:
    tio_close(&reader); return 0;
}
static int store_switches(StoreRows *rows, const char *state, int64_t now, int64_t retention) {
    char path[PATH_MAX], line[TIO_LINE];
    if (!store_path(path, state, "traffic-switches.tsv")) return 0;
    FILE *f = tio_file(path);
    if (!f) return errno == ENOENT;
    int ok = 1;
    while (fgets(line, sizeof(line), f)) {
        char *tab = strchr(line, '\t'); int64_t at;
        if (!tab || !strchr(line, '\n')) { ok = 0; break; }
        *tab = 0; int valid = store_uint(line, &at); *tab = '\t';
        if (!valid) { ok = 0; break; }
        if (at > now || now - at > retention) continue;
        int channel = store_channel(&rows->dict[2], line);
        StoreRow row = {.at = at, .channel = (uint32_t)channel, .kind = 2};
        if (channel < 0 || !store_append(rows, row)) { ok = 0; break; }
    }
    if (ferror(f)) ok = 0;
    fclose(f); return ok;
}
static int store_compare(const void *a, const void *b) {
    const StoreRow *x = a, *y = b;
    if (x->at != y->at) return x->at < y->at ? -1 : 1;
    if (x->kind != y->kind) return x->kind < y->kind ? -1 : 1;
    if (x->resolution != y->resolution) return x->resolution < y->resolution ? -1 : 1;
    return x->channel == y->channel ? 0 : (x->channel < y->channel ? -1 : 1);
}
static int store_merge(StoreRows *rows) {
    qsort(rows->rows, rows->count, sizeof(*rows->rows), store_compare);
    size_t written = 0;
    for (size_t i = 0; i < rows->count; i++) {
        StoreRow *r = &rows->rows[i];
        if (written && !store_compare(&rows->rows[written - 1], r) && r->kind != 2) {
            StoreRow *p = &rows->rows[written - 1];
            if (p->amount > INT64_MAX - r->amount || p->seconds > UINT64_MAX - r->seconds) return 0;
            p->amount += r->amount; p->seconds += r->seconds; p->legacy |= r->legacy;
            if (r->start && (!p->start || r->start < p->start)) p->start = r->start;
            if (r->end > p->end) p->end = r->end;
        } else rows->rows[written++] = *r;
    }
    rows->count = written; return 1;
}
static int store_write(const StoreRows *rows, size_t first, const char *directory, uint64_t *bytes) {
    char path[PATH_MAX], line[TIO_LINE], meta[TIO_LINE], *p[6]; gzFile packed[2] = {NULL, NULL}; FILE *switches = NULL, *index = NULL;
    int *ids[2] = {NULL, NULL}, counts[2] = {0, 0}, ok = 0;
    int64_t *times = calloc((rows->dict[0].count ? rows->dict[0].count : 1) * 6, sizeof(*times));
    if (!times) return 0;
    int64_t chunk_day = -1, chunk_start = 0, chunk_end = 0; uint64_t chunk_offset = 0;
    const char *names[] = {"usage-curves.tsv.dict.gz", "usage-samples.tsv.dict.gz", "usage-switches.tsv", "usage-curves.tsv.index"};
    for (int k = 0; k < 4; k++) {
        if (!store_path(path, directory, names[k])) goto done;
        unlink(path);
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0) goto done;
        if (k >= 2) {
            FILE *f = fdopen(fd, "w"); if (!f) { close(fd); goto done; }
            if (k == 2) switches = f; else index = f;
        }
        else {
            packed[k] = gzdopen(fd, "wb6"); if (!packed[k]) { close(fd); goto done; }
            ids[k] = malloc((rows->dict[k].count ? rows->dict[k].count : 1) * sizeof(int));
            if (!ids[k]) goto done;
            for (size_t j = 0; j < rows->dict[k].count; j++) ids[k][j] = -1;
            snprintf(line, sizeof(line), "BJUT-TRAFFIC\t%d\t%s\n", k ? 1 : 2, k ? "samples" : "curves");
            if (!gz_line(packed[k], line)) goto done;
        }
    }
    for (size_t i = first; i < rows->count; i++) {
        const StoreRow *r = &rows->rows[i]; int k = r->kind;
        if (k == 2) { if (fputs(rows->dict[2].items[r->channel], switches) == EOF) goto done; continue; }
        if (!k) {
            int64_t day = (r->at + 28800) / 86400;
            if (chunk_day >= 0 && day != chunk_day) {
                int closed = gzclose(packed[0]); packed[0] = NULL;
                if (closed != Z_OK || fprintf(index, "%" PRId64 "\t%" PRId64 "\t%" PRIu64 "\n", chunk_start, chunk_end, chunk_offset) < 0) goto done;
                store_path(path, directory, names[0]); struct stat st;
                if (lstat(path, &st)) goto done;
                chunk_offset = (uint64_t)st.st_size;
                packed[0] = gzopen(path, "ab6");
                if (!packed[0] || !gz_line(packed[0], "BJUT-TRAFFIC\t2\tcurves\n")) goto done;
                for (size_t j = 0; j < rows->dict[0].count; j++) ids[0][j] = -1;
                counts[0] = 0; memset(times, 0, rows->dict[0].count * 6 * sizeof(*times));
            }
            if (day != chunk_day) chunk_start = r->at;
            chunk_day = day; chunk_end = r->at;
        }
        int id = ids[k][r->channel];
        if (id < 0) {
            id = counts[k]++; ids[k][r->channel] = id;
            snprintf(line, sizeof(line), "D\t%d\t%s\n", id, rows->dict[k].items[r->channel]);
            if (!gz_line(packed[k], line)) goto done;
        }
        if (!k) {
            size_t slot = r->channel * 6 + (r->resolution == 60 ? 0 : (r->resolution == 3600 ? 1 : 2));
            int64_t step = r->at - times[slot]; times[slot] = r->at;
            int64_t change = r->amount - times[slot + 3]; times[slot + 3] = r->amount;
            snprintf(line, sizeof(line), "P\t%d\t%u\t%" PRId64 "\t%" PRId64 "\t%" PRIu64, id, r->resolution, step, change, r->seconds);
            size_t n = strlen(line);
            if (!r->legacy) snprintf(line + n, sizeof(line) - n, "\t%" PRId64 "\t%" PRId64 "\n", r->start ? r->start - r->at : -r->at, r->end ? r->end - r->at : -r->at);
            else snprintf(line + n, sizeof(line) - n, "\n");
        } else {
            /* The metadata stays dictionary-encoded; only the civil date is rebuilt. */
            time_t day = (time_t)(r->at + 28800); struct tm tm;
            if (!gmtime_r(&day, &tm)) goto done;
            snprintf(meta, sizeof(meta), "%s\n", rows->dict[k].items[r->channel]);
            if (tio_fields(meta, p, 6) != 4) goto done;
            snprintf(line, sizeof(line), "P\t%d\t%04d-%02d-%02d\t%" PRId64 ".%03" PRId64 "\t%" PRIu64 "\n", id, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, r->amount / 1000, r->amount % 1000, r->seconds);
        }
        if (!gz_line(packed[k], line)) goto done;
    }
    if (chunk_day >= 0 && fprintf(index, "%" PRId64 "\t%" PRId64 "\t%" PRIu64 "\n", chunk_start, chunk_end, chunk_offset) < 0) goto done;
    ok = 1;
done:
    for (int k = 0; k < 2; k++) {
        if (packed[k] && gzclose(packed[k]) != Z_OK) ok = 0;
        free(ids[k]);
    }
    if (switches && fclose(switches)) ok = 0;
    if (index && fclose(index)) ok = 0;
    free(times);
    *bytes = 0;
    for (int k = 0; k < 4; k++) {
        struct stat st;
        if (!store_path(path, directory, names[k]) || lstat(path, &st) || !S_ISREG(st.st_mode)) ok = 0;
        else *bytes += (uint64_t)st.st_size;
    }
    return ok;
}
static int store_compact(int argc, char **argv) {
    (void)argc;
    const char *state = argv[2], *output = argv[3]; int64_t now, retention[3], limit, reserved;
    if (!store_uint(argv[4], &now) || !store_uint(argv[5], &retention[0]) || !store_uint(argv[6], &retention[1]) ||
        !store_uint(argv[7], &retention[2]) || !store_uint(argv[8], &limit) || !store_uint(argv[9], &reserved) ||
        retention[0] > 8760 || retention[1] > 3660 || retention[2] > 36600 || limit < 1024 || reserved > limit) return 2;
    retention[0] *= 3600; retention[1] *= 86400; retention[2] *= 86400;
    setpriority(PRIO_PROCESS, 0, 10);
    StoreRows rows = {0}; uint64_t bytes = 0; size_t first = 0, attempts = 0; int ok = 0;
    int64_t longest = retention[0] > retention[1] ? retention[0] : retention[1];
    if (retention[2] > longest) longest = retention[2];
    if (!store_load(&rows, state, 0, now, retention) || !store_load(&rows, state, 1, now, retention) ||
        !store_switches(&rows, state, now, longest) || !store_merge(&rows)) goto done;
    while (store_write(&rows, first, output, &bytes)) {
        if (bytes + (uint64_t)reserved <= (uint64_t)limit) { ok = 1; break; }
        if (first == rows.count || ++attempts > 24) break;
        /* Trim oldest timestamps using the measured gzip size, then measure
         * again. Never discard the newest samples because of sort syntax. */
        double fraction = 1.0 - (double)(limit - reserved) / (double)bytes * .98;
        size_t remove = (size_t)((rows.count - first) * fraction);
        if (!remove) remove = 1;
        first += remove;
        if (first > rows.count) first = rows.count;
        while (first < rows.count && first && rows.rows[first].at == rows.rows[first - 1].at) first++;
    }
    if (ok) {
        char path[PATH_MAX];
        for (int k = 0; k < 2; k++) {
            store_path(path, output, k ? "usage-samples.tsv.dict.gz" : "usage-curves.tsv.dict.gz");
            if (!store_verify(k ? "samples" : "curves", path)) ok = 0;
        }
        if (ok) printf("{\"flashBytes\":%" PRIu64 ",\"limitBytes\":%" PRId64 ",\"retainedRows\":%zu,\"trimmedRows\":%zu,\"checkpointAt\":%" PRId64 "}\n", bytes + (uint64_t)reserved, limit, rows.count - first, first, now);
    }
done:
    free(rows.rows);
    for (int i = 0; i < 3; i++) tio_dict_free(&rows.dict[i]);
    return ok ? 0 : 1;
}
static int store_commit(const char *state, const char *source) {
    char directory[PATH_MAX], old[PATH_MAX] = "", from[PATH_MAX], to[PATH_MAX];
    tio_directory(state, old, sizeof(old));
    if (snprintf(directory, sizeof(directory), "%s/traffic-store.XXXXXX", state) >= (int)sizeof(directory) || !mkdtemp(directory)) return 1;
    int ok = 1;
    const char *names[] = {"usage-curves.tsv.dict.gz", "usage-samples.tsv.dict.gz", "usage-curves.tsv.index", "usage-curves.tsv", "usage-samples.tsv"};
    for (int i = 0; i < 5 && ok; i++) {
        ok = store_path(to, directory, names[i]);
        if (i < 3) ok = ok && store_path(from, source, names[i]) && store_copy(from, to);
        else ok = ok && store_empty(to);
    }
    if (ok) ok = store_publish(state, directory, 0);
    if (!ok) store_remove_directory(directory);
    else {
        /* Retire older generations only after publication. Readers with open
         * descriptors keep a consistent snapshot across the atomic switch. */
        DIR *d = opendir(state); struct dirent *entry;
        if (d) {
            while ((entry = readdir(d))) {
                if (strncmp(entry->d_name, "traffic-store.", 14) || !store_path(to, state, entry->d_name) ||
                    !strcmp(to, directory) || !strcmp(to, old)) continue;
                store_remove_directory(to);
            }
            closedir(d);
        }
    }
    return ok ? 0 : 1;
}

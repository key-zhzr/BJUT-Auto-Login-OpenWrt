/* Lossless v1 dictionary-gzip reader shared by the collector and RPC views.
 * RAM keeps an immutable checkpoint plus a small append journal. Publishing a
 * new generation switches both files together; readers pin their open files. */
#ifndef BJUT_TRAFFIC_IO_H
#define BJUT_TRAFFIC_IO_H
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define TIO_LINE 4096
#define TIO_CHANNELS 65536
/* Corrupt-input/resource guard, independent of the persistent storage quota. */
#define TIO_MAX_READ (UINT64_C(1024) * 1048576)
typedef struct { char **items; size_t count, capacity; } TioDictionary;
typedef struct {
    gzFile packed;
    FILE *journal;
    TioDictionary dict;
    int64_t *times;
    uint64_t read_bytes;
    int curves, header, failed, delta;
    int packed_fd;
    int64_t stop_at;
    char directory[PATH_MAX];
} TioReader;

static inline void tio_dict_free(TioDictionary *d) {
    for (size_t i = 0; i < d->count; i++) free(d->items[i]);
    free(d->items);
    memset(d, 0, sizeof(*d));
}
static inline int tio_dict_add(TioDictionary *d, const char *text) {
    if (d->count >= TIO_CHANNELS) return -1;
    if (d->count == d->capacity) {
        size_t capacity = d->capacity ? d->capacity * 2 : 16;
        char **items = realloc(d->items, capacity * sizeof(*items));
        if (!items) return -1;
        d->items = items; d->capacity = capacity;
    }
    char *item = strdup(text);
    if (!item) return -1;
    d->items[d->count] = item;
    return (int)d->count++;
}
static inline int tio_fields(char *line, char **parts, int maximum) {
    size_t length = strlen(line);
    if (!length || line[length - 1] != '\n') return -1;
    line[length - 1] = 0;
    int n = 1; parts[0] = line;
    for (char *p = line; *p; p++) if (*p == '\t') {
        if (n >= maximum) return -1;
        *p = 0; parts[n++] = p + 1;
    }
    return n;
}
static inline int tio_id(const char *s, size_t *id) {
    size_t n = 0;
    if (!*s) return 0;
    for (; *s; s++) {
        if (*s < '0' || *s > '9' || n > TIO_CHANNELS) return 0;
        n = n * 10 + (size_t)(*s - '0');
    }
    *id = n; return 1;
}
static inline FILE *tio_file(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NULL;
    FILE *f = fdopen(fd, "r");
    if (!f) close(fd);
    return f;
}
static inline int tio_directory(const char *state, char *directory, size_t size) {
    char path[PATH_MAX], generation[100] = "";
    if (snprintf(path, sizeof(path), "%s/traffic-store-current", state) >= (int)sizeof(path)) return 0;
    FILE *f = tio_file(path);
    if (!f) return 0;
    int ok = fgets(generation, sizeof(generation), f) != NULL;
    fclose(f);
    size_t n = strcspn(generation, "\n"); generation[n] = 0;
    if (!ok || strncmp(generation, "traffic-store.", 14) || n < 20) return 0;
    for (size_t i = 14; i < n; i++)
        if (!((generation[i] >= 'a' && generation[i] <= 'z') ||
              (generation[i] >= 'A' && generation[i] <= 'Z') ||
              (generation[i] >= '0' && generation[i] <= '9'))) return 0;
    return snprintf(directory, size, "%s/%s", state, generation) < (int)size;
}
static inline int tio_open(TioReader *r, const char *kind, const char *packed, const char *journal) {
    memset(r, 0, sizeof(*r)); r->curves = !strcmp(kind, "curves");
    int fd = open(packed, O_RDONLY | O_NOFOLLOW);
    if (fd >= 0) {
        r->packed = gzdopen(fd, "rb");
        if (!r->packed) { close(fd); return 0; }
        r->packed_fd = fd;
    } else if (errno != ENOENT) return 0;
    r->journal = tio_file(journal);
    if (!r->journal && errno != ENOENT) {
        if (r->packed) gzclose(r->packed);
        memset(r, 0, sizeof(*r)); return 0;
    }
    return r->packed || r->journal;
}
static inline void tio_close(TioReader *r) {
    if (r->packed) gzclose(r->packed);
    if (r->journal) fclose(r->journal);
    tio_dict_free(&r->dict);
    free(r->times); r->times = NULL;
    r->packed = NULL; r->journal = NULL;
}
static inline int tio_open_state(TioReader *r, const char *state, const char *kind) {
    char directory[PATH_MAX], packed[PATH_MAX], journal[PATH_MAX];
    for (int retry = 0; retry < 3; retry++) {
        int current = tio_directory(state, directory, sizeof(directory));
        if (!current && snprintf(directory, sizeof(directory), "%s", state) >= (int)sizeof(directory)) return 0;
        if (snprintf(journal, sizeof(journal), "%s/usage-%s.tsv", directory, kind) >= (int)sizeof(journal) ||
            snprintf(packed, sizeof(packed), "%s.dict.gz", journal) >= (int)sizeof(packed)) return 0;
        if (tio_open(r, kind, packed, journal)) {
            if (!current || (r->packed && r->journal)) {
                snprintf(r->directory, sizeof(r->directory), "%s", directory);
                return 1;
            }
            tio_close(r);
        }
        if (!current) break;
        /* A generation may have been retired between reading the manifest
         * and opening its files. Already-open generations remain readable. */
    }
    return 0;
}
/* The small index addresses independently decodable daily gzip members.
 * Missing indexes (v1 checkpoints) fall back to a full streaming read. */
static inline int tio_seek(TioReader *r, int64_t first, int64_t last) {
    if (!r->packed || !r->curves || !*r->directory || first <= 0) return 1;
    char path[PATH_MAX], line[160];
    if (snprintf(path, sizeof(path), "%s/usage-curves.tsv.index", r->directory) >= (int)sizeof(path)) return 0;
    FILE *f = tio_file(path);
    if (!f) return errno == ENOENT;
    unsigned long long start, end, offset, chosen = 0; int found = 0;
    while (fgets(line, sizeof(line), f)) {
        char suffix;
        if (sscanf(line, "%llu\t%llu\t%llu%c", &start, &end, &offset, &suffix) != 4 || suffix != '\n' || start > end || offset > INT64_MAX) { fclose(f); return 0; }
        if ((int64_t)end >= first) { chosen = offset; found = 1; break; }
    }
    fclose(f);
    if (!found) return 1;
    int fd = dup(r->packed_fd);
    if (fd < 0) return 0;
    if (gzclose(r->packed) != Z_OK) { close(fd); r->packed = NULL; return 0; }
    r->packed = NULL;
    if (lseek(fd, (off_t)chosen, SEEK_SET) < 0 || !(r->packed = gzdopen(fd, "rb"))) { close(fd); return 0; }
    r->packed_fd = fd; r->stop_at = last;
    return 1;
}
/* One reconstructed TSV row, EOF, or a validation/read failure. */
static inline int tio_next(TioReader *r, char *out, size_t size) {
    char line[TIO_LINE], original[TIO_LINE], meta[TIO_LINE], *p[12];
    if (r->failed) return -1;
    while (r->packed) {
        if (!gzgets(r->packed, line, sizeof(line))) {
            int error = Z_OK; gzerror(r->packed, &error);
            int ok = r->header && gzeof(r->packed) && (error == Z_OK || error == Z_STREAM_END);
            if (gzclose(r->packed) != Z_OK) ok = 0;
            r->packed = NULL;
            if (!ok) goto bad;
            break;
        }
        if (!r->header || !strncmp(line, "BJUT-TRAFFIC\t", 13)) {
            char header[64];
            tio_dict_free(&r->dict); free(r->times); r->times = NULL; r->delta = 0;
            snprintf(header, sizeof(header), "BJUT-TRAFFIC\t1\t%s\n", r->curves ? "curves" : "samples");
            if (strcmp(line, header)) {
                if (!r->curves || strcmp(line, "BJUT-TRAFFIC\t2\tcurves\n")) goto bad;
                r->delta = 1;
            }
            r->header = 1; continue;
        }
        memcpy(original, line, strlen(line) + 1);
        int n = tio_fields(line, p, 12), count; size_t id;
        if (n < 3 || !tio_id(p[1], &id)) goto bad;
        if (!strcmp(p[0], "D")) {
            if (n != (r->curves ? 7 : 6) || id != r->dict.count) goto bad;
            char *start = strchr(original, '\t'); start = strchr(start + 1, '\t') + 1;
            start[strlen(start) - 1] = 0;
            if (tio_dict_add(&r->dict, start) < 0) goto bad;
            if (r->delta) {
                int64_t *times = realloc(r->times, r->dict.count * 6 * sizeof(*times));
                if (!times) goto bad;
                r->times = times;
                memset(r->times + id * 6, 0, 6 * sizeof(*times));
            }
            continue;
        }
        if (strcmp(p[0], "P") || id >= r->dict.count) goto bad;
        if (r->curves) {
            if (n != 6 && n != 8) goto bad;
            if (!r->delta) {
                count = snprintf(out, size, "%s\t%s\t%s\t%s\t%s%s%s%s%s\n", p[2], p[3], r->dict.items[id], p[4], p[5],
                                 n == 8 ? "\t" : "", n == 8 ? p[6] : "", n == 8 ? "\t" : "", n == 8 ? p[7] : "");
            } else {
                int slot = !strcmp(p[2], "60") ? 0 : (!strcmp(p[2], "3600") ? 1 : (!strcmp(p[2], "86400") ? 2 : -1));
                char *end; errno = 0; int64_t step = strtoll(p[3], &end, 10);
                if (slot < 0 || !*p[3] || *end || errno || step < 0 || r->times[id * 6 + slot] > INT64_MAX - step) goto bad;
                int64_t at = (r->times[id * 6 + slot] += step), start = 0, finish = 0;
                errno = 0; int64_t change = strtoll(p[4], &end, 10), previous = r->times[id * 6 + slot + 3];
                if (!*p[4] || *end || errno || change < -previous || change > INT64_MAX - previous) goto bad;
                int64_t amount = (r->times[id * 6 + slot + 3] += change);
                if (n == 8) {
                    errno = 0; int64_t offset = strtoll(p[6], &end, 10);
                    if (!*p[6] || *end || errno || offset < -at || offset > INT64_MAX - at) goto bad;
                    start = at + offset;
                    errno = 0; offset = strtoll(p[7], &end, 10);
                    if (!*p[7] || *end || errno || offset < -at || offset > INT64_MAX - at) goto bad;
                    finish = at + offset;
                }
                count = snprintf(out, size, "%s\t%lld\t%s\t%lld.%03lld\t%s", p[2], (long long)at, r->dict.items[id], (long long)(amount / 1000), (long long)(amount % 1000), p[5]);
                if (count < 0 || (size_t)count >= size) goto bad;
                int extra = n == 8 ? snprintf(out + count, size - (size_t)count, "\t%lld\t%lld\n", (long long)start, (long long)finish) : snprintf(out + count, size - (size_t)count, "\n");
                if (extra < 0) goto bad;
                count += extra;
            }
        } else {
            if (n != 5) goto bad;
            snprintf(meta, sizeof(meta), "%s\n", r->dict.items[id]); char *m[5];
            if (tio_fields(meta, m, 5) != 4) goto bad;
            count = snprintf(out, size, "%s\t%s\t%s\t%s\t%s\t%s%s%s\n", p[2], m[0], m[1], m[2], p[3], p[4],
                             !strcmp(m[3], "-") ? "" : "\t", !strcmp(m[3], "-") ? "" : m[3]);
        }
        if (count < 0 || (size_t)count >= size) goto bad;
        if (r->stop_at > 0 && r->curves) {
            char *tab = strchr(out, '\t');
            if (tab && strtoll(tab + 1, NULL, 10) > r->stop_at) {
                gzclose(r->packed); r->packed = NULL; break;
            }
        }
        r->read_bytes += (size_t)count;
        if (r->read_bytes > TIO_MAX_READ) goto bad;
        return 1;
    }
    if (r->journal && fgets(out, (int)size, r->journal)) {
        size_t n = strlen(out);
        if (!n || out[n - 1] != '\n') goto bad;
        r->read_bytes += n;
        if (r->read_bytes > TIO_MAX_READ) goto bad;
        return 1;
    }
    if (r->journal && ferror(r->journal)) goto bad;
    return 0;
bad:
    r->failed = 1; return -1;
}
#endif

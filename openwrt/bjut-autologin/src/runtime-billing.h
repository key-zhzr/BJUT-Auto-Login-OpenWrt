/* SPDX-License-Identifier: MIT
 * Project billing rows onto their display columns in a single process. */
#ifndef BJUT_RUNTIME_BILLING_H
#define BJUT_RUNTIME_BILLING_H
#include <strings.h>
#include "runtime-calendar.h"

static J *billing_rows(J *value) {
    if (json_object_is_type(value, json_type_array))
        return value;
    J *rows = get(value, "rows");
    if (!json_object_is_type(rows, json_type_array))
        rows = get(value, "data");
    return json_object_is_type(rows, json_type_array) ? rows : NULL;
}

static const char *billing_cell(J *row, const char *key, size_t index) {
    J *value = NULL;
    if (json_object_is_type(row, json_type_array)) {
        value = json_object_array_get_idx(row, index);
    } else if (json_object_is_type(row, json_type_object)) {
        int found = json_object_object_get_ex(row, key, &value);
        if (!found) {
            json_object_object_foreach(row, name, entry) {
                if (!strcasecmp(name, key)) {
                    value = entry;
                    found = 1;
                    break;
                }
            }
        }
        if (found && !value)
            return "--";
    }
    if (!value || json_object_is_type(value, json_type_object) || json_object_is_type(value, json_type_array))
        return "";
    return json_object_get_string(value);
}

static const char *billing_display_cell(J *row, const char *key, size_t index, char converted[32]) {
    const char *value = billing_cell(row, key, index);
    if (!strcmp(key, "mac") || !strcmp(key, "macAddress")) {
        if (strlen(value) < 32) {
            display_mac(value, converted, 32);
            return converted;
        }
    } else if (!strcmp(key, "billingMode")) {
        if (!strcmp(value, "1")) return "时长";
        if (!strcmp(value, "2")) return "流量";
        if (!strcmp(value, "3")) return "包月";
    } else if (strlen(value) == 13) {
        static const char *const dates[] = {
            "loginTime", "logoutTime", "lastLoginAt", "startAt", "endAt", "billedAt", "paidAt",
            "operatedAt", "fldoperatedate", "fldchangedate", "fldexcutedate", "fldstatedate"
        };
        for (size_t i = 0; i < sizeof(dates) / sizeof(*dates); i++)
            if (!strcmp(key, dates[i]) && bjut_timestamp_date(value, 13, converted))
                return converted;
    }
    return value;
}

static int billing_project(const char *module, const char *file) {
    static const char *const history[] = {
        "loginTime", "logoutTime", "ip", "ipv6", "mac", "durationMinutes", "flowMb", "billingMode", "amount"
    };
    static const char *const devices[] = {"online", "mac", "device", "lastLoginAt", "lastIp"};
    static const char *const sessions[] = {"loginTime", "ip", "ipv6", "mac", "useTime", "downFlow", "upFlow"};
    int session_view = !strcmp(module, "sessions");
    const char *const *columns;
    size_t count;
    if (session_view) {
        columns = sessions;
        count = sizeof(sessions) / sizeof(*sessions);
    } else if (!strcmp(module, "devices")) {
        columns = devices;
        count = sizeof(devices) / sizeof(*devices);
    } else if (!strcmp(module, "history")) {
        columns = history;
        count = sizeof(history) / sizeof(*history);
    } else {
        return 2;
    }
    J *source = NULL;
    if (!billing_read_json(file, &source))
        return 1;
    J *rows = billing_rows(source);
    if (source && !rows) { json_object_put(source); return 1; }
    size_t total = rows ? json_object_array_length(rows) : 0;
    if (total > (session_view ? 500U : 5000U)) { json_object_put(source); return 1; }
    J *result = json_object_new_array();
    for (size_t i = 0; i < total; i++) {
        J *row = json_object_array_get_idx(rows, i);
        J *display = session_view ? json_object_new_object() : json_object_new_array();
        if (session_view)
            number(display, "sessionIndex", (int64_t)i);
        for (size_t j = 0; j < count; j++) {
            char formatted[32];
            const char *value = session_view && j == 0 ? billing_cell(row, columns[j], j) :
                                billing_display_cell(row, columns[j], j, formatted);
            if (strlen(value) > 256)
                value = "";
            if (session_view)
                text(display, columns[j], value);
            else
                json_object_array_add(display, json_object_new_string(value));
        }
        json_object_array_add(result, display);
    }
    J *out = result;
    if (!session_view) {
        out = json_object_new_object();
        J *labels = json_object_new_array();
        for (size_t i = 0; i < count; i++)
            json_object_array_add(labels, json_object_new_string(columns[i]));
        json_object_object_add(out, "columns", labels);
        json_object_object_add(out, "rows", result);
    }
    int ok = puts(json_object_to_json_string_ext(out, JSON_C_TO_STRING_PLAIN)) >= 0;
    json_object_put(out);
    json_object_put(source);
    return ok ? 0 : 1;
}

static int billing_record_rows(int argc, char **argv) {
    if (argc < 5 || !digits(argv[2]) || !digits(argv[3]))
        return 2;
    int usage = !strcmp(argv[1], "usage");
    int64_t first = strtoll(argv[2], NULL, 10), last = strtoll(argv[3], NULL, 10);
    if (first < 0 || last < first || last >= 100)
        return 2;
    J *source = NULL;
    if (!billing_read_json(argv[0], &source))
        return 1;
    J *rows = billing_rows(source);
    if (!rows) { json_object_put(source); return 1; }
    size_t count = json_object_array_length(rows);
    int status = 0;
    for (size_t i = (size_t)first; i <= (size_t)last && i < count; i++) {
        J *row = json_object_array_get_idx(rows, i);
        if (!json_object_is_type(row, json_type_array) && !json_object_is_type(row, json_type_object)) {
            status = 1;
            break;
        }
        J *display = json_object_new_array();
        const char *nas_ip = "", *nas_port = "";
        char mac[32] = "";
        for (int j = 4; j < argc; j++) {
            const char *key = argv[j];
            char formatted[32];
            const char *value = billing_display_cell(row, key, (size_t)(j - 4), formatted);
            if (usage) {
                if (!strcmp(key, "macAddress")) bounded_copy(mac, sizeof(mac), value);
                if (!strcmp(key, "nasIp")) { nas_ip = billing_cell(row, key, (size_t)(j - 4)); continue; }
                if (!strcmp(key, "nasPort")) { nas_port = billing_cell(row, key, (size_t)(j - 4)); continue; }
                if (!strcmp(key, "internetUpFlow") || !strcmp(key, "internetDownFlow") ||
                    !strcmp(key, "chinanetUpFlow") || !strcmp(key, "chinanetDownFlow")) continue;
            }
            json_object_array_add(display, json_object_new_string(strlen(value) > 512 ? "内容较长" : value));
        }
        if (usage) {
            const char *access = "未知";
            if (!strcmp(mac, "00-00-00-00-00-00") && !strcmp(nas_ip, "0.0.0.0") && !strcmp(nas_port, "0"))
                access = "lgn（有线）";
            else if (!strcmp(nas_ip, "10.21.251.3")) access = "bjut_wifi";
            else if (!strcmp(nas_ip, "10.21.221.97")) access = "bjut-sushe";
            json_object_array_add(display, json_object_new_string(access));
        }
        printf("{\"row\":%s}\n", json_object_to_json_string_ext(display, JSON_C_TO_STRING_PLAIN));
        json_object_put(display);
    }
    json_object_put(source);
    return status;
}

#endif

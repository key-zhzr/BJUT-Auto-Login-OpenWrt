/* SPDX-License-Identifier: MIT */
#ifndef BJUT_RUNTIME_CALENDAR_H
#define BJUT_RUNTIME_CALENDAR_H

static inline int bjut_leap_year(int year) {
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

static inline int bjut_month_days(int year, int month) {
    static const int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    return days[month - 1] + (month == 2 && bjut_leap_year(year));
}

/* jfself uses epoch milliseconds and Beijing time, including on 32-bit targets. */
static inline int bjut_timestamp_date(const char *value, size_t length, char output[20]) {
    uint64_t stamp = 0;
    if (length != 10 && length != 13)
        return 0;
    for (size_t i = 0; i < length; i++) {
        if (value[i] < '0' || value[i] > '9')
            return 0;
        stamp = stamp * 10 + (unsigned)(value[i] - '0');
    }
    if (!stamp)
        return 0;
    uint64_t seconds = (length == 13 ? stamp / 1000 : stamp) + 28800;
    if (seconds / 86400 > 84005)
        return 0;
    int day = (int)(seconds / 86400), clock = (int)(seconds % 86400);
    int year = 1970, month = 1;
    while (day >= 365 + bjut_leap_year(year)) {
        day -= 365 + bjut_leap_year(year);
        year++;
    }
    while (day >= bjut_month_days(year, month)) {
        day -= bjut_month_days(year, month);
        month++;
    }
    return snprintf(output, 20, "%04d-%02d-%02d %02d:%02d:%02d", year, month, day + 1,
                    clock / 3600, clock / 60 % 60, clock % 60) == 19;
}

#endif

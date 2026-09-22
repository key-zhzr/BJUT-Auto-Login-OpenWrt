// SPDX-License-Identifier: MIT
// Tiny stdin-only codecs used by the OpenWrt shell service. Keeping secrets
// off argv prevents them from being exposed by `ps` while curl is running.

#include <errno.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_INPUT 16384U
#define EPORTAL_XOR_KEY 0x16U

static int read_stdin(unsigned char **data, size_t *length)
{
    size_t capacity = 256;
    size_t used = 0;
    unsigned char *buffer = malloc(capacity);

    if (buffer == NULL) {
        return -1;
    }

    for (;;) {
        size_t available;
        size_t count;

        if (used == capacity) {
            unsigned char *next;

            if (capacity >= MAX_INPUT) {
                free(buffer);
                errno = EFBIG;
                return -1;
            }
            capacity *= 2;
            if (capacity > MAX_INPUT) {
                capacity = MAX_INPUT;
            }
            next = realloc(buffer, capacity);
            if (next == NULL) {
                free(buffer);
                return -1;
            }
            buffer = next;
        }

        available = capacity - used;
        count = fread(buffer + used, 1, available, stdin);
        used += count;
        if (count < available) {
            if (ferror(stdin)) {
                free(buffer);
                return -1;
            }
            break;
        }
    }

    *data = buffer;
    *length = used;
    return 0;
}

static int is_unreserved(unsigned char value)
{
    return (value >= 'A' && value <= 'Z') ||
           (value >= 'a' && value <= 'z') ||
           (value >= '0' && value <= '9') || value == '-' || value == '.' ||
           value == '_' || value == '~';
}

static int write_urlencoded(const unsigned char *data, size_t length)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t index;

    for (index = 0; index < length; index++) {
        unsigned char value = data[index];

        if (is_unreserved(value)) {
            if (putchar((int)value) == EOF) {
                return -1;
            }
        } else if (printf("%%%c%c", hex[value >> 4], hex[value & 0x0f]) < 0) {
            return -1;
        }
    }
    return 0;
}

static int decode_utf8(const unsigned char *data, size_t length, size_t *offset,
                       uint32_t *codepoint)
{
    unsigned char first;
    uint32_t value;
    size_t needed;
    size_t index;

    if (*offset >= length) {
        return 0;
    }
    first = data[(*offset)++];
    if (first < 0x80) {
        *codepoint = first;
        return 1;
    }
    if (first >= 0xc2 && first <= 0xdf) {
        value = first & 0x1fU;
        needed = 1;
    } else if (first >= 0xe0 && first <= 0xef) {
        value = first & 0x0fU;
        needed = 2;
    } else if (first >= 0xf0 && first <= 0xf4) {
        value = first & 0x07U;
        needed = 3;
    } else {
        return -1;
    }
    if (length - *offset < needed) {
        return -1;
    }
    for (index = 0; index < needed; index++) {
        unsigned char next = data[(*offset)++];

        if ((next & 0xc0U) != 0x80U) {
            return -1;
        }
        value = (value << 6) | (next & 0x3fU);
    }
    if ((needed == 2 && value < 0x800) ||
        (needed == 3 && value < 0x10000) || value > 0x10ffff ||
        (value >= 0xd800 && value <= 0xdfff)) {
        return -1;
    }
    *codepoint = value;
    return 1;
}

static int write_encrypted_unit(uint16_t unit)
{
    return printf("%02x", (unsigned int)(unit ^ EPORTAL_XOR_KEY)) < 0 ? -1 : 0;
}

static int write_eportal(const unsigned char *data, size_t length)
{
    size_t offset = 0;

    while (offset < length) {
        uint32_t codepoint;
        int decoded = decode_utf8(data, length, &offset, &codepoint);

        if (decoded <= 0) {
            errno = EILSEQ;
            return -1;
        }
        if (codepoint <= 0xffff) {
            if (write_encrypted_unit((uint16_t)codepoint) != 0) {
                return -1;
            }
        } else {
            uint32_t adjusted = codepoint - 0x10000;
            uint16_t high = (uint16_t)(0xd800U + (adjusted >> 10));
            uint16_t low = (uint16_t)(0xdc00U + (adjusted & 0x3ffU));

            if (write_encrypted_unit(high) != 0 || write_encrypted_unit(low) != 0) {
                return -1;
            }
        }
    }
    return 0;
}

static int write_base64(const unsigned char *data, size_t length)
{
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t index;

    for (index = 0; index < length; index += 3) {
        uint32_t block = (uint32_t)data[index] << 16;
        size_t remaining = length - index;

        if (remaining > 1) {
            block |= (uint32_t)data[index + 1] << 8;
        }
        if (remaining > 2) {
            block |= data[index + 2];
        }
        if (putchar(alphabet[(block >> 18) & 0x3f]) == EOF ||
            putchar(alphabet[(block >> 12) & 0x3f]) == EOF ||
            putchar(remaining > 1 ? alphabet[(block >> 6) & 0x3f] : '=') == EOF ||
            putchar(remaining > 2 ? alphabet[block & 0x3f] : '=') == EOF) {
            return -1;
        }
    }
    return 0;
}

static int validate_ipv6(const unsigned char *data, size_t length)
{
    char text[INET6_ADDRSTRLEN];
    struct in6_addr address;

    if (length == 0 || length >= sizeof(text)) {
        errno = EINVAL;
        return -1;
    }
    memcpy(text, data, length);
    text[length] = '\0';
    if (inet_pton(AF_INET6, text, &address) == 1) {
        return 0;
    }
    errno = EINVAL;
    return -1;
}

static void usage(const char *program)
{
    fprintf(stderr, "Usage: %s {urlencode|eportal|base64|validate-ipv6} < input\n", program);
}

int main(int argc, char **argv)
{
    unsigned char *data = NULL;
    size_t length = 0;
    int result;

    if (argc != 2) {
        usage(argv[0]);
        return 2;
    }
    if (read_stdin(&data, &length) != 0) {
        perror("bjut-codec: input");
        return 1;
    }
    if (memchr(data, '\0', length) != NULL) {
        fprintf(stderr, "bjut-codec: NUL bytes are not accepted\n");
        free(data);
        return 1;
    }

    if (strcmp(argv[1], "urlencode") == 0) {
        result = write_urlencoded(data, length);
    } else if (strcmp(argv[1], "eportal") == 0) {
        result = write_eportal(data, length);
    } else if (strcmp(argv[1], "base64") == 0) {
        result = write_base64(data, length);
    } else if (strcmp(argv[1], "validate-ipv6") == 0) {
        result = validate_ipv6(data, length);
    } else {
        usage(argv[0]);
        free(data);
        return 2;
    }

    if (result != 0 || fflush(stdout) == EOF) {
        perror("bjut-codec: output");
        free(data);
        return 1;
    }
    free(data);
    return 0;
}

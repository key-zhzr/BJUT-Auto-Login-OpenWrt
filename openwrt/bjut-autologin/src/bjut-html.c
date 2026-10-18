// SPDX-License-Identifier: MIT
// Bounded extraction only: never evaluate scripts from a billing response.
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define LIMIT (1024U * 1024U)

static const char *find_ci(const char *s, const char *needle)
{
    size_t n = strlen(needle);
    for (; *s; s++) if (!strncasecmp(s, needle, n)) return s;
    return NULL;
}

static const char *tag_end(const char *s)
{
    char quote = 0;
    for (; *s; s++) {
        if (quote) { if (*s == quote) quote = 0; }
        else if (*s == '\'' || *s == '"') quote = *s;
        else if (*s == '>') return s;
    }
    return NULL;
}

static int emit_text(const char *a, const char *b, int strip)
{
    int inside = 0, space = 0;
    for (; a < b; a++) {
        if (strip && *a == '<') { inside = 1; continue; }
        if (strip && *a == '>') { inside = 0; space = 1; continue; }
        if (inside) continue;
        if (strip && isspace((unsigned char)*a)) { space = 1; continue; }
        if (space) { putchar(' '); space = 0; }
        if (*a == '&') {
            const char *semi = memchr(a, ';', (size_t)(b - a));
            if (semi && semi - a < 10) {
                size_t n = (size_t)(semi - a + 1);
                char value = 0;
                if (n == 5 && !strncmp(a, "&amp;", n)) value = '&';
                else if (n == 6 && !strncmp(a, "&quot;", n)) value = '"';
                else if (n == 6 && !strncmp(a, "&apos;", n)) value = '\'';
                else if (n == 4 && !strncmp(a, "&lt;", n)) value = '<';
                else if (n == 4 && !strncmp(a, "&gt;", n)) value = '>';
                else if (n == 6 && !strncmp(a, "&nbsp;", n)) value = ' ';
                if (value) { putchar(value); a = semi; continue; }
            }
        }
        putchar((unsigned char)*a);
    }
    return ferror(stdout) ? 1 : 0;
}

static int attr(const char *tag, const char *wanted, const char **a, const char **b)
{
    const char *end = tag_end(tag), *p = tag;
    if (!end) return 0;
    while (p < end && !isspace((unsigned char)*p)) p++;
    while (p < end) {
        const char *name, *name_end, *value, *value_end;
        char quote = 0;
        while (p < end && (isspace((unsigned char)*p) || *p == '/')) p++;
        name = p;
        while (p < end && !isspace((unsigned char)*p) && *p != '=' && *p != '>') p++;
        name_end = p;
        while (p < end && isspace((unsigned char)*p)) p++;
        if (p >= end || *p != '=') continue;
        p++;
        while (p < end && isspace((unsigned char)*p)) p++;
        if (p < end && (*p == '\'' || *p == '"')) quote = *p++;
        value = p;
        while (p < end && (quote ? *p != quote : !isspace((unsigned char)*p))) p++;
        value_end = p;
        if (quote && p < end) p++;
        if ((size_t)(name_end - name) == strlen(wanted) && !strncasecmp(name, wanted, strlen(wanted))) {
            *a = value; *b = value_end; return 1;
        }
    }
    return 0;
}

static int attr_is(const char *tag, const char *key, const char *value)
{
    const char *a, *b;
    return attr(tag, key, &a, &b) && (size_t)(b - a) == strlen(value) && !strncasecmp(a, value, strlen(value));
}

static const char *next_tag(const char *p, const char *tag)
{
    char prefix[32];
    snprintf(prefix, sizeof(prefix), "<%s", tag);
    while ((p = find_ci(p, prefix))) {
        char next = p[strlen(prefix)];
        if (next == '>' || next == '/' || isspace((unsigned char)next)) return p;
        p++;
    }
    return NULL;
}

static int user_json(const char *html)
{
    const char *p = strstr(html, "window.user"), *a;
    if (!p) return 1;
    while ((p = strstr(p, "})"))) {
        int depth = 0, quoted = 0, escaped = 0;
        p += 2;
        while (isspace((unsigned char)*p)) p++;
        if (*p != '(') continue;
        p++;
        while (isspace((unsigned char)*p)) p++;
        if (*p != '{') continue;
        a = p;
        for (; *p; p++) {
            if (quoted) {
                if (escaped) escaped = 0;
                else if (*p == '\\') escaped = 1;
                else if (*p == '"') quoted = 0;
            } else if (*p == '"') quoted = 1;
            else if (*p == '{') depth++;
            else if (*p == '}' && --depth == 0) return emit_text(a, p + 1, 0);
        }
        return 1;
    }
    return 1;
}

static int safe_id(const char *a, const char *b)
{
    if (b <= a || b-a > 64) return 0;
    for (; a < b; a++) if (!isalnum((unsigned char)*a) && *a != '-' && *a != '_') return 0;
    return 1;
}

static int literal(const char *html, const char *name)
{
    const char *p=html, *a;
    while ((p=find_ci(p,name))) {
        if (p>html && (isalnum((unsigned char)p[-1]) || p[-1]=='_')) { p++; continue; }
        p+=strlen(name);
        if (isalnum((unsigned char)*p) || *p=='_') continue;
        if (*p=='\'' || *p=='"') p++;
        while (isspace((unsigned char)*p)) p++;
        if (*p!=':' && *p!='=') continue;
        p++; while (isspace((unsigned char)*p)) p++;
        char quote=*p;
        if (quote!='\'' && quote!='"') continue;
        a=++p;
        while (*p && (isalnum((unsigned char)*p) || *p=='-' || *p=='_' || *p=='.')) p++;
        if (*p==quote && p>a && p-a<=256) return emit_text(a,p,0);
    }
    return 1;
}

static int choices(const char *html, int packages)
{
    const char *p=html, *a, *b, *body, *end, *limit=NULL;
    int count=0;
    if (!packages) {
        while ((p=next_tag(p,"select")) && !attr_is(p,"id","question1")) p++;
        if (!p || !(limit=find_ci(p,"</select>"))) return 1;
    }
    while ((p=next_tag(p,packages?"a":"option")) && (!limit || p<limit)) {
        if (attr(p,packages?"data-package":"value",&a,&b) && safe_id(a,b) && !(b-a==1 && *a=='0')) {
            body=tag_end(p); end=find_ci(p,packages?"</a>":"</option>");
            if (body && end && end>body && end-body<=1024) {
                emit_text(a,b,0); putchar('\t'); emit_text(body+1,end,1); putchar('\n');
                if (++count>=100) break;
            }
        }
        p++;
    }
    return 0;
}

static int extract(const char *html, const char *op, const char *name)
{
    const char *p = html, *a, *b, *end;
    if (!strcmp(op,"object") && *name) {
        p=strstr(html,name); if(!p || !(p=strchr(p,'{')))return 1;
        a=p;int depth=0,quoted=0,escaped=0;
        for(;*p;p++){
            if(quoted){if(escaped)escaped=0;else if(*p=='\\')escaped=1;else if(*p=='"')quoted=0;}
            else if(*p=='"')quoted=1;else if(*p=='{')depth++;else if(*p=='}' && --depth==0)return emit_text(a,p+1,0);
        }
        return 1;
    }
    if (!strcmp(op,"literal") && *name) return literal(html,name);
    if (!strcmp(op,"package-csrf")) {
        p=find_ci(html,"post('doPackage'"); if (!p) p=find_ci(html,"post(\"doPackage\"");
        if (!p) return 1;
        char snippet[1025]; size_t n=strlen(p); if(n>1024)n=1024; memcpy(snippet,p,n);snippet[n]=0;
        return literal(snippet,"csrftoken");
    }
    if (!strcmp(op,"packages")) return choices(html,1);
    if (!strcmp(op,"questions")) return choices(html,0);
    if (!strcmp(op,"package-cancel")) {
        const char *tags[]={"a","button","input"};
        const char *keys[]={"href","action","onclick"};
        for(int i=0;i<3;i++){
            p=html;
            while((p=next_tag(p,tags[i]))){
                if(attr_is(p,"data-toggle","undoPackage"))return 0;
                for(int k=0;k<3;k++)if(attr(p,keys[k],&a,&b)){
                    const char *match=find_ci(a,"undoPackage");if(match && match<b)return 0;
                }
                p++;
            }
        }
        return 1;
    }
    if (!strcmp(op,"enabled")) {
        while ((p=strchr(p,'<'))) {
            if (attr_is(p,"id",name)) {
                end=tag_end(p); a=find_ci(p,"disabled");
                return end && (!a || a>end) ? 0 : 1;
            }
            p++;
        }
        return 1;
    }
    if (!strcmp(op,"mauth")) {
        p=find_ci(html,"oprateMauth"); if(!p)return 1;
        a=strchr(p,'>');b=find_ci(p,"</a>");if(!a || !b)return 1;
        end=strstr(a,"开启");if(end && end<b){printf("1");return 0;}
        end=strstr(a,"关闭");if(end && end<b){printf("0");return 0;}
        return 1;
    }
    if (!strcmp(op, "user-json")) return user_json(html);
    if (!strcmp(op, "metric") && *name) {
        while ((p = next_tag(p, "dt"))) {
            end = find_ci(p, "</dt>"); a = tag_end(p);
            if (!end || !a) return 1;
            const char *label = strstr(a + 1, name);
            const char *dd = next_tag(end + 5, "dd"), *next = next_tag(end + 5, "dt"), *close = find_ci(end + 5, "</dl>");
            if (dd && (!next || dd < next) && (!close || dd < close)) {
                const char *da=tag_end(dd), *db=find_ci(dd,"</dd>");
                if (!da || !db) return 1;
                if (label && label < end) return db-da <= 1024 ? emit_text(da+1,db,1) : 1;
                // Dashboard cards put their value in dt and the caption in dd.
                label=strstr(da+1,name);
                if (label && label < db) return end-a <= 1024 ? emit_text(a+1,end,1) : 1;
            }
            if (label && label < end) return 1;
            p=end+5;
        }
        return 1;
    }
    if (!strcmp(op, "assets")) {
        const char *tags[] = {"script", "link"};
        const char *keys[] = {"src", "href"};
        int count = 0;
        for (int i = 0; i < 2; i++) {
            p = html;
            while ((p = next_tag(p, tags[i]))) {
                if (attr(p, keys[i], &a, &b) && b - a <= 2048 &&
                    !memchr(a, '\n', (size_t)(b - a)) && !memchr(a, '\r', (size_t)(b - a))) {
                    emit_text(a, b, 0); putchar('\n');
                    if (++count >= 16) return 0;
                }
                p++;
            }
        }
        return 0;
    }
    if (!strcmp(op, "input")) {
        while ((p = next_tag(p, "input"))) {
            if (attr_is(p, "name", name)) {
                if (!attr(p, "value", &a, &b)) return 0;
                return emit_text(a, b, 0);
            }
            p++;
        }
    } else if (!strcmp(op, "captcha")) {
        while ((p = next_tag(p, "div"))) {
            if (attr_is(p, "id", "randomDiv")) {
                int hidden = 0;
                if (attr(p, "class", &a, &b)) {
                    while (a < b) {
                        while (a < b && isspace((unsigned char)*a)) a++;
                        end = a;
                        while (end < b && !isspace((unsigned char)*end)) end++;
                        if (end - a == 4 && !strncasecmp(a, "hide", 4)) hidden = 1;
                        a = end;
                    }
                }
                printf("%d", !hidden); return 0;
            }
            p++;
        }
    } else if (!strcmp(op, "action")) {
        while ((p = next_tag(p, "form"))) {
            if (attr_is(p, "method", "post") && attr(p, "action", &a, &b)) return emit_text(a, b, 0);
            p++;
        }
    } else if (!strcmp(op, "status")) {
        while ((p = next_tag(p, "label"))) {
            end = find_ci(p, "</label>");
            if (!end) return 1;
            a = tag_end(p);
            if (a && strstr(a, "状") && strstr(a, "状") < end && strstr(a, "态") && strstr(a, "态") < end) {
                p = end + 8;
                while (isspace((unsigned char)*p)) p++;
                if (strncasecmp(p, "<div", 4)) return 1;
                a = tag_end(p); b = find_ci(p, "</div>");
                if (a && b && a < b) return emit_text(a + 1, b, 1);
                return 1;
            }
            p = end + 8;
        }
    }
    return 1;
}

int main(int argc, char **argv)
{
    char *html;
    size_t size;
    int result;
    if (argc < 2 || argc > 3) return 2;
    html = malloc(LIMIT + 1);
    if (!html) return 1;
    size = fread(html, 1, LIMIT + 1, stdin);
    if (size > LIMIT || ferror(stdin) || memchr(html, 0, size)) { free(html); return 1; }
    html[size] = 0;
    result = extract(html, argv[1], argc == 3 ? argv[2] : "");
    free(html);
    return result;
}

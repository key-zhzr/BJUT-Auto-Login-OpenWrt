/* SPDX-License-Identifier: MIT
 * Batched projections return data pairs, never executable shell text. */
#ifndef BJUT_RUNTIME_BATCH_H
#define BJUT_RUNTIME_BATCH_H
static int variable_name(const char *s, size_t n) {
    if (!n || n>160 || !(isalpha((unsigned char)*s) || *s=='_')) return 0;
    for (size_t i=1;i<n;i++) if (!(isalnum((unsigned char)s[i]) || s[i]=='_')) return 0;
    return 1;
}
static J *json_path(J *o, const char *p) {
    if (*p++!='@') return NULL;
    while (*p && o) {
        char key[256];size_t n=0;
        if (*p=='.') {
            p++;while (*p && *p!='.' && *p!='[' && n+1<sizeof(key)) key[n++]=*p++;
            if (!n || (*p && *p!='.' && *p!='[')) return NULL;
            key[n]=0;o=get(o,key);
        } else if (*p++=='[') {
            if (*p=='"' || *p=='\'') {
                char quote=*p++;
                while (*p && *p!=quote && n+1<sizeof(key)) key[n++]=*p++;
                if (*p!=quote) return NULL;
                p++;if (*p!=']') return NULL;
                p++;
                key[n]=0;o=get(o,key);
            } else {
                char *end;unsigned long index=strtoul(p,&end,10);
                if (p==end || *end!=']' || index>100000 || !json_object_is_type(o,json_type_array)) return NULL;
                p=end+1;o=json_object_array_get_idx(o,index);
            }
        } else return NULL;
    }
    return *p?NULL:o;
}
static J *load_input(const char *file) {
    if (strcmp(file,"-")) return load(file);
    char *buffer=malloc(JSON_LIMIT+1);if(!buffer)return NULL;
    size_t n=fread(buffer,1,JSON_LIMIT+1,stdin);
    J *o=NULL;
    if (n && n<=JSON_LIMIT && !ferror(stdin)) {
        buffer[n]=0;struct json_tokener *tok=json_tokener_new();
        if(tok){o=json_tokener_parse_ex(tok,buffer,(int)n);if(json_tokener_get_error(tok)!=json_tokener_success){json_object_put(o);o=NULL;}json_tokener_free(tok);}
    }
    free(buffer);return o;
}
static int jsonp_file(const char *file) {
    FILE *f=tio_file(file);if(!f)return 1;
    char *buffer=malloc(JSON_LIMIT+1);if(!buffer){fclose(f);return 1;}
    size_t n=fread(buffer,1,JSON_LIMIT+1,f);int ok=n>0 && n<=JSON_LIMIT && !ferror(f);fclose(f);
    J *o=NULL;
    if(ok) {
        buffer[n]=0;char *first=buffer;while(isspace((unsigned char)*first))first++;
        if(*first!='{') {
            char *open=strchr(first,'('),*close=strrchr(first,')');
            if(!open || !close || close<=open){ok=0;}else {first=open+1;*close=0;}
        }
        if(ok) {
            struct json_tokener *tok=json_tokener_new();
            if(tok){
                o=json_tokener_parse_ex(tok,first,(int)strlen(first));
                ok=json_tokener_get_error(tok)==json_tokener_success && json_object_is_type(o,json_type_object);
                const char *tail=first+json_tokener_get_parse_end(tok);while(isspace((unsigned char)*tail))tail++;
                if(*tail)ok=0;
                json_tokener_free(tok);
            }else ok=0;
        }
    }
    if(ok)puts(json_object_to_json_string_ext(o,JSON_C_TO_STRING_PLAIN));
    json_object_put(o);free(buffer);return ok?0:1;
}
static int batch_fields(int argc, char **argv) {
    if (argc<2 || argc>129) return 2;
    for (int i=1;i<argc;i++) {
        const char *equal=strchr(argv[i],'=');
        if(!equal || !variable_name(argv[i],(size_t)(equal-argv[i])) || equal[1]!='@')return 2;
    }
    J *o=load_input(argv[0]);
    for(int i=1;i<argc;i++) {
        const char *equal=strchr(argv[i],'=');J *node=json_path(o,equal+1);
        const char *value=(json_object_is_type(node,json_type_object) || json_object_is_type(node,json_type_array))?json_object_to_json_string_ext(node,JSON_C_TO_STRING_PLAIN):json_object_get_string(node);
        printf("%.*s\n",(int)(equal-argv[i]),argv[i]);
        if(value)fwrite(value,1,strcspn(value,"\n"),stdout);
        putchar('\n');
    }
    /* Preserve a final empty value across shell command substitution. */
    puts("BJUT_FIELDS_END\n1");json_object_put(o);return ferror(stdout)?1:0;
}
#endif

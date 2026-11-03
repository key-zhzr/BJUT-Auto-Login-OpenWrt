/* SPDX-License-Identifier: MIT
 * Validated, non-executable configuration metadata for independent workers.
 * Plaintext credentials are never included in this metadata. */
#ifndef BJUT_RUNTIME_PREPARED_H
#define BJUT_RUNTIME_PREPARED_H
static const char *prepared_options(const char *type) {
    if(!strcmp(type,"service"))return " enabled network network6 device device6 source4 source6 accounts mwan3 managed_routes transport login_type compatibility interval timeout offline_confirmations max_backoff credential_cooldown post_login_delay online_url online_code strict_network expected_ssid expected_bssid log_level log_target log_directory log_web log_max_kb pushplus_enabled pushplus_topic pushplus_online pushplus_failure pushplus_delay pushplus_interval billing_background billing_interval billing_alerts balance_threshold flow_threshold traffic_monitor traffic_scope traffic_minute_hours traffic_hour_days traffic_day_days traffic_storage_mb prefer_remaining_flow bjut_pushplus_ready ";
    if(!strcmp(type,"uplink"))return " enabled network network6 device device6 source4 source6 accounts transport login_type compatibility expected_ssid expected_bssid ";
    if(!strcmp(type,"account"))return " enabled username login_type max_sessions bjut_key bjut_signature bjut_has_password ";
    return "";
}
static int prepared_option(const char *type,const char *option) {
    char token[180];if(!variable_name(option,strlen(option)))return 0;
    snprintf(token,sizeof(token)," %s ",option);
    return strstr(prepared_options(type),token)!=NULL;
}
static int prepared_valid(J *o) {
    J *sections=get(o,"sections");
    if(!json_object_is_type(sections,json_type_object) || json_object_object_length(sections)>256)return 0;
    json_object_object_foreach(sections,id,section) {
        if(!*id || strlen(id)>64 || strspn(id,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")!=strlen(id) || !*prepared_options(str(section,"TYPE")))return 0;
        const char *type=str(section,"TYPE");
        json_object_object_foreach(section,option,value) {
            if(strcmp(option,"TYPE") && !prepared_option(type,option))return 0;
            const char *s=json_object_get_string(value);
            if(!json_object_is_type(value,json_type_string) || !s || strlen(s)>4096 || strpbrk(s,"\r\n"))return 0;
        }
    }
    return 1;
}
static int prepare_config(int argc,char **argv) {
    if(argc!=4)return 2;
    char signature[17];fingerprint(argv[1],argv[2],signature);
    if(!*signature || strcmp(signature,argv[3]))return 75;
    J *o=load_input("-"),*sections=get(o,"sections");
    if(!o || !json_object_is_type(sections,json_type_object)){json_object_put(o);return 1;}
    number(o,"schema",2);text(o,"fingerprint",signature);boolean(o,"validated",1);
    int ok=prepared_valid(o);
    char current[17];fingerprint(argv[1],argv[2],current);
    if(strcmp(signature,current))ok=0;
    if(ok)ok=private_write(argv[0],json_object_to_json_string_ext(o,JSON_C_TO_STRING_PLAIN));
    json_object_put(o);return ok?0:75;
}
static int prepared_config(int argc,char **argv) {
    if(argc!=3)return 2;
    struct stat st;
    if(lstat(argv[0],&st) || !S_ISREG(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&077))return 75;
    J *o=load(argv[0]);char signature[17];fingerprint(argv[1],argv[2],signature);
    if(!o || num(o,"schema")!=2 || !num(o,"validated") || !*signature || strcmp(signature,str(o,"fingerprint")) || !prepared_valid(o)){json_object_put(o);return 75;}
    J *sections=get(o,"sections");char section_list[17000]="";size_t n=0;
    json_object_object_foreach(sections,id,section) {
        size_t length=strlen(id);if(n){section_list[n++]=' ';}memcpy(section_list+n,id,length+1);n+=length;
        json_object_object_foreach(section,option,value) {
            printf("CONFIG_%s_%s\n%s\n",id,option,json_object_get_string(value));
        }
    }
    printf("CONFIG_SECTIONS\n%s\nCONFIG_GENERATION\n%s\nCONFIG_PREPARED\n1\nBJUT_FIELDS_END\n1\n",section_list,signature);
    json_object_put(o);return ferror(stdout)?1:0;
}
#endif

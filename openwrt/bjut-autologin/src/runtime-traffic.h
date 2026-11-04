/* SPDX-License-Identifier: MIT
 * One online-list parse for the display, identity match and billing deltas.
 * The caller owns the existing history lock for the entire ingest. */
#ifndef BJUT_RUNTIME_TRAFFIC_H
#define BJUT_RUNTIME_TRAFFIC_H
#include <arpa/inet.h>
#include <math.h>
typedef struct { char id[128],name[128],mac[256],ip[INET6_ADDRSTRLEN]; } TrafficIdentity;
typedef struct {
    char key[65],used[64]; int64_t at;
} TrafficBaseline;
static void bounded_copy(char *out,size_t size,const char *s) {
    if(!size)return;
    size_t n=strnlen(s,size-1);memcpy(out,s,n);out[n]=0;
}
static void scalar(J *o,const char *key,char *out,size_t size) {
    const char *s=str(o,key);size_t n=strcspn(s,"\n");
    if(n>=size)n=size-1;
    memcpy(out,s,n);out[n]=0;
}
static void normalize_address(const char *s,char out[INET6_ADDRSTRLEN]) {
    unsigned char address[16];int family=strchr(s,':')?AF_INET6:AF_INET;
    out[0]=0;
    if(inet_pton(family,s,address)==1 && !inet_ntop(family,address,out,INET6_ADDRSTRLEN))out[0]=0;
}
static void normalize_mac(const char *s,char *out,size_t size) {
    size_t n=0;
    for(;*s && n+1<size;s++)if(!strchr(":.-",*s))out[n++]=(char)tolower((unsigned char)*s);
    out[n]=0;
}
static void display_mac(const char *s,char *out,size_t size) {
    char compact[13];size_t n=0;
    for(const char *p=s;*p;p++)if(isxdigit((unsigned char)*p)) {
        if(n>=12){bounded_copy(out,size,s);return;}
        compact[n++]=(char)toupper((unsigned char)*p);
    }
    if(n!=12){bounded_copy(out,size,s);return;}
    snprintf(out,size,"%c%c-%c%c-%c%c-%c%c-%c%c-%c%c",compact[0],compact[1],compact[2],compact[3],compact[4],compact[5],compact[6],compact[7],compact[8],compact[9],compact[10],compact[11]);
}
static size_t traffic_identities(const char *state,TrafficIdentity *ids,size_t maximum) {
    char file[PATH_MAX],line[1024],*p[4];size_t n=0;
    path(file,sizeof(file),state,"traffic-identities.tsv");FILE *f=tio_file(file);
    if(!f)return 0;
    while(n<maximum && fgets(line,sizeof(line),f)) {
        if(tio_fields(line,p,4)!=4 || !safe_name(p[0]) || !safe_name(p[1]) || strlen(p[0])>=sizeof(ids[n].id) || strlen(p[1])>=sizeof(ids[n].name) || strlen(p[2])>=sizeof(ids[n].mac))continue;
        normalize_address(p[3],ids[n].ip);if(!*ids[n].ip)continue;
        strcpy(ids[n].id,p[0]);strcpy(ids[n].name,p[1]);strcpy(ids[n].mac,p[2]);n++;
    }
    fclose(f);return n;
}
static int traffic_identity(TrafficIdentity *ids,size_t n,const char *mac,const char *ip,const char *ipv6,char id[128],char name[256]) {
    char v4[INET6_ADDRSTRLEN],v6[INET6_ADDRSTRLEN],digest[65];int primary=-1,secondary=-1;
    normalize_address(ip,v4);normalize_address(ipv6,v6);
    for(size_t i=0;i<n;i++) {
        if(*mac && strcmp(ids[i].mac,"-") && !strcmp(ids[i].mac,mac)){primary=(int)i;break;}
        if(*v4 && !strcmp(ids[i].ip,v4))primary=(int)i;
        if(*v6 && !strcmp(ids[i].ip,v6))secondary=(int)i;
    }
    int match=primary>=0?primary:secondary;
    if(match>=0) {strcpy(id,ids[match].id);strcpy(name,ids[match].name);return 1;}
    sha_text(*mac?mac:(*v4?v4:v6),digest);
    snprintf(id,128,"device:%.16s",digest);
    bounded_copy(name,256,*mac?mac:(*v4?v4:"device"));return 0;
}
static int decimal_counter(const char *s,char used[64],double *value) {
    const char *p=s;if(!isdigit((unsigned char)*p))return 0;
    while(isdigit((unsigned char)*p))p++;
    if(*p=='.'){p++;if(!isdigit((unsigned char)*p))return 0;while(isdigit((unsigned char)*p))p++;}
    if(*p)return 0;
    char *end;double v=strtod(s,&end)/1024;
    if(*end || !isfinite(v) || v<0 || v>1e15)return 0;
    snprintf(used,64,"%.3f",v);*value=strtod(used,NULL);return 1;
}
static J *traffic_array(J *o) {
    J *rows=get(o,"rows"),*data=get(o,"data");
    if(json_object_is_type(data,json_type_string) && !json_object_get_string_len(data))data=NULL;
    if(json_object_is_type(rows,json_type_string) && !json_object_get_string_len(rows))rows=NULL;
    if(data)o=data;else if(rows)o=rows;
    return json_object_is_type(o,json_type_array)?o:NULL;
}
static int private_write(const char *file,const char *value);
static int online_capture(const char *input,const char *output) {
    FILE *f=tio_file(input);if(!f)return 1;
    char *buffer=malloc(JSON_LIMIT+1);if(!buffer){fclose(f);return 1;}
    size_t n=fread(buffer,1,JSON_LIMIT+1,f);int ok=n<=JSON_LIMIT && !ferror(f);fclose(f);
    J *o=NULL,*rows=NULL;enum json_tokener_error error=json_tokener_error_parse_unexpected;
    if(ok) {
        buffer[n]=0;const char *p=buffer;
        if(n>=3 && !memcmp(p,"\xef\xbb\xbf",3))p+=3;
        o=json_tokener_parse_verbose(p,&error);ok=error==json_tokener_success;
        if(ok && json_object_is_type(o,json_type_string)) {
            J *nested=json_tokener_parse_verbose(json_object_get_string(o),&error);json_object_put(o);o=nested;ok=error==json_tokener_success;
        }
    }
    if(ok && !o) {o=json_object_new_array();rows=o;}
    else if(ok && json_object_is_type(o,json_type_array))rows=o;
    else if(ok) {
        rows=get(o,"rows");if(!json_object_is_type(rows,json_type_array))rows=get(o,"data");
    }
    if(!json_object_is_type(rows,json_type_array) || json_object_array_length(rows)>500)ok=0;
    if(ok)for(size_t i=0;i<json_object_array_length(rows);i++) {
        J *row=json_object_array_get_idx(rows,i),*id=get(row,"sessionId");const char *s=json_object_get_string(id);
        if(!s || !*s || !strcmp(s,"null") || strlen(s)>256 || strpbrk(s,"\r\n") || json_object_is_type(id,json_type_object) || json_object_is_type(id,json_type_array)){ok=0;break;}
    }
    if(ok)ok=private_write(output,json_object_to_json_string_ext(rows,JSON_C_TO_STRING_PLAIN));
    json_object_put(o);free(buffer);return ok?0:1;
}
static int private_write(const char *file,const char *value) {
    char tmp[PATH_MAX];size_t n=strlen(file);
    if(n+40>=sizeof(tmp))return 0;
    memcpy(tmp,file,n);snprintf(tmp+n,sizeof(tmp)-n,".tmp.%ld",(long)getpid());
    int fd=open(tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)return 0;
    size_t left=strlen(value);const char *p=value;int ok=1;
    while(left) {ssize_t done=write(fd,p,left);if(done<0 && errno==EINTR)continue;if(done<=0){ok=0;break;}left-=(size_t)done;p+=done;}
    if(close(fd))ok=0;
    struct stat st;if(!lstat(file,&st) && !S_ISREG(st.st_mode))ok=0;
    if(ok && rename(tmp,file))ok=0;
    if(!ok)unlink(tmp);
    return ok;
}
static FILE *journal_open(const char *directory,const char *name,off_t *length) {
    char file[PATH_MAX];path(file,sizeof(file),directory,name);
    int fd=open(file,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600);struct stat st;
    if(fd<0)return NULL;
    if(fstat(fd,&st) || !S_ISREG(st.st_mode)){close(fd);return NULL;}
    *length=st.st_size;FILE *f=fdopen(fd,"a");if(!f)close(fd);return f;
}
static void baseline_expire(const char *directory) {
    DIR *d=opendir(directory);if(!d)return;
    struct dirent *e;time_t at=time(NULL);
    while((e=readdir(d))) {
        if(strlen(e->d_name)!=64 || strspn(e->d_name,"0123456789abcdef")!=64)continue;
        struct stat st;
        if(!fstatat(dirfd(d),e->d_name,&st,AT_SYMLINK_NOFOLLOW) && S_ISREG(st.st_mode) && at-st.st_mtime>259200)unlinkat(dirfd(d),e->d_name,0);
    }
    closedir(d);
}
static int traffic_process(int argc,char **argv,int ingest) {
    if(argc!=(ingest?6:3) || (strcmp(argv[2],"local") && strcmp(argv[2],"all")))return 2;
    const char *file=argv[0],*state=argv[1],*scope=argv[2],*account=ingest?argv[3]:"";
    char *end;int64_t at=ingest?strtoll(argv[4],&end,10):0;
    if(ingest && (*end || at<0 || at>7258089599LL || strlen(account)!=64 || strspn(account,"0123456789abcdef")!=64))return 2;
    J *root=load(file),*rows=traffic_array(root),*devices=json_object_new_array();
    if(!devices){json_object_put(root);return 1;}
    TrafficIdentity ids[256];size_t nids=traffic_identities(state,ids,256);
    TrafficBaseline baselines[500];size_t nbaseline=0;int resets=0,rollbacks=0,ok=1,journal_committed=0;
    char directory[PATH_MAX],baseline_dir[PATH_MAX],day[32];FILE *samples=NULL,*curves=NULL;off_t sample_size=0,curve_size=0;
    if(ingest) {
        if(!tio_directory(state,directory,sizeof(directory)))snprintf(directory,sizeof(directory),"%s",state);
        path(baseline_dir,sizeof(baseline_dir),state,"traffic-baselines");
        struct stat st;if((mkdir(baseline_dir,0700) && errno!=EEXIST) || lstat(baseline_dir,&st) || !S_ISDIR(st.st_mode)){ok=0;goto done;}
        samples=journal_open(directory,"usage-samples.tsv",&sample_size);curves=journal_open(directory,"usage-curves.tsv",&curve_size);
        if(!samples || !curves){ok=0;goto done;}
        time_t stamp=(time_t)(at+28800);struct tm tm;
        if(!gmtime_r(&stamp,&tm) || !strftime(day,sizeof(day),"%Y-%m-%d",&tm)){ok=0;goto done;}
    }
    size_t count=rows?json_object_array_length(rows):0;if(count>500)count=500;
    for(size_t i=0;i<count;i++) {
        J *row=json_object_array_get_idx(rows,i);char session_id[4097];scalar(row,"sessionId",session_id,sizeof(session_id));
        if(!*session_id)break;
        char mac_raw[4097],ip[4097],ipv6[4097],login[4097],down[4097],mac[4097],id[128],name[256],used[64];double value=0;
        scalar(row,"mac",mac_raw,sizeof(mac_raw));scalar(row,"ip",ip,sizeof(ip));scalar(row,"ipv6",ipv6,sizeof(ipv6));scalar(row,"loginTime",login,sizeof(login));scalar(row,"downFlow",down,sizeof(down));
        normalize_mac(mac_raw,mac,sizeof(mac));int local=traffic_identity(ids,nids,mac,ip,ipv6,id,name);
        if(!strcmp(scope,"local") && !local)continue;
        int valid=decimal_counter(down,used,&value);
        J *device=json_object_new_object();text(device,"interfaceId",id);text(device,"interfaceName",name);boolean(device,"local",local);
        text(device,"loginAt",strlen(login)<=256?login:"");text(device,"ip",strlen(ip)<=256?ip:"");text(device,"ipv6",strlen(ipv6)<=256?ipv6:"");
        char formatted[257];display_mac(strlen(mac_raw)<=256?mac_raw:"",formatted,sizeof(formatted));text(device,"mac",formatted);
        text(device,"usedFlowMb",valid?used:"--");json_object_array_add(devices,device);
        if(!ingest || !valid)continue;
        TrafficBaseline *b=&baselines[nbaseline++];char digest[65],device_key[17],baseline_path[PATH_MAX],previous[128];
        sha_text(*mac?mac:ip,digest);memcpy(device_key,digest,16);device_key[16]=0;
        BjutSha s;sha_init(&s);const char *parts[]={account,device_key,ip,login,id};
        for(int j=0;j<5;j++){if(j)sha_update(&s,":",1);sha_update(&s,parts[j],strlen(parts[j]));}sha_final(&s,b->key);
        path(baseline_path,sizeof(baseline_path),baseline_dir,b->key);
        int64_t previous_at=0;double previous_used=value;char previous_value[64],suffix;
        FILE *baseline=tio_file(baseline_path);
        int has_previous=baseline && fgets(previous,sizeof(previous),baseline)!=NULL;
        if(baseline)fclose(baseline);
        if(has_previous) {
            long long stamp;
            if(sscanf(previous,"%lld %63s %c",&stamp,previous_value,&suffix)==2 && stamp>=0) {
                previous_at=(int64_t)stamp;char *tail;double parsed=strtod(previous_value,&tail);
                if(!*tail && isfinite(parsed) && parsed>=0)previous_used=parsed;else previous_at=0;
            }
        }
        /* Duplicate rows must see the baseline already advanced by this
         * response, just as the old sequential collector did. */
        for(size_t j=0;j+1<nbaseline;j++)if(!strcmp(baselines[j].key,b->key)) {
            previous_at=baselines[j].at;previous_used=strtod(baselines[j].used,NULL);
        }
        int64_t elapsed=at-previous_at;
        if(elapsed>0 && elapsed<=180 && value>=previous_used) {
            const char *label=*mac?mac:ip;
            if(!*label || strspn(label,"0123456789abcdefABCDEF:.-")!=strlen(label))label="device";
            fprintf(samples,"%s\t%s\t%s\t%s\t%.3f\t%" PRId64 "\t%d\n",day,account,device_key,label,value-previous_used,elapsed,local);
            static const int resolutions[]={60,3600,86400};
            for(int j=0;j<3;j++) {
                int resolution=resolutions[j];int64_t bucket=(at+28800)/resolution*resolution-28800;
                fprintf(curves,"%d\t%" PRId64 "\t%.16s\t%s\t%s\t%s\t%d\t%.3f\t%" PRId64 "\t%" PRId64 "\t%" PRId64 "\n",resolution,bucket,account,device_key,id,name,local,value-previous_used,elapsed,previous_at,at);
            }
        } else if(previous_at && elapsed>180)resets++;
        else if(previous_at)rollbacks++;
        b->at=at;snprintf(b->used,sizeof(b->used),"%.3f",value>previous_used?value:previous_used);
    }
    if(ingest) {
        if(fflush(samples) || ferror(samples) || fflush(curves) || ferror(curves)){ok=0;goto done;}
        journal_committed=1;
        for(size_t i=0;i<nbaseline;i++) {
            char file_path[PATH_MAX],value[128];path(file_path,sizeof(file_path),baseline_dir,baselines[i].key);
            snprintf(value,sizeof(value),"%" PRId64 " %s\n",baselines[i].at,baselines[i].used);
            if(!private_write(file_path,value)){ok=0;break;}
        }
        if(ok && strcmp(argv[5],"-") && !private_write(argv[5],json_object_to_json_string_ext(devices,JSON_C_TO_STRING_PLAIN)))ok=0;
        if(ok) {baseline_expire(baseline_dir);printf("%zu %d %d\n",nbaseline,resets,rollbacks);}
    } else puts(json_object_to_json_string_ext(devices,JSON_C_TO_STRING_PLAIN));
done:
    if(!ok && !journal_committed) {
        if(samples){fflush(samples);if(ftruncate(fileno(samples),sample_size))fputs("BJUT traffic: sample journal rollback failed\n",stderr);}
        if(curves){fflush(curves);if(ftruncate(fileno(curves),curve_size))fputs("BJUT traffic: curve journal rollback failed\n",stderr);}
    }
    if(samples && fclose(samples))ok=0;
    if(curves && fclose(curves))ok=0;
    json_object_put(root);json_object_put(devices);return ok?0:1;
}
#endif

/* SPDX-License-Identifier: MIT
 * A shared ubus dump plus current kernel addresses. No routing changes. */
#ifndef BJUT_RUNTIME_NETWORK_H
#define BJUT_RUNTIME_NETWORK_H
#include <ifaddrs.h>
#include <net/if.h>
typedef struct { char device[128],ip[INET6_ADDRSTRLEN];int family; } NetAddress;
static int device_name(const char *s) {
    return s && *s && strlen(s)<128 && strspn(s,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-")==strlen(s);
}
static int campus4(const char *s) {
    unsigned a,b,c,d;char extra;
    if(sscanf(s,"%u.%u.%u.%u%c",&a,&b,&c,&d,&extra)!=4 || c>255 || d>255)return 0;
    return (a==10 && ((b>=17 && b<=27) || b==121 || b==126 || b==226)) || (a==172 && ((b>=17 && b<=27) || b==30));
}
static int ipv6_ready(const char *device,const struct in6_addr *address) {
#ifdef __linux__
    FILE *f=fopen("/proc/net/if_inet6","r");if(!f)return 0;
    char wanted[33],hex[33],name[128];unsigned index,prefix,scope,flags;int ready=0;
    for(int i=0;i<16;i++)snprintf(wanted+2*i,3,"%02x",address->s6_addr[i]);
    while(fscanf(f,"%32s %x %x %x %x %127s",hex,&index,&prefix,&scope,&flags,name)==6) {
        if(!strcmp(name,device) && !strcmp(hex,wanted)) {ready=!(flags&(0x08|0x20|0x40));break;}
    }
    fclose(f);return ready;
#else
    (void)device;(void)address;return 1;
#endif
}
static size_t net_addresses(NetAddress *out,size_t maximum) {
    const char *fixture=getenv("BJUT_NATIVE_ADDRESSES");
    if(fixture && *fixture) {
        J *o=load(fixture);size_t n=0,count=json_object_is_type(o,json_type_array)?json_object_array_length(o):0;
        for(size_t i=0;i<count && n<maximum;i++) {
            J *v=json_object_array_get_idx(o,i);const char *device=str(v,"device"),*ip=str(v,"ip");
            if(!device_name(device) || num(v,"unusable"))continue;
            normalize_address(ip,out[n].ip);if(!*out[n].ip)continue;
            strcpy(out[n].device,device);out[n].family=strchr(ip,':')?AF_INET6:AF_INET;n++;
        }
        json_object_put(o);return n;
    }
    struct ifaddrs *addresses=NULL;size_t n=0;
    if(getifaddrs(&addresses))return 0;
    for(struct ifaddrs *p=addresses;p && n<maximum;p=p->ifa_next) {
        if(!p->ifa_addr || !device_name(p->ifa_name) || !(p->ifa_flags&IFF_UP))continue;
        int family=p->ifa_addr->sa_family;void *ip=NULL;
        if(family==AF_INET)ip=&((struct sockaddr_in *)p->ifa_addr)->sin_addr;
        else if(family==AF_INET6) {
            struct in6_addr *v=&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
            if(IN6_IS_ADDR_LINKLOCAL(v) || IN6_IS_ADDR_LOOPBACK(v) || IN6_IS_ADDR_MULTICAST(v) || !ipv6_ready(p->ifa_name,v))continue;
            ip=v;
        }
        if(!ip || !inet_ntop(family,ip,out[n].ip,sizeof(out[n].ip)))continue;
        strcpy(out[n].device,p->ifa_name);out[n].family=family;n++;
    }
    freeifaddrs(addresses);return n;
}
static J *net_status(J *dump,const char *network) {
    J *rows=get(dump,"interface");size_t count=json_object_is_type(rows,json_type_array)?json_object_array_length(rows):0;
    for(size_t i=0;i<count;i++){J *row=json_object_array_get_idx(rows,i);if(!strcmp(str(row,"interface"),network))return row;}
    return NULL;
}
static int kernel_address(NetAddress *addresses,size_t count,const char *device,int family,const char *wanted,char out[INET6_ADDRSTRLEN]) {
    char normalized[INET6_ADDRSTRLEN];normalize_address(wanted,normalized);out[0]=0;
    if(*wanted && !*normalized)return 0;
    for(size_t i=0;i<count;i++) {
        if(addresses[i].family!=family || strcmp(addresses[i].device,device))continue;
        if(*wanted && strcmp(addresses[i].ip,normalized))continue;
        if(family==AF_INET6 && !*wanted && *addresses[i].ip!='2' && *addresses[i].ip!='3')continue;
        strcpy(out,addresses[i].ip);return 1;
    }
    return 0;
}
static J *net_identity(J *dump,NetAddress *addresses,size_t count,const char *sys,const char *network,const char *device,const char *network6,const char *device6,const char *source4,const char *source6) {
    J *v4=net_status(dump,network),*v6=v4;
    if(!num(v4,"up")){v4=net_status(dump,network6);if(!num(v4,"up"))return NULL;}
    const char *d4=*device?device:str(v4,"l3_device");if(!*d4)d4=str(v4,"device");
    if(!device_name(d4))return NULL;
    char file[PATH_MAX],ip4[INET6_ADDRSTRLEN],ip6[INET6_ADDRSTRLEN]="",prefix[180]="";
    path(file,sizeof(file),sys,d4);struct stat st;if(stat(file,&st) || !S_ISDIR(st.st_mode))return NULL;
    const char *wanted=*source4?source4:json_object_get_string(json_path(v4,"@[\"ipv4-address\"][0].address"));
    kernel_address(addresses,count,d4,AF_INET,wanted?wanted:"",ip4);
    if(!*source4 && wanted && campus4(wanted) && !*ip4)return NULL;
    const char *d6=*device6?device6:d4;
    if(*network6) {
        v6=net_status(dump,network6);
        if(num(v6,"up")){d6=*device6?device6:str(v6,"l3_device");if(!*d6)d6=str(v6,"device");}else {v6=NULL;d6=d4;}
    }
    if(v6 && device_name(d6)) {
        path(file,sizeof(file),sys,d6);
        if(!stat(file,&st) && S_ISDIR(st.st_mode)) {
            kernel_address(addresses,count,d6,AF_INET6,source6,ip6);
            const char *p=json_object_get_string(json_path(v6,"@[\"ipv6-prefix\"][0].address"));
            J *mask=json_path(v6,"@[\"ipv6-prefix\"][0].mask");char normalized[INET6_ADDRSTRLEN];normalize_address(p?p:"",normalized);
            if(*normalized && strchr(normalized,':') && mask && json_object_get_int(mask)>=0 && json_object_get_int(mask)<=128)snprintf(prefix,sizeof(prefix),"%s/%d",normalized,json_object_get_int(mask));
        }
    }
    if(!campus4(ip4)) {if(strncmp(ip6,"2001:da8:216:",13))return NULL;ip4[0]=0;}
    J *o=json_object_new_object();text(o,"DEVICE",d4);text(o,"DEVICE6",d6);text(o,"LOCAL_IPV4",ip4);text(o,"LOCAL_IPV6",ip6);text(o,"IPV6_PD",prefix);
    text(o,"NETWORK_JSON4",json_object_to_json_string_ext(v4,JSON_C_TO_STRING_PLAIN));
    text(o,"NETWORK_JSON6",v6?json_object_to_json_string_ext(v6,JSON_C_TO_STRING_PLAIN):"");return o;
}
static int network_read(int argc,char **argv) {
    if(argc!=9)return 2;
    struct stat st;
    if(lstat(argv[0],&st) || !S_ISREG(st.st_mode) || st.st_uid!=geteuid() || (st.st_mode&077) || time(NULL)<st.st_mtime || time(NULL)-st.st_mtime>5)return 75;
    J *dump=load(argv[0]);
    if(strcmp(str(dump,"bjutFingerprint"),argv[8])){json_object_put(dump);return 75;}
    NetAddress addresses[1024];size_t n=net_addresses(addresses,1024);
    J *o=net_identity(dump,addresses,n,argv[1],argv[2],argv[3],argv[4],argv[5],argv[6],argv[7]);
    if(!o){json_object_put(dump);return 75;}
    json_object_object_foreach(o,key,value)printf("%s\n%s\n",key,json_object_get_string(value));
    puts("BJUT_FIELDS_END\n1");json_object_put(o);json_object_put(dump);return 0;
}
static int identity_line_compare(const void *a,const void *b){return strcmp(*(const char *const *)a,*(const char *const *)b);}
static int network_identities(int argc,char **argv) {
    if(argc!=5)return 2;
    J *dump=load(argv[0]),*ctx=load(argv[1]),*sections=get(ctx,"sections"),*main=NULL;
    if(!prepared_valid(ctx) || strcmp(str(ctx,"fingerprint"),argv[4]) || strcmp(str(dump,"bjutFingerprint"),argv[4])){json_object_put(dump);json_object_put(ctx);return 75;}
    json_object_object_foreach(sections,service_id,item){(void)service_id;if(!strcmp(str(item,"TYPE"),"service")){main=item;break;}}
    NetAddress addresses[1024];size_t n=net_addresses(addresses,1024);char *output=NULL;size_t length=0;FILE *f=open_memstream(&output,&length);
    if(!f){json_object_put(dump);json_object_put(ctx);return 1;}
    char seen[256][128];size_t nseen=0;
    json_object_object_foreach(sections,id,section) {
        (void)id;if(strcmp(str(section,"TYPE"),"uplink"))continue;
        const char *network=str(section,"network");if(!*network)network=str(main,"network");
        J *o=net_identity(dump,addresses,n,argv[2],network,str(section,"device"),str(section,"network6"),str(section,"device6"),str(section,"source4"),str(section,"source6"));
        if(!o)continue;
        const char *devices[]={str(o,"DEVICE"),str(o,"DEVICE6")};
        for(int family=0;family<2;family++) {
            const char *device=devices[family];if(!device_name(device) || (family && !strcmp(device,devices[0])))continue;
            int found=0;for(size_t j=0;j<nseen;j++)if(!strcmp(seen[j],device)){found=1;break;}
            if(found || nseen>=256)continue;
            strcpy(seen[nseen++],device);
            char path_name[PATH_MAX],mac[256],raw[256]="";path(path_name,sizeof(path_name),argv[2],device);
            size_t plen=strlen(path_name);if(plen+9>=sizeof(path_name))continue;memcpy(path_name+plen,"/address",9);
            read_line(path_name,raw,sizeof(raw));normalize_mac(raw,mac,sizeof(mac));
            for(size_t i=0;i<n;i++)if(!strcmp(addresses[i].device,device))fprintf(f,"interface:%s\t%s\t%s\t%s\n",device,device,*mac?mac:"-",addresses[i].ip);
        }
        json_object_put(o);
    }
    int ok=!ferror(f);if(fclose(f))ok=0;
    /* Keep the legacy sort -u order: shared MACs on different VLANs must
     * resolve to the same first identity after an upgrade or UCI reorder. */
    if(ok && length) {
        char *lines[2048],*save=NULL,*line;size_t count=0;
        for(line=strtok_r(output,"\n",&save);line;line=strtok_r(NULL,"\n",&save)) {
            if(count>=2048){ok=0;break;}lines[count++]=line;
        }
        qsort(lines,count,sizeof(*lines),identity_line_compare);
        char *sorted=malloc(length+1);size_t used=0;
        if(!sorted)ok=0;
        else {
            for(size_t i=0;i<count;i++)if(!i || strcmp(lines[i-1],lines[i])){size_t nline=strlen(lines[i]);memcpy(sorted+used,lines[i],nline);used+=nline;sorted[used++]='\n';}
            sorted[used]=0;if(ok)ok=private_write(argv[3],sorted);free(sorted);
        }
    }else if(ok)ok=private_write(argv[3],"");
    free(output);json_object_put(dump);json_object_put(ctx);return ok?0:1;
}
static int network_save(int argc,char **argv) {
    if(argc!=2 || strlen(argv[1])!=16 || strspn(argv[1],"0123456789abcdef")!=16)return 2;
    J *o=load_input("-");
    if(!json_object_is_type(get(o,"interface"),json_type_array)){json_object_put(o);return 75;}
    text(o,"bjutFingerprint",argv[1]);
    int ok=private_write(argv[0],json_object_to_json_string_ext(o,JSON_C_TO_STRING_PLAIN));json_object_put(o);return ok?0:1;
}
#endif

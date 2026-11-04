/* SPDX-License-Identifier: MIT
 * Read-only live route/rule audit. A miss always uses the original installer. */
#ifndef BJUT_RUNTIME_ROUTES_H
#define BJUT_RUNTIME_ROUTES_H
#ifdef __linux__
#include <linux/rtnetlink.h>
#include <linux/fib_rules.h>
#include <sys/socket.h>
#include <sys/time.h>
static int route_dump(J *rows,int family,int rules) {
    int fd=socket(AF_NETLINK,SOCK_RAW,NETLINK_ROUTE);if(fd<0)return 0;
    struct timeval timeout={0,200000};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    struct {struct nlmsghdr h;struct rtmsg r;} request;
    memset(&request,0,sizeof(request));request.h.nlmsg_len=sizeof(request);request.h.nlmsg_type=rules?RTM_GETRULE:RTM_GETROUTE;request.h.nlmsg_flags=NLM_F_REQUEST|NLM_F_DUMP;request.h.nlmsg_seq=1;request.r.rtm_family=(unsigned char)family;
    struct sockaddr_nl address;memset(&address,0,sizeof(address));address.nl_family=AF_NETLINK;
    if(sendto(fd,&request,sizeof(request),0,(struct sockaddr *)&address,sizeof(address))!=(ssize_t)sizeof(request)){close(fd);return 0;}
    union {struct nlmsghdr alignment;char data[32768];} buffer;int ok=0;int64_t deadline=monotonic_ms()+300;
    for(int batch=0;batch<128 && monotonic_ms()<deadline;batch++) {
        ssize_t bytes=recv(fd,buffer.data,sizeof(buffer.data),0);if(bytes<=0)break;
        int left=(int)bytes;
        for(struct nlmsghdr *h=(struct nlmsghdr *)buffer.data;NLMSG_OK(h,left);h=NLMSG_NEXT(h,left)) {
            if(h->nlmsg_seq!=1)continue;
            if(h->nlmsg_type==NLMSG_DONE){int error=0;if(NLMSG_PAYLOAD(h,0)>=sizeof(error))memcpy(&error,NLMSG_DATA(h),sizeof(error));ok=!error && !(h->nlmsg_flags&NLM_F_DUMP_INTR);goto done;}
            if(h->nlmsg_type==NLMSG_ERROR)goto done;
            if(h->nlmsg_type!=(rules?RTM_NEWRULE:RTM_NEWROUTE) || NLMSG_PAYLOAD(h,0)<sizeof(struct rtmsg))continue;
            J *o=json_object_new_object();number(o,"family",family==AF_INET?4:6);
            struct rtmsg *rt=NLMSG_DATA(h);struct fib_rule_hdr *rule=NLMSG_DATA(h);
            number(o,"prefix",rules?rule->src_len:rt->rtm_dst_len);number(o,"table",rules?rule->table:rt->rtm_table);
            number(o,"type",rules?rule->action:rt->rtm_type);
            if(!rules){number(o,"proto",rt->rtm_protocol);number(o,"scope",rt->rtm_scope);}
            int length=(int)NLMSG_PAYLOAD(h,sizeof(*rt));
            struct rtattr *a=(struct rtattr *)((char *)rt+NLMSG_ALIGN(sizeof(*rt)));
            for(;RTA_OK(a,length);a=RTA_NEXT(a,length)) {
                unsigned type=a->rta_type;size_t n=RTA_PAYLOAD(a);uint32_t value=0;char ip[INET6_ADDRSTRLEN];
                if(rules && type==FRA_OIFNAME && n>0 && n<128 && ((char *)RTA_DATA(a))[n-1]==0)text(o,"device",RTA_DATA(a));
                else if(rules && type==FRA_PROTOCOL && n==1)number(o,"proto",*(unsigned char *)RTA_DATA(a));
                else if(n==4 && ((rules && (type==FRA_TABLE || type==FRA_PRIORITY)) || (!rules && (type==RTA_TABLE || type==RTA_OIF)))) {
                    memcpy(&value,RTA_DATA(a),4);
                    if((rules && type==FRA_TABLE) || (!rules && type==RTA_TABLE))number(o,"table",value);
                    else if(rules)number(o,"priority",value);
                    else {char device[IF_NAMESIZE];if(if_indextoname(value,device))text(o,"device",device);}
                } else if(n==(size_t)(family==AF_INET?4:16) && ((rules && type==FRA_SRC) || (!rules && (type==RTA_DST || type==RTA_GATEWAY || type==RTA_PREFSRC)))) {
                    if(inet_ntop(family,RTA_DATA(a),ip,sizeof(ip)))text(o,rules?"source":(type==RTA_DST?"destination":type==RTA_GATEWAY?"gateway":"source"),ip);
                }
            }
            if(length || json_object_array_length(rows)>=16384){json_object_put(o);goto done;}
            json_object_array_add(rows,o);
        }
    }
done:close(fd);return ok;
}
#endif
static J *route_facts(void) {
    const char *fixture=getenv("BJUT_NATIVE_ROUTES");if(fixture && *fixture)return load(fixture);
#ifdef __linux__
    J *o=json_object_new_object(),*routes=json_object_new_array(),*rules=json_object_new_array();
    json_object_object_add(o,"routes",routes);json_object_object_add(o,"rules",rules);
    if(route_dump(routes,AF_INET,0) && route_dump(routes,AF_INET6,0) && route_dump(rules,AF_INET,1) && route_dump(rules,AF_INET6,1))return o;
    json_object_put(o);
#endif
    return NULL;
}
static size_t route_count(J *o){return json_object_is_type(o,json_type_array)?json_object_array_length(o):0;}
static int text_compare(const void *a,const void *b){return strcmp(*(const char *const *)a,*(const char *const *)b);}
static uint32_t connected_hash(J *routes,int family,const char *device) {
    char *prefixes[2048];size_t n=0,count=route_count(routes);uint32_t hash=UINT32_C(2166136261);
    for(size_t i=0;i<count;i++) {
        J *r=json_object_array_get_idx(routes,i);
        if(num(r,"family")!=family || strcmp(str(r,"device"),device) || num(r,"proto")==186 || num(r,"scope")!=253)continue;
        char prefix[160];int type=(int)num(r,"type"),bits=(int)num(r,"prefix");
        if(type==3)strcpy(prefix,"broadcast");
        else if(type==1) {
            if(!bits)strcpy(prefix,"default");
            else if(bits==(family==4?32:128))bounded_copy(prefix,sizeof(prefix),str(r,"destination"));
            else snprintf(prefix,sizeof(prefix),"%s/%d",str(r,"destination"),bits);
        } else continue;
        if(n>=2048)break;
        prefixes[n]=strdup(prefix);if(!prefixes[n])break;n++;
    }
    qsort(prefixes,n,sizeof(*prefixes),text_compare);const char *last=NULL;
    for(size_t i=0;i<n;i++)if(!last || strcmp(last,prefixes[i])) {
        if(last)hash=(hash^'\n')*UINT32_C(16777619);
        for(const unsigned char *p=(unsigned char *)prefixes[i];*p;p++)hash=(hash^*p)*UINT32_C(16777619);
        last=prefixes[i];
    }
    for(size_t i=0;i<n;i++)free(prefixes[i]);
    return hash;
}
static int family_route_current(J *facts,J *status,const char *state,const char *uplink,int family,const char *device,const char *ip) {
    char name[160],file[PATH_MAX],line[512];snprintf(name,sizeof(name),"routes-%s-%d",uplink,family);path(file,sizeof(file),state,name);
    if(!*ip)return access(file,F_OK)!=0;
    FILE *f=tio_file(file);if(!f)return 0;
    int found=fgets(line,sizeof(line),f)!=NULL;fclose(f);if(!found)return 0;
    int saved_family,table;unsigned long saved_hash;char source[80],saved_device[128],gateway[80],owner[65],tail;
    if(sscanf(line,"%d %d %79s %127s %79s %64s %lu %c",&saved_family,&table,source,saved_device,gateway,owner,&saved_hash,&tail)!=7 || saved_family!=family || table<40000 || table>44999 || strcmp(saved_device,device) || strcmp(owner,uplink))return 0;
    char wanted[80];snprintf(wanted,sizeof(wanted),"%s/%d",ip,family==4?32:128);if(strcmp(source,wanted))return 0;
    J *routes=get(facts,"routes"),*rules=get(facts,"rules"),*array=get(status,"route");const char *hop=NULL;
    for(size_t i=0;i<route_count(array) && i<64;i++) {
        J *r=json_object_array_get_idx(array,i);const char *target=str(r,"target");
        if(!*target)break;
        if(!num(r,"mask") && !strcmp(target,family==4?"0.0.0.0":"::")){hop=str(r,"nexthop");break;}
    }
    if(!hop)for(size_t i=0;i<json_object_array_length(routes);i++) {
        J *r=json_object_array_get_idx(routes,i);
        if(num(r,"family")==family && !num(r,"prefix") && num(r,"type")==1 && num(r,"proto")!=186 && !strcmp(str(r,"device"),device)){hop=str(r,"gateway");break;}
    }
    if(!hop)return 0;
    if(!*hop || !strcmp(hop,"0.0.0.0") || !strcmp(hop,"::"))hop="__direct";
    if(strcmp(hop,gateway) || saved_hash!=connected_hash(routes,family,device))return 0;
    int valid_rule=0,valid_default=0;
    for(size_t i=0;i<json_object_array_length(rules);i++) {
        J *r=json_object_array_get_idx(rules,i);
        if(num(r,"family")==family && num(r,"prefix")== (family==4?32:128) && !strcmp(str(r,"source"),ip) && !strcmp(str(r,"device"),device) && num(r,"table")==table && num(r,"priority")==900 && num(r,"proto")==186 && num(r,"type")==1){valid_rule=1;break;}
    }
    for(size_t i=0;i<json_object_array_length(routes);i++) {
        J *r=json_object_array_get_idx(routes,i);const char *g=str(r,"gateway");
        if(num(r,"family")==family && !num(r,"prefix") && num(r,"type")==1 && num(r,"table")==table && num(r,"proto")==186 && !strcmp(str(r,"device"),device) && !strcmp(str(r,"source"),ip) && (!strcmp(gateway,"__direct")?!*g:!strcmp(g,gateway))){valid_default=1;break;}
    }
    return valid_rule && valid_default;
}
static int routes_current(int argc,char **argv) {
    if(argc!=6 || !*argv[1] || strlen(argv[1])>64 || strspn(argv[1],"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")!=strlen(argv[1]))return 2;
    char *lines[2]={NULL,NULL};size_t capacities[2]={0,0};J *status[2]={NULL,NULL},*facts=NULL;int ok=0;
    for(int i=0;i<2;i++){ssize_t n=getline(&lines[i],&capacities[i],stdin);if(n<0 || n>JSON_LIMIT)goto done;status[i]=json_tokener_parse(lines[i]);}
    facts=route_facts();if(!facts || !json_object_is_type(get(facts,"routes"),json_type_array) || !json_object_is_type(get(facts,"rules"),json_type_array))goto done;
    ok=family_route_current(facts,status[0],argv[0],argv[1],4,argv[2],argv[3]) && family_route_current(facts,status[1],argv[0],argv[1],6,argv[4],argv[5]);
    if(ok)printf("%s %s\n",*argv[3]?"managed":"not_configured",*argv[5]?"managed":"not_configured");
done:for(int i=0;i<2;i++){free(lines[i]);json_object_put(status[i]);}json_object_put(facts);return ok?0:75;
}
#endif

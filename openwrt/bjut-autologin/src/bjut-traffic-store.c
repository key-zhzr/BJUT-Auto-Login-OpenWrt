#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>
#include <dirent.h>
#include <inttypes.h>
#include <sys/resource.h>
#include <time.h>
#include "traffic-io.h"

/* Versioned, lossless dictionary TSV inside gzip, shared by checkpoints and
 * streaming readers. Minute collection appends to a small RAM journal. */
#define LINE_SIZE 4096
#define MAX_CHANNELS 65536
typedef struct { char **items; size_t count, capacity; } Dictionary;

static void dictionary_free(Dictionary *dict) {
    for (size_t i=0;i<dict->count;i++) free(dict->items[i]);
    free(dict->items);
}
static int dictionary_add(Dictionary *dict,const char *text) {
    if(dict->count>=MAX_CHANNELS)return -1;
    if(dict->count==dict->capacity){
        size_t capacity=dict->capacity?dict->capacity*2:16;
        char **items=realloc(dict->items,capacity*sizeof(*items));
        if(!items)return -1;
        dict->items=items;dict->capacity=capacity;
    }
    char *item=strdup(text);if(!item)return -1;
    dict->items[dict->count]=item;return (int)dict->count++;
}
static int fields(char *line,char **parts,int maximum) {
    size_t length=strlen(line);
    if(!length||line[length-1]!='\n')return -1;
    line[length-1]='\0';int n=1;parts[0]=line;
    for(char *c=line;*c;c++)if(*c=='\t'){
        if(n>=maximum)return -1;
        *c='\0';parts[n++]=c+1;
    }
    return n;
}
static int gz_line(gzFile file,const char *line) {
    size_t n=strlen(line);return gzwrite(file,line,(unsigned)n)==(int)n;
}
static int pack(const char *kind,const char *input,const char *output) {
    int curves=!strcmp(kind,"curves"),ok=0;FILE *source=fopen(input,"r");
    if(!source)return 1;
    int fd=open(output,O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd<0){fclose(source);return 1;}
    gzFile destination=gzdopen(fd,"wb6");
    if(!destination){close(fd);fclose(source);unlink(output);return 1;}
    Dictionary dict={0};char line[LINE_SIZE],meta[LINE_SIZE],out[LINE_SIZE],*p[12];
    snprintf(out,sizeof(out),"BJUT-TRAFFIC\t1\t%s\n",kind);
    if(!gz_line(destination,out))goto done;
    while(fgets(line,sizeof(line),source)){
        int n=fields(line,p,12),size;
        if(curves){
            if(n!=9&&n!=11)goto done;
            size=snprintf(meta,sizeof(meta),"%s\t%s\t%s\t%s\t%s",p[2],p[3],p[4],p[5],p[6]);
        }else{
            if(n!=6&&n!=7)goto done;
            size=snprintf(meta,sizeof(meta),"%s\t%s\t%s\t%s",p[1],p[2],p[3],n==7?p[6]:"-");
        }
        if(size<0||(size_t)size>=sizeof(meta))goto done;
        int id=-1;
        for(size_t i=0;i<dict.count;i++)if(!strcmp(dict.items[i],meta)){id=(int)i;break;}
        if(id<0){
            id=dictionary_add(&dict,meta);if(id<0)goto done;
            size=snprintf(out,sizeof(out),"D\t%d\t%s\n",id,meta);
            if(size<0||(size_t)size>=sizeof(out)||!gz_line(destination,out))goto done;
        }
        if(curves){
            size=snprintf(out,sizeof(out),"P\t%d\t%s\t%s\t%s\t%s%s%s%s%s\n",id,p[0],p[1],p[7],p[8],n==11?"\t":"",n==11?p[9]:"",n==11?"\t":"",n==11?p[10]:"");
        }else size=snprintf(out,sizeof(out),"P\t%d\t%s\t%s\t%s\n",id,p[0],p[4],p[5]);
        if(size<0||(size_t)size>=sizeof(out)||!gz_line(destination,out))goto done;
    }
    ok=!ferror(source);
done:
    if(fclose(source))ok=0;
    if(gzclose(destination)!=Z_OK)ok=0;
    dictionary_free(&dict);
    if(!ok)unlink(output);
    return ok?0:1;
}
static int unpack(const char *kind,const char *input,const char *output,size_t maximum) {
    TioReader reader;char line[TIO_LINE];size_t written=0;int code=0,ok=1;
    if(!tio_open(&reader,kind,input,"/dev/null"))return 1;
    int fd=open(output,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0){tio_close(&reader);return 1;}
    FILE *destination=fdopen(fd,"w");
    if(!destination){close(fd);tio_close(&reader);unlink(output);return 1;}
    while((code=tio_next(&reader,line,sizeof(line)))>0){
        size_t n=strlen(line);
        if(n>maximum-written||fwrite(line,1,n,destination)!=n){ok=0;break;}
        written+=n;
    }
    if(code<0)ok=0;
    tio_close(&reader);
    if(fclose(destination))ok=0;
    if(!ok)unlink(output);
    return ok?0:1;
}

#include "traffic-compact.h"

int main(int argc,char **argv) {
    if(argc==5&&!strcmp(argv[1],"init"))return store_init(argv[2],argv[3],argv[4]);
    if(argc==3&&!strcmp(argv[1],"path")){
        char directory[PATH_MAX];
        if(!tio_directory(argv[2],directory,sizeof(directory)))return 1;
        puts(directory);return 0;
    }
    if((argc==4||argc==6)&&!strcmp(argv[1],"stream")){
        int64_t first=0,last=0;
        if(argc==6&&(!store_uint(argv[4],&first)||!store_uint(argv[5],&last)))return 2;
        return store_stream(argv[2],argv[3],first,last);
    }
    if(argc==10&&!strcmp(argv[1],"compact"))return store_compact(argc,argv);
    if(argc==4&&!strcmp(argv[1],"commit"))return store_commit(argv[2],argv[3]);
    if(argc<5||(strcmp(argv[2],"curves")&&strcmp(argv[2],"samples")))return 2;
    if(argc==5&&!strcmp(argv[1],"pack"))return pack(argv[2],argv[3],argv[4]);
    if(argc==6&&!strcmp(argv[1],"unpack")){
        char *end=NULL;errno=0;unsigned long maximum=strtoul(argv[5],&end,10);
        if(errno||!end||*end||!maximum||maximum>536870912UL)return 2;
        return unpack(argv[2],argv[3],argv[4],(size_t)maximum);
    }
    return 2;
}

#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

/* Versioned, lossless dictionary TSV inside gzip. Only checkpoints use this
 * format: minute collection and chart reads retain their cheap RAM TSV. */
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
static int number(const char *text,size_t *value) {
    if(!*text)return 0;
    size_t result=0;
    for(const char *p=text;*p;p++){
        if(*p<'0'||*p>'9'||result>MAX_CHANNELS)return 0;
        result=result*10+(size_t)(*p-'0');
    }
    *value=result;return 1;
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
    int curves=!strcmp(kind,"curves"),ok=0;gzFile source=gzopen(input,"rb");
    if(!source)return 1;
    int fd=open(output,O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd<0){gzclose(source);return 1;}
    FILE *destination=fdopen(fd,"w");
    if(!destination){close(fd);gzclose(source);unlink(output);return 1;}
    Dictionary dict={0};char line[LINE_SIZE],meta[LINE_SIZE],out[LINE_SIZE],header[64],*p[12];size_t written=0;
    snprintf(header,sizeof(header),"BJUT-TRAFFIC\t1\t%s\n",kind);
    if(!gzgets(source,line,sizeof(line))||strcmp(line,header))goto done;
    while(gzgets(source,line,sizeof(line))){
        /* Splitting mutates line; metadata definitions must be copied first. */
        char original[LINE_SIZE];memcpy(original,line,strlen(line)+1);
        int n=fields(line,p,12),size;size_t id=0;
        if(n<3||!number(p[1],&id))goto done;
        if(!strcmp(p[0],"D")){
            if(n!=(curves?7:6)||id!=dict.count)goto done;
            char *start=strchr(original,'\t');start=strchr(start+1,'\t')+1;
            start[strlen(start)-1]='\0';
            if(dictionary_add(&dict,start)<0)goto done;
            continue;
        }
        if(strcmp(p[0],"P")||id>=dict.count)goto done;
        if(curves){
            if(n!=6&&n!=8)goto done;
            size=snprintf(out,sizeof(out),"%s\t%s\t%s\t%s\t%s%s%s%s%s\n",p[2],p[3],dict.items[id],p[4],p[5],n==8?"\t":"",n==8?p[6]:"",n==8?"\t":"",n==8?p[7]:"");
        }else{
            if(n!=5)goto done;
            snprintf(meta,sizeof(meta),"%s\n",dict.items[id]);char *m[5];
            if(fields(meta,m,5)!=4)goto done;
            size=snprintf(out,sizeof(out),"%s\t%s\t%s\t%s\t%s\t%s%s%s\n",p[2],m[0],m[1],m[2],p[3],p[4],!strcmp(m[3],"-")?"":"\t",!strcmp(m[3],"-")?"":m[3]);
        }
        if(size<0||(size_t)size>=sizeof(out)||(size_t)size>maximum-written)goto done;
        if(fwrite(out,1,(size_t)size,destination)!=(size_t)size)goto done;
        written+=(size_t)size;
    }
    int error=Z_OK;gzerror(source,&error);ok=gzeof(source)&&(error==Z_OK||error==Z_STREAM_END);
done:
    if(fclose(destination))ok=0;
    if(gzclose(source)!=Z_OK)ok=0;
    dictionary_free(&dict);
    if(!ok)unlink(output);
    return ok?0:1;
}
int main(int argc,char **argv) {
    if(argc<5||(strcmp(argv[2],"curves")&&strcmp(argv[2],"samples")))return 2;
    if(argc==5&&!strcmp(argv[1],"pack"))return pack(argv[2],argv[3],argv[4]);
    if(argc==6&&!strcmp(argv[1],"unpack")){
        char *end=NULL;errno=0;unsigned long maximum=strtoul(argv[5],&end,10);
        if(errno||!end||*end||!maximum||maximum>536870912UL)return 2;
        return unpack(argv[2],argv[3],argv[4],(size_t)maximum);
    }
    return 2;
}

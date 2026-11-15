// SPDX-License-Identifier: MIT
// Exercises production SMC read/write logic with a simulated controller only.
#include <IOKit/IOKitLib.h>
#include <assert.h>
kern_return_t testExchange(mach_port_t,uint32_t,const void*,size_t,void*,size_t*);
#define IOConnectCallStructMethod testExchange
#include "../Source/SMC.c"
#undef IOConnectCallStructMethod
static uint8_t bitmap=0;
static int writes=0,drop_request=0,bad_activation=0;
kern_return_t testExchange(mach_port_t c,uint32_t selector,const void *input,size_t n,void *output,size_t *m) {
    (void)c;assert(selector==2 && n==sizeof(Packet) && *m==sizeof(Packet));
    const Packet *in=input;Packet *out=output;memset(out,0,sizeof(*out));
    if(in->command==9)out->info.size=1;
    else if(in->command==5)out->bytes[0]=bitmap;
    else if(in->command==6) {
        writes++;
        if(in->key==keyCode("CHIE")) {
            // A different adapter request remains present. CHIE controls bit 3 only.
            bitmap=(bitmap&~0x08)|(drop_request?0:(in->bytes[0]&0x08));
        } else bitmap=in->bytes[0]|(bad_activation?0x40:0);
    } else assert(0);
    return KERN_SUCCESS;
}
int main(void) {
    char err[512]={0};bitmap=0x20;
    assert(setValue(1,"CHIE",8,1,err,sizeof(err))==0 && bitmap==0x28 && writes==1);
    assert(setValue(1,"CHIE",8,1,err,sizeof(err))==0 && writes==1);
    assert(setValue(1,"CHIE",0,1,err,sizeof(err))==0 && bitmap==0x20 && writes==2);
    assert(setValue(1,"CHIE",0,1,err,sizeof(err))==0 && writes==2);
    drop_request=1;
    assert(setValue(1,"CHIE",8,1,err,sizeof(err))==-5 && bitmap==0x20);
    drop_request=0;bitmap=0;bad_activation=1;
    assert(setValue(1,"bfF0",2,1,err,sizeof(err))==-5);
    bad_activation=0;bitmap=0;
    assert(setValue(1,"bfF0",2,1,err,sizeof(err))==0 && bitmap==2);
    puts("PASS: 7 adapter controller checks; shared requests preserved, idempotent writes, rejected request detected, firmware verification stays strict; no hardware access");
    return 0;
}

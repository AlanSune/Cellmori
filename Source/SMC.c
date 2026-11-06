// SPDX-License-Identifier: MIT
#include "SMC.h"
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>

static io_connect_t powerRoot = 0;
static IONotificationPortRef powerPort = NULL;
static io_object_t powerNotifier = 0;
static void (*powerCallback)(int) = NULL;
static void powerEvent(void *context, io_service_t service, natural_t type, void *argument) {
    (void)context; (void)service;
    if (type == kIOMessageSystemWillSleep) {
        if (powerCallback) powerCallback(0);
        IOAllowPowerChange(powerRoot, (intptr_t)argument);
    } else if (type == kIOMessageCanSystemSleep) {
        IOAllowPowerChange(powerRoot, (intptr_t)argument);
    } else if (type == kIOMessageSystemHasPoweredOn || type == kIOMessageSystemWillNotSleep) {
        if (powerCallback) powerCallback(1);
    } else if (type == kIOMessageSystemWillPowerOff || type == kIOMessageSystemWillRestart) {
        if (powerCallback) powerCallback(0);
    }
}
int cm_watch_power(void (*callback)(int)) {
    powerCallback = callback;
    powerRoot = IORegisterForSystemPower(NULL, &powerPort, powerEvent, &powerNotifier);
    if (!powerRoot || !powerPort) return -1;
    CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(powerPort), kCFRunLoopDefaultMode);
    return 0;
}

// AppleSMC user-client ABI, selector 2. All writes are restricted below.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } Info;
typedef struct {
    uint32_t key; Version version; Limits limits; Info info;
    uint8_t result, status, command; uint32_t index; uint8_t bytes[32];
} Packet;
_Static_assert(sizeof(Packet) == 80, "Unexpected SMC ABI layout");

static int connectSMC(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return (int)result;
}
static uint32_t keyCode(const char *key) {
    return ((uint32_t)key[0]<<24)|((uint32_t)key[1]<<16)|((uint32_t)key[2]<<8)|(uint32_t)key[3];
}
static int exchange(io_connect_t c, Packet *in, Packet *out) {
    size_t count = sizeof(*out);
    memset(out, 0, count);
    kern_return_t result = IOConnectCallStructMethod(c, 2, in, sizeof(*in), out, &count);
    if (result != KERN_SUCCESS) return (int)result;
    if (count != sizeof(*out)) return -2;
    return out->result == 0 ? 0 : 1000 + out->result;
}
static int readKey(io_connect_t c, const char *key, Packet *value) {
    Packet in = {0}, out = {0};
    in.key = keyCode(key); in.command = 9;
    int result = exchange(c, &in, &out);
    if (result) return result;
    if (out.info.size == 0 || out.info.size > 32) return -3;
    in.info = out.info; in.command = 5;
    result = exchange(c, &in, value);
    value->info = in.info;
    return result;
}
static int setValue(io_connect_t c, const char *key, uint8_t byte, uint32_t size, char *error, int cap) {
    Packet current = {0};
    int result = readKey(c, key, &current);
    if (result || current.info.size != size) {
        snprintf(error, cap, "%s read/size failed (%d)", key, result); return -4;
    }
    uint8_t desired[32]={0}; desired[0]=byte;
    if (memcmp(current.bytes,desired,size)==0) return 0;
    Packet in = {0}, out = {0};
    in.key = keyCode(key); in.info = current.info; in.command = 6; in.bytes[0] = byte;
    result = exchange(c, &in, &out);
    if (!result) result = readKey(c, key, &current);
    if (!result && memcmp(current.bytes,desired,size)!=0) result = -5;
    if (result) snprintf(error, cap, "%s write/verification failed (%d)", key, result);
    return result;
}
typedef struct { const char *charge; const char *secondCharge; uint32_t chargeSize;
                 const char *adapter; uint8_t dischargeValue; } Backend;
static int hasKey(io_connect_t c, const char *key, uint32_t size) {
    Packet p={0}; return readKey(c,key,&p)==0 && p.info.size==size;
}
static Backend detect(io_connect_t c) {
    Backend b={0};
    if(hasKey(c,"CHTE",4)) { b.charge="CHTE"; b.chargeSize=4; }
    else if(hasKey(c,"CH0B",1) && hasKey(c,"CH0C",1)) {
        b.charge="CH0B"; b.secondCharge="CH0C"; b.chargeSize=1;
    }
    if(hasKey(c,"CHIE",1)) {b.adapter="CHIE";b.dischargeValue=8;}
    else if(hasKey(c,"CH0J",1)) {b.adapter="CH0J";b.dischargeValue=1;}
    else if(hasKey(c,"CH0I",1)) {b.adapter="CH0I";b.dischargeValue=1;}
    return b;
}
int cm_capabilities(void) {
    io_connect_t c=0; if(connectSMC(&c)) return 0;
    Backend b=detect(c);
    int firmware=hasKey(c,"bfF0",1) && hasKey(c,"bfD0",4) && hasKey(c,"bfE0",4);
    int physical=hasKey(c,"AC-W",1);
    IOServiceClose(c);
    return (b.charge?1:0)|(b.adapter?2:0)|(firmware?4:0)|(physical?8:0);
}
int cm_physical_power(void) {
    io_connect_t c=0;if(connectSMC(&c)) return -1;
    Packet p={0};int r=readKey(c,"AC-W",&p);IOServiceClose(c);
    return r || p.info.size!=1 ? -1 : (p.bytes[0]>0 ? 1:0);
}
int cm_test_firmware_access(char *output, int capacity) {
    io_connect_t c=0; int r=connectSMC(&c);
    if(r) {snprintf(output,capacity,"AppleSMC open failed (%d)",r);return r;}
    Packet activation={0}, upper={0}, lower={0};
    r=readKey(c,"bfF0",&activation);
    if(!r) r=readKey(c,"bfD0",&upper);
    if(!r) r=readKey(c,"bfE0",&lower);
    if(r || activation.info.size!=1 || upper.info.size!=4 || lower.info.size!=4) {
        IOServiceClose(c);snprintf(output,capacity,"Firmware limit keys unavailable (%d)",r);return -6;
    }
    // This intentionally bypasses the normal no-op optimization to test entitlement enforcement.
    Packet in={0}, out={0}; in.key=keyCode("bfF0");in.info=activation.info;in.command=6;
    memcpy(in.bytes,activation.bytes,activation.info.size);
    r=exchange(c,&in,&out);
    Packet after={0};
    if(!r) r=readKey(c,"bfF0",&after);
    if(!r && memcmp(after.bytes,activation.bytes,activation.info.size)) r=-5;
    snprintf(output,capacity,"bfF0 unchanged-value write: %s (code=%d); original activation=%u, upper=%u, lower=%u",
        r?"DENIED/FAILED":"verified",r,activation.bytes[0],upper.bytes[0],lower.bytes[0]);
    IOServiceClose(c);return r;
}
int cm_firmware_read(int *activation, int *upper, int *lower, char *error, int capacity) {
    io_connect_t c=0; int r=connectSMC(&c);
    if(r) {snprintf(error,capacity,"AppleSMC open failed (%d)",r);return r;}
    Packet a={0},u={0},l={0};
    r=readKey(c,"bfF0",&a);if(!r) r=readKey(c,"bfD0",&u);if(!r) r=readKey(c,"bfE0",&l);
    if(!r && (a.info.size!=1 || u.info.size!=4 || l.info.size!=4)) r=-3;
    if(!r) {
        uint32_t uv=u.bytes[0]|(uint32_t)u.bytes[1]<<8|(uint32_t)u.bytes[2]<<16|(uint32_t)u.bytes[3]<<24;
        uint32_t lv=l.bytes[0]|(uint32_t)l.bytes[1]<<8|(uint32_t)l.bytes[2]<<16|(uint32_t)l.bytes[3]<<24;
        // An interrupted update can leave an inactive intermediate range with lower >= upper.
        // Keep it readable so the persisted original snapshot can still be restored.
        if((a.bytes[0]!=0 && a.bytes[0]!=2) || uv>100 || lv>100 || (a.bytes[0]==2 && lv>=uv)) r=-3;
        else {*activation=a.bytes[0];*upper=(int)uv;*lower=(int)lv;}
    }
    IOServiceClose(c);if(r) snprintf(error,capacity,"Firmware snapshot failed (%d)",r);return r;
}
int cm_firmware_set(int activation, int upper, int lower, char *error, int capacity) {
    if((activation!=0 && activation!=2) || upper<0 || upper>100 || lower<0 || lower>100 || (activation==2 && lower>=upper)) {
        snprintf(error,capacity,"Invalid firmware target");return -3;
    }
    int oa=0,ou=0,ol=0;
    int r=cm_firmware_read(&oa,&ou,&ol,error,capacity);if(r) return r;
    if(oa==activation && ou==upper && ol==lower) return 0;
    io_connect_t c=0;r=connectSMC(&c);
    if(r) {snprintf(error,capacity,"AppleSMC open failed (%d)",r);return r;}
    // Disable before changing the little-endian percentage fields, then activate last.
    r=setValue(c,"bfF0",0,1,error,capacity);
    if(!r) r=setValue(c,"bfD0",(uint8_t)upper,4,error,capacity);
    if(!r) r=setValue(c,"bfE0",(uint8_t)lower,4,error,capacity);
    if(!r) r=setValue(c,"bfF0",(uint8_t)activation,1,error,capacity);
    IOServiceClose(c);
    int a=0,u=0,l=0;
    if(!r) r=cm_firmware_read(&a,&u,&l,error,capacity);
    if(!r && (a!=activation || u!=upper || l!=lower)) {r=-5;snprintf(error,capacity,"Firmware readback mismatch");}
    // The privileged caller persists the original snapshot before invoking this function,
    // and performs/retries rollback on any partial failure.
    return r;
}
int cm_adapter(int discharging, char *error, int capacity) {
    io_connect_t c=0;int r=connectSMC(&c);
    if(r) {snprintf(error,capacity,"AppleSMC open failed (%d)",r);return r;}
    Backend b=detect(c);
    if(!b.adapter) {IOServiceClose(c);snprintf(error,capacity,"No adapter control");return -6;}
    r=setValue(c,b.adapter,discharging?b.dischargeValue:0,1,error,capacity);
    IOServiceClose(c);return r;
}
int cm_probe(char *output, int capacity) {
    io_connect_t c = 0;
    int result = connectSMC(&c);
    if (result) { snprintf(output, capacity, "AppleSMC open failed (%d)", result); return result; }
    const char *keys[] = {"#KEY", "CH0B", "CH0C", "CHTE", "CH0I", "CH0J", "CHIE", "CHWA", "bfF0", "bfD0", "bfE0", "AC-W"};
    int used = 0;
    for (int i=0; i<12; i++) {
        Packet value = {0}; int r = readKey(c, keys[i], &value);
        if (used < capacity) used += snprintf(output+used, capacity-used, "%s: %s (code=%d, size=%u, value=%u)\n",
            keys[i], r ? "unavailable" : "readable", r, value.info.size, value.bytes[0]);
    }
    Backend b=detect(c);
    int firmware=hasKey(c,"bfF0",1) && hasKey(c,"bfD0",4) && hasKey(c,"bfE0",4);
    if(used<capacity) snprintf(output+used,capacity-used,"Charge: %s; adapter: %s\n",firmware?"firmware limits":(b.charge?b.charge:"unavailable"),b.adapter?b.adapter:"unavailable");
    IOServiceClose(c);
    return (b.charge || firmware) ? 0 : -6;
}
int cm_restore(char *error, int capacity) {
    io_connect_t c=0; int r=connectSMC(&c); if(r) {snprintf(error,capacity,"AppleSMC open failed (%d)",r);return r;}
    Backend b=detect(c);
    if(!b.charge && !b.adapter) { IOServiceClose(c);snprintf(error,capacity,"No supported control keys; cannot verify restore");return -6; }
    // Restore adapter first and try every available gate even if another fails.
    int failed=0;
    if(b.adapter && setValue(c,b.adapter,0,1,error,capacity)) failed=1;
    if(b.charge && setValue(c,b.charge,0,b.chargeSize,error,capacity)) failed=1;
    if(b.secondCharge && setValue(c,b.secondCharge,0,1,error,capacity)) failed=1;
    IOServiceClose(c); return failed ? -7 : 0;
}
int cm_control(int charging, int discharging, char *error, int capacity) {
    io_connect_t c=0; int r=connectSMC(&c);
    if(r) {snprintf(error,capacity,"AppleSMC open failed (%d)",r);return r;}
    Backend b=detect(c);
    if(!b.charge || (discharging && !b.adapter)) {
        IOServiceClose(c);snprintf(error,capacity,"Required control capability unavailable");return -6;
    }
    // Leave an already-correct discharge state alone to avoid repeated adapter negotiation.
    Packet charge={0}, second={0}, adapter={0};
    uint8_t expected=b.chargeSize==4?(charging?0:1):(charging?0:2);
    uint8_t wanted[4]={expected,0,0,0};
    int same=readKey(c,b.charge,&charge)==0 && memcmp(charge.bytes,wanted,b.chargeSize)==0;
    if(b.secondCharge) same= same && readKey(c,b.secondCharge,&second)==0 && second.bytes[0]==expected;
    if(b.adapter) same= same && readKey(c,b.adapter,&adapter)==0 && adapter.bytes[0]==(discharging?b.dischargeValue:0);
    if(same) {IOServiceClose(c);return 0;}
    if(b.adapter) r=setValue(c,b.adapter,0,1,error,capacity);
    if(!r) r=setValue(c,b.charge,expected,b.chargeSize,error,capacity);
    if(!r && b.secondCharge) r=setValue(c,b.secondCharge,expected,1,error,capacity);
    if(!r && discharging) r=setValue(c,b.adapter,b.dischargeValue,1,error,capacity);
    IOServiceClose(c);
    if(r) {char ignored[256]={0}; cm_restore(ignored,sizeof(ignored));}
    return r;
}

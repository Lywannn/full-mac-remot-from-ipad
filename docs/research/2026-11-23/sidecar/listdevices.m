// Read-only: calls ONLY getters on SidecarDisplayManager (isSupported, sharedManager,
// devices, connectedDevices, recentDevices). Never calls connect/disconnect/goHome/
// preferencesChanged. Prints no device names or identifiers.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>

static id call0(id target, const char *sel) {
    SEL s = sel_registerName(sel);
    if (![target respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, s);
}

static void describeDevice(id d, int idx) {
    long rapport = [d respondsToSelector:@selector(rapportVersion)] ? ((long (*)(id, SEL))objc_msgSend)(d, sel_registerName("rapportVersion")) : -1;
    unsigned long status = ((unsigned long (*)(id, SEL))objc_msgSend)(d, sel_registerName("status"));
    BOOL addl = ((BOOL (*)(id, SEL))objc_msgSend)(d, sel_registerName("offersAdditionalDisplay"));
    BOOL reality = ((BOOL (*)(id, SEL))objc_msgSend)(d, sel_registerName("isRealityDevice"));
    NSString *model = call0(d, "model");
    NSString *version = call0(d, "version");
    NSString *typeId = call0(d, "deviceTypeIdentifier");
    printf("  device[%d]: model=%s typeId=%s version=%s rapportVersion=%ld status=%lu offersAdditionalDisplay=%d isRealityDevice=%d\n",
           idx, model.UTF8String ?: "-", typeId.UTF8String ?: "-", version.UTF8String ?: "-", rapport, status, addl, reality);
}

int main(void) {
    @autoreleasepool {
        alarm(25); // hard watchdog
        if (!dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY)) {
            printf("dlopen failed: %s\n", dlerror());
            return 1;
        }
        Class M = NSClassFromString(@"SidecarDisplayManager");
        BOOL supported = ((BOOL (*)(id, SEL))objc_msgSend)(M, sel_registerName("isSupported"));
        printf("+isSupported = %d\n", supported);
        id m = call0(M, "sharedManager");
        printf("sharedManager = %s\n", m ? class_getName(object_getClass(m)) : "nil");
        if (!m) return 2;
        NSDate *t0 = [NSDate date];
        NSArray *devs = call0(m, "devices");
        printf("devices: %lu (%.2fs)\n", (unsigned long)devs.count, -[t0 timeIntervalSinceNow]);
        int i = 0;
        for (id d in devs) describeDevice(d, i++);
        NSArray *conn = call0(m, "connectedDevices");
        printf("connectedDevices: %lu\n", (unsigned long)conn.count);
        NSArray *rec = call0(m, "recentDevices");
        printf("recentDevices: %lu\n", (unsigned long)rec.count);
        i = 0;
        for (id d in rec) describeDevice(d, i++);
    }
    return 0;
}

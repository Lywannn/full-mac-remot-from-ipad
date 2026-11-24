#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import "IPMPrivateDisplay.h"

// Local protocols mirroring docs/research/2026-11-23/display/CGVirtualDisplayPrivate.h.
// The real classes are only ever reached through NSClassFromString.
@protocol IPMVDDescriptor <NSObject>
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNumber;
@end

@protocol IPMVDMode <NSObject>
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@protocol IPMVDSettings <NSObject>
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic) uint32_t hiDPI;
@end

@protocol IPMVD <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

typedef CGError (*IPMConfigureEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
typedef CGError (*IPMGetDisplayListFn)(uint32_t, CGDirectDisplayID *, uint32_t *);
typedef CFDictionaryRef (*IPMInfoFn)(CGDirectDisplayID);

static IPMConfigureEnabledFn ipmConfigureFn(void) {
    static IPMConfigureEnabledFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (IPMConfigureEnabledFn)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled"); });
    return fn;
}
static IPMGetDisplayListFn ipmListFn(void) {
    static IPMGetDisplayListFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (IPMGetDisplayListFn)dlsym(RTLD_DEFAULT, "CGSGetDisplayList"); });
    return fn;
}
static IPMInfoFn ipmInfoFn(void) {
    static IPMInfoFn fn; static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        if (h) fn = (IPMInfoFn)dlsym(h, "CoreDisplay_DisplayCreateInfoDictionary");
    });
    return fn;
}

static BOOL ipmAll(Class c, NSArray<NSString *> *sels) {
    for (NSString *n in sels) if (![c instancesRespondToSelector:NSSelectorFromString(n)]) return NO;
    return YES;
}

// Every selector IPMVirtualDisplayCreate sends, checked on the class it is sent to.
static BOOL ipmVirtualDisplayClassesPresent(void) {
    Class d = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class m = NSClassFromString(@"CGVirtualDisplayMode");
    Class s = NSClassFromString(@"CGVirtualDisplaySettings");
    Class v = NSClassFromString(@"CGVirtualDisplay");
    return d && m && s && v
        && ipmAll(d, @[@"setQueue:", @"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
                       @"setSizeInMillimeters:", @"setVendorID:", @"setProductID:", @"setSerialNumber:"])
        && ipmAll(m, @[@"initWithWidth:height:refreshRate:"])
        && ipmAll(s, @[@"setHiDPI:", @"setModes:"])
        && ipmAll(v, @[@"initWithDescriptor:", @"applySettings:", @"displayID"]);
}

IPMPrivateAPIStatus IPMGetPrivateAPIStatus(void) {
    IPMPrivateAPIStatus s;
    s.virtualDisplay = ipmVirtualDisplayClassesPresent();
    s.configureEnabled = ipmConfigureFn() != NULL;
    s.displayList = ipmListFn() != NULL;
    s.displayInfo = ipmInfoFn() != NULL;
    return s;
}

void *IPMVirtualDisplayCreate(const char *name, uint32_t vendorID, uint32_t productID, uint32_t serial,
    double widthMM, double heightMM, uint32_t maxPixelsWide, uint32_t maxPixelsHigh, bool hiDPI,
    const IPMModeSpec *modes, int modeCount, CGDirectDisplayID *outDisplayID) {
    @autoreleasepool { @try {
        if (!ipmVirtualDisplayClassesPresent() || !name || !modes || modeCount <= 0) return NULL;
        id<IPMVDDescriptor> desc = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        if (!desc) return NULL;
        desc.name = [NSString stringWithUTF8String:name];
        desc.maxPixelsWide = maxPixelsWide;
        desc.maxPixelsHigh = maxPixelsHigh;
        desc.sizeInMillimeters = CGSizeMake(widthMM, heightMM);
        desc.vendorID = vendorID;
        desc.productID = productID;
        desc.serialNumber = serial;
        desc.queue = dispatch_get_main_queue();

        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        NSMutableArray *modeObjs = [NSMutableArray arrayWithCapacity:(NSUInteger)modeCount];
        for (int i = 0; i < modeCount; i++) {
            id<IPMVDMode> m = [[modeClass alloc] initWithWidth:modes[i].widthPoints
                                                        height:modes[i].heightPoints
                                                   refreshRate:modes[i].refreshHz];
            if (!m) return NULL;
            [modeObjs addObject:m];
        }
        id<IPMVDSettings> settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        if (!settings) return NULL;
        settings.hiDPI = hiDPI ? 1 : 0;
        settings.modes = modeObjs;

        id<IPMVD> vd = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
        if (!vd) return NULL;
        if (![vd applySettings:settings]) return NULL;
        if (outDisplayID) *outDisplayID = vd.displayID;
        return (void *)CFBridgingRetain(vd);
    } @catch (NSException *e) { return NULL; } }
}

void IPMVirtualDisplayRelease(void *handle) {
    if (handle) CFRelease(handle);
}

CGError IPMConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled) {
    IPMConfigureEnabledFn fn = ipmConfigureFn();
    return fn ? fn(config, display, enabled) : kCGErrorNotImplemented;
}

uint32_t IPMCopyAllDisplayIDs(CGDirectDisplayID *out, uint32_t max) {
    IPMGetDisplayListFn fn = ipmListFn();
    if (!fn || !out || max == 0) return 0;
    CGDirectDisplayID tmp[32]; uint32_t n = 0;
    if (fn(32, tmp, &n) != kCGErrorSuccess) return 0;
    uint32_t written = 0;
    for (uint32_t i = 0; i < n && written < max; i++) {
        if (CGDisplayVendorNumber(tmp[i]) == 0) continue;
        out[written++] = tmp[i];
    }
    return written;
}

CFDictionaryRef IPMCopyDisplayInfo(CGDirectDisplayID display) {
    IPMInfoFn fn = ipmInfoFn();
    return fn ? fn(display) : NULL;
}

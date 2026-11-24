// Read-only: lists displays and checks for private symbols via dlsym (never calls
// configuration functions). Only getters are invoked.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>

typedef CFDictionaryRef (*InfoDictFn)(CGDirectDisplayID);

int main(void) {
    @autoreleasepool {
        void *cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        const char *syms[] = {"CoreDisplay_DisplayCreateInfoDictionary", "CGSConfigureDisplayEnabled",
            "SLSConfigureDisplayEnabled", "CGSGetDisplayList", "SLSGetDisplayList", "CGSIsDisplayEnabled",
            "SLSIsDisplayEnabled", "CGDisplayIsAsleep", "CGConfigureDisplayMirrorOfDisplay", NULL};
        for (int i = 0; syms[i]; i++) {
            void *p = dlsym(RTLD_DEFAULT, syms[i]);
            printf("dlsym %-42s %s\n", syms[i], p ? "present" : "absent");
        }
        (void)cd; (void)sl;
        Class vd = objc_getClass("CGVirtualDisplay");
        printf("CGVirtualDisplay class: %s; image: %s\n", vd ? "present" : "absent", vd ? class_getImageName(vd) : "-");
        if (vd) {
            unsigned int n = 0;
            Method *m = class_copyMethodList(vd, &n);
            printf("  CGVirtualDisplay methods:");
            for (unsigned int i = 0; i < n; i++) printf(" %s", sel_getName(method_getName(m[i])));
            printf("\n");
            free(m);
        }
        Class vdd = objc_getClass("CGVirtualDisplayDescriptor");
        if (vdd) {
            unsigned int n = 0;
            objc_property_t *p = class_copyPropertyList(vdd, &n);
            printf("  CGVirtualDisplayDescriptor props:");
            for (unsigned int i = 0; i < n; i++) printf(" %s", property_getName(p[i]));
            printf("\n");
            free(p);
        }
        InfoDictFn info = (InfoDictFn)dlsym(RTLD_DEFAULT, "CoreDisplay_DisplayCreateInfoDictionary");

        uint32_t count = 0;
        CGDirectDisplayID ids[16];
        CGGetOnlineDisplayList(16, ids, &count);
        uint32_t activeCount = 0;
        CGDirectDisplayID act[16];
        CGGetActiveDisplayList(16, act, &activeCount);
        printf("\nonline displays: %u, active displays: %u, main: %u\n", count, activeCount, CGMainDisplayID());
        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID d = ids[i];
            CGRect b = CGDisplayBounds(d);
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(d);
            printf("\n display %u: vendor=0x%x model=0x%x serial=%s builtin=%d main=%d active=%d asleep=%d online=%d inMirrorSet=%d mirrorsDisplay=%u bounds=%.0fx%.0f@(%.0f,%.0f) mode=%zux%zu px=%zux%zu modes=",
                   d, CGDisplayVendorNumber(d), CGDisplayModelNumber(d), CGDisplaySerialNumber(d) ? "nonzero" : "0",
                   CGDisplayIsBuiltin(d), CGDisplayIsMain(d), CGDisplayIsActive(d), CGDisplayIsAsleep(d), CGDisplayIsOnline(d),
                   CGDisplayIsInMirrorSet(d), CGDisplayMirrorsDisplay(d), b.size.width, b.size.height, b.origin.x, b.origin.y,
                   mode ? CGDisplayModeGetWidth(mode) : 0, mode ? CGDisplayModeGetHeight(mode) : 0,
                   mode ? CGDisplayModeGetPixelWidth(mode) : 0, mode ? CGDisplayModeGetPixelHeight(mode) : 0);
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, NULL);
            printf("%ld\n", modes ? (long)CFArrayGetCount(modes) : -1L);
            if (modes) CFRelease(modes);
            if (mode) CGDisplayModeRelease(mode);
            if (info) {
                NSDictionary *dict = CFBridgingRelease(info(d));
                NSMutableArray *keys = [NSMutableArray array];
                for (NSString *k in [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                    id v = dict[k];
                    BOOL sensitive = [k rangeOfString:@"Serial" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                     [k rangeOfString:@"EDID" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                     [k rangeOfString:@"UUID" options:NSCaseInsensitiveSearch].location != NSNotFound;
                    BOOL simple = [v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]];
                    [keys addObject:[NSString stringWithFormat:@"%@=%@", k, sensitive ? @"<redacted>" : (simple ? v : NSStringFromClass([v class]))]];
                }
                printf("   infoDict: %s\n", [[keys componentsJoinedByString:@"; "] UTF8String]);
            }
        }
        printf("\nNSScreens:\n");
        for (NSScreen *s in [NSScreen screens]) {
            NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
            printf("  id=%u name=%s backingScale=%.1f\n", num.unsignedIntValue, s.localizedName.UTF8String, s.backingScaleFactor);
        }
    }
    return 0;
}

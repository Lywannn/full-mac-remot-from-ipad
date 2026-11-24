// Runtime-resolved shim over private CoreGraphics / SkyLight / CoreDisplay APIs.
// Nothing here links against a private symbol: functions come from dlsym, classes from
// NSClassFromString. If Apple removes an API, the call fails soft instead of the binary not launching.
#ifndef IPM_PRIVATE_DISPLAY_H
#define IPM_PRIVATE_DISPLAY_H

#include <stdbool.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

CF_ASSUME_NONNULL_BEGIN

typedef struct { bool virtualDisplay; bool configureEnabled; bool displayList; bool displayInfo; } IPMPrivateAPIStatus;
IPMPrivateAPIStatus IPMGetPrivateAPIStatus(void);

typedef struct { uint32_t widthPoints; uint32_t heightPoints; double refreshHz; } IPMModeSpec;

// Handle is retained (release with IPMVirtualDisplayRelease), or NULL on failure.
void *_Nullable IPMVirtualDisplayCreate(const char *name, uint32_t vendorID, uint32_t productID, uint32_t serial,
    double widthMM, double heightMM, uint32_t maxPixelsWide, uint32_t maxPixelsHigh, bool hiDPI,
    const IPMModeSpec *modes, int modeCount, CGDirectDisplayID *outDisplayID);
void IPMVirtualDisplayRelease(void *_Nullable handle);

// kCGErrorNotImplemented when the symbol is missing.
CGError IPMConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);
// CGSGetDisplayList, without vendor 0 entries.
uint32_t IPMCopyAllDisplayIDs(CGDirectDisplayID *out, uint32_t max);
// CoreDisplay_DisplayCreateInfoDictionary (caller releases), NULL if unavailable.
CFDictionaryRef _Nullable IPMCopyDisplayInfo(CGDirectDisplayID display);

CF_ASSUME_NONNULL_END
#endif

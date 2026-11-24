// CGVirtualDisplayPrivate.h - minimal private display API surface for Swift (bridging header).
// Types checked against ObjC runtime type encodings on macOS 27.0.1 (26A434), arm64.
// PRIVATE API: undocumented, may change in any macOS update. Check selectors at runtime before use.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;          // alias: -setDispatchQueue:
@property (nonatomic, strong) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;                   // must cover the largest mode's PIXEL size
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;                 // use the real panel size
@property (nonatomic) uint32_t vendorID;                        // non-zero (Chromium: macOS 14+ expects it)
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNumber;                    // legacy alias still present: serialNum
// Block parameters follow older class-dumps; runtime encoding is only "@?". Keep the block trivial.
@property (nonatomic, copy, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
@end

@interface CGVirtualDisplayMode : NSObject
// Encoding @32@0:8I16I20d24 -> 32-bit width/height (older headers wrongly use NSUInteger).
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;  // with hiDPI=1: sizes in POINTS
@property (nonatomic) uint32_t hiDPI;
@property (nonatomic) uint32_t rotation;
@end

@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) uint32_t hiDPI;
@property (nonatomic, readonly) NSArray *modes;
@end

// Exported by CoreGraphics (alias of SkyLight's SLSConfigureDisplayEnabled, same address on 27.0.1).
// Call between CGBeginDisplayConfiguration and CGCompleteDisplayConfiguration.
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);
// Exported by CoreGraphics; unlike CGGetOnlineDisplayList it also returns software-disabled
// and unused framebuffers (filter vendor == 0).
extern CGError CGSGetDisplayList(uint32_t maxDisplays, CGDirectDisplayID * _Nullable displays, uint32_t * _Nullable count);
// CoreDisplay.framework: per-display info (kCGDisplayIsVirtualDevice, kCGDisplayIsAirPlay, IODisplayLocation, ...).
extern CFDictionaryRef _Nullable CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END

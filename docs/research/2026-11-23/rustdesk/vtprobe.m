#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
static void probe(CMVideoCodecType t, const char *name) {
  CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
  CFDictionarySetValue(spec, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
  CFDictionaryRef props = NULL; CFStringRef outID = NULL;
  OSStatus a = VTCopySupportedPropertyDictionaryForEncoder(1280, 720, t, spec, &outID, &props);
  printf("%s pathA(require HW) status=%d encoderID=%s\n", name, (int)a, outID ? [(__bridge NSString*)outID UTF8String] : "-");
  if (props) CFRelease(props); if (outID) CFRelease(outID);
  CFMutableDictionaryRef en = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(en, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
  VTCompressionSessionRef s = NULL;
  OSStatus b = VTCompressionSessionCreate(NULL, 1280, 720, t, en, NULL, NULL, NULL, NULL, &s);
  int hw = -1;
  if (b == noErr && s) {
    OSStatus p = VTCompressionSessionPrepareToEncodeFrames(s);
    CFBooleanRef u = NULL;
    OSStatus q = VTSessionCopyProperty(s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, (void**)&u);
    hw = (q == noErr && u && CFBooleanGetValue(u)) ? 1 : 0;
    printf("%s pathB create=%d prepare=%d copyprop=%d usingHW=%d\n", name, (int)b, (int)p, (int)q, hw);
    if (u) CFRelease(u);
    VTCompressionSessionInvalidate(s); CFRelease(s);
  } else printf("%s pathB create failed=%d\n", name, (int)b);
  CFRelease(spec); CFRelease(en);
}
int main(void) { @autoreleasepool { probe(kCMVideoCodecType_HEVC, "HEVC"); probe(kCMVideoCodecType_H264, "H264"); } return 0; }

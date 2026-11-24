// Read-only ObjC runtime introspection of Sidecar private frameworks.
// Does NOT instantiate or message any Sidecar class; only reads runtime metadata
// and scans the loaded image's __TEXT,__cstring section.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <string.h>

static void dumpClass(Class cls) {
    Class sup = class_getSuperclass(cls);
    printf("\n@interface %s : %s", class_getName(cls), sup ? class_getName(sup) : "nil");
    unsigned int pc = 0;
    Protocol * __unsafe_unretained *protos = class_copyProtocolList(cls, &pc);
    if (pc) {
        printf(" <");
        for (unsigned int i = 0; i < pc; i++) printf("%s%s", i ? ", " : "", protocol_getName(protos[i]));
        printf(">");
    }
    free(protos);
    printf("\n");
    unsigned int n = 0;
    objc_property_t *props = class_copyPropertyList(cls, &n);
    for (unsigned int i = 0; i < n; i++)
        printf("  @property %s  [%s]\n", property_getName(props[i]), property_getAttributes(props[i]));
    free(props);
    Method *cm = class_copyMethodList(object_getClass(cls), &n);
    for (unsigned int i = 0; i < n; i++)
        printf("  + %s  %s\n", sel_getName(method_getName(cm[i])), method_getTypeEncoding(cm[i]) ?: "");
    free(cm);
    Method *im = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++)
        printf("  - %s  %s\n", sel_getName(method_getName(im[i])), method_getTypeEncoding(im[i]) ?: "");
    free(im);
    Ivar *iv = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++)
        printf("  ivar %s %s\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]) ?: "");
    free(iv);
}

static void dumpProtocol(Protocol *p) {
    printf("\n@protocol %s\n", protocol_getName(p));
    BOOL reqs[2] = {YES, NO};
    BOOL insts[2] = {YES, NO};
    for (int r = 0; r < 2; r++) for (int k = 0; k < 2; k++) {
        unsigned int n = 0;
        struct objc_method_description *md = protocol_copyMethodDescriptionList(p, reqs[r], insts[k], &n);
        for (unsigned int i = 0; i < n; i++)
            printf("  %s%s %s  %s\n", reqs[r] ? "" : "@optional ", insts[k] ? "-" : "+", sel_getName(md[i].name), md[i].types ?: "");
        free(md);
    }
    unsigned int n = 0;
    objc_property_t *props = protocol_copyPropertyList(p, &n);
    for (unsigned int i = 0; i < n; i++)
        printf("  @property %s  [%s]\n", property_getName(props[i]), property_getAttributes(props[i]));
    free(props);
}

static void scanCStrings(const char *imageSubstr) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, imageSubstr)) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        const char *sects[] = {"__cstring", "__oslogstring", NULL};
        for (int s = 0; sects[s]; s++) {
            unsigned long size = 0;
            uint8_t *data = getsectiondata(mh, "__TEXT", sects[s], &size);
            if (!data) continue;
            printf("\n### STRINGS %s %s (%lu bytes)\n", name, sects[s], size);
            unsigned long start = 0;
            for (unsigned long j = 0; j < size; j++) {
                if (data[j] == 0) {
                    if (j > start) printf("%.*s\n", (int)(j - start), (const char *)data + start);
                    start = j + 1;
                }
            }
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *paths[] = {
            "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore",
            "/System/Library/PrivateFrameworks/SidecarUI.framework/SidecarUI",
            NULL};
        BOOL wantStrings = argc > 1 && strcmp(argv[1], "strings") == 0;
        for (int i = 0; paths[i]; i++) {
            void *h = dlopen(paths[i], RTLD_LAZY);
            fprintf(stderr, "dlopen %s -> %s\n", paths[i], h ? "OK" : dlerror());
        }
        if (wantStrings) {
            scanCStrings(argc > 2 ? argv[2] : "SidecarCore");
            return 0;
        }
        unsigned int imgCount = 0;
        const char **imgs = objc_copyImageNames(&imgCount);
        for (unsigned int i = 0; i < imgCount; i++) {
            if (!strstr(imgs[i], "Sidecar")) continue;
            unsigned int cc = 0;
            const char **names = objc_copyClassNamesForImage(imgs[i], &cc);
            printf("\n######## IMAGE %s : %u classes\n", imgs[i], cc);
            for (unsigned int c = 0; c < cc; c++) {
                Class cls = objc_getClass(names[c]);
                if (cls) dumpClass(cls);
            }
            free(names);
        }
        free(imgs);
        unsigned int pn = 0;
        Protocol * __unsafe_unretained *plist = objc_copyProtocolList(&pn);
        printf("\n######## PROTOCOLS containing 'Sidecar'\n");
        for (unsigned int i = 0; i < pn; i++) {
            const char *pname = protocol_getName(plist[i]);
            if (strcasestr(pname, "sidecar")) dumpProtocol(plist[i]);
        }
        free(plist);
    }
    return 0;
}

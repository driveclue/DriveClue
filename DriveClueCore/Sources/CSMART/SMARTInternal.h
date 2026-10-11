#ifndef SMART_INTERNAL_H
#define SMART_INTERNAL_H

// Helpers shared by the SMARTEnumerate / SMARTATA / SMARTNVMe implementation files.
// Everything here is static inline so each translation unit gets its own copy.

#import "SMARTBridge.h"
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOKitKeys.h>
#import <IOKit/storage/IOStorageDeviceCharacteristics.h>
#import <IOKit/storage/ata/ATASMARTLib.h>
#import <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#import <string.h>
#import <stdio.h>

static inline void zero_mem(void *ptr, size_t n) {
    memset(ptr, 0, n);
}

static inline void copy_cstr(char *dst, size_t dstLen, CFStringRef string) {
    if (dstLen == 0) {
        return;
    }
    dst[0] = 0;
    if (string == NULL) {
        return;
    }
    CFStringGetCString(string, dst, (CFIndex)dstLen, kCFStringEncodingUTF8);
}

static inline void trim_trailing(char *text) {
    size_t n = strlen(text);
    while (n > 0 && text[n - 1] == ' ') {
        text[n - 1] = 0;
        n--;
    }
    size_t start = 0;
    while (text[start] == ' ') {
        start++;
    }
    if (start > 0) {
        memmove(text, text + start, strlen(text + start) + 1);
    }
}

static inline CFTypeRef copy_property(io_service_t service, CFStringRef key) {
    return IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
}

// Walks up the registry until an entry advertises SMART capability and reports its transport.
static inline io_service_t copy_smart_service(io_service_t media, int *transport) {
    io_service_t current = media;
    IOObjectRetain(current);
    *transport = 0;
    for (int depth = 0; depth < 32 && current != 0; depth++) {
        CFTypeRef nvme = copy_property(current, CFSTR(kIOPropertyNVMeSMARTCapableKey));
        if (nvme != NULL) {
            CFRelease(nvme);
            *transport = 2;
            return current;
        }
        CFTypeRef ata = copy_property(current, CFSTR(kIOPropertySMARTCapableKey));
        if (ata != NULL) {
            CFRelease(ata);
            *transport = 1;
            return current;
        }
        io_service_t parent = 0;
        kern_return_t kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        if (kr != KERN_SUCCESS) {
            return 0;
        }
        current = parent;
    }
    if (current != 0) {
        IOObjectRelease(current);
    }
    return 0;
}

static inline io_service_t copy_media(const char *bsdName) {
    if (bsdName == NULL || bsdName[0] == 0) {
        return 0;
    }
    CFMutableDictionaryRef match = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName);
    if (match == NULL) {
        return 0;
    }
    return IOServiceGetMatchingService(kIOMainPortDefault, match);
}

static inline void set_io_error(char *dst, int length, IOReturn code, const char *what) {
    if (length <= 0) {
        return;
    }
    snprintf(dst, (size_t)length, "%s failed (%#x)", what, code);
}

typedef struct DSUnknownVTable {
    void *_reserved;
    void *QueryInterface;
    void *AddRef;
    ULONG (*Release)(void *thisPointer);
} DSUnknownVTable;

static inline void close_plugin(void *interface, IOCFPlugInInterface **plugin, io_service_t service) {
    if (interface != NULL) {
        DSUnknownVTable **unknown = (DSUnknownVTable **)interface;
        (*unknown)->Release(interface);
    }
    if (plugin != NULL) {
        IODestroyPlugInInterface(plugin);
    }
    if (service != 0) {
        IOObjectRelease(service);
    }
}

#endif

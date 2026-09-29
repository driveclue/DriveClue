#import "SMARTBridge.h"

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/IOStorageDeviceCharacteristics.h>
#import <IOKit/storage/ata/ATASMARTLib.h>
#import <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#import <sys/mount.h>
#import <string.h>
#import <stdio.h>

static void zero_mem(void *ptr, size_t n) {
    memset(ptr, 0, n);
}

static void copy_cstr(char *dst, size_t dstLen, CFStringRef string) {
    if (dstLen == 0) {
        return;
    }
    dst[0] = 0;
    if (string == NULL) {
        return;
    }
    CFStringGetCString(string, dst, (CFIndex)dstLen, kCFStringEncodingUTF8);
}

static void trim_trailing(char *text) {
    size_t n = strlen(text);
    while (n > 0 && (text[n - 1] == ' ' || text[n - 1] == '\0')) {
        if (text[n - 1] == ' ') {
            text[n - 1] = 0;
            n--;
        } else {
            break;
        }
    }
    size_t start = 0;
    while (text[start] == ' ') {
        start++;
    }
    if (start > 0) {
        memmove(text, text + start, strlen(text + start) + 1);
    }
}

static CFTypeRef copy_property(io_service_t service, CFStringRef key) {
    return IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
}

static bool property_is_true(io_service_t service, CFStringRef key) {
    CFTypeRef value = copy_property(service, key);
    bool result = false;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            result = CFBooleanGetValue((CFBooleanRef)value);
        }
        CFRelease(value);
    }
    return result;
}

static uint64_t property_u64(io_service_t service, CFStringRef key) {
    CFTypeRef value = copy_property(service, key);
    uint64_t number = 0;
    if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number);
    }
    if (value != NULL) {
        CFRelease(value);
    }
    return number;
}

static void property_string(io_service_t service, CFStringRef key, char *dst, size_t dstLen) {
    CFTypeRef value = copy_property(service, key);
    dst[0] = 0;
    if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
        copy_cstr(dst, dstLen, (CFStringRef)value);
    }
    if (value != NULL) {
        CFRelease(value);
    }
}

static bool parent_conforms(io_service_t media, const char *className) {
    io_service_t current = media;
    IOObjectRetain(current);
    bool found = false;
    for (int depth = 0; depth < 32 && current != 0; depth++) {
        if (IOObjectConformsTo(current, className)) {
            found = true;
            break;
        }
        io_service_t parent = 0;
        kern_return_t kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        if (kr != KERN_SUCCESS) {
            current = 0;
            break;
        }
        current = parent;
    }
    if (current != 0) {
        IOObjectRelease(current);
    }
    return found;
}

static io_service_t copy_smart_service(io_service_t media, int *transport) {
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

static io_service_t copy_media(const char *bsdName) {
    if (bsdName == NULL || bsdName[0] == 0) {
        return 0;
    }
    CFMutableDictionaryRef match = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName);
    if (match == NULL) {
        return 0;
    }
    return IOServiceGetMatchingService(kIOMainPortDefault, match);
}

static void read_characteristics(io_service_t media, DSDiskInfo *info) {
    io_service_t current = media;
    IOObjectRetain(current);
    for (int depth = 0; depth < 32 && current != 0; depth++) {
        CFTypeRef value = copy_property(current, CFSTR("Device Characteristics"));
        if (value != NULL && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
            CFDictionaryRef dict = (CFDictionaryRef)value;
            if (info->registry_model[0] == 0) {
                copy_cstr(info->registry_model, sizeof(info->registry_model), CFDictionaryGetValue(dict, CFSTR("Product Name")));
            }
            if (info->registry_serial[0] == 0) {
                copy_cstr(info->registry_serial, sizeof(info->registry_serial), CFDictionaryGetValue(dict, CFSTR("Serial Number")));
            }
            if (info->registry_firmware[0] == 0) {
                copy_cstr(info->registry_firmware, sizeof(info->registry_firmware), CFDictionaryGetValue(dict, CFSTR("Product Revision Level")));
            }
        }
        if (value != NULL) {
            CFRelease(value);
        }
        CFTypeRef protocol = copy_property(current, CFSTR("Protocol Characteristics"));
        if (protocol != NULL && CFGetTypeID(protocol) == CFDictionaryGetTypeID()) {
            CFDictionaryRef dict = (CFDictionaryRef)protocol;
            if (info->interconnect[0] == 0) {
                copy_cstr(info->interconnect, sizeof(info->interconnect), CFDictionaryGetValue(dict, CFSTR("Physical Interconnect")));
            }
            if (info->location[0] == 0) {
                copy_cstr(info->location, sizeof(info->location), CFDictionaryGetValue(dict, CFSTR("Physical Interconnect Location")));
            }
        }
        if (protocol != NULL) {
            CFRelease(protocol);
        }
        io_service_t parent = 0;
        kern_return_t kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        if (kr != KERN_SUCCESS) {
            return;
        }
        current = parent;
    }
    if (current != 0) {
        IOObjectRelease(current);
    }
}

static void set_io_error(char *dst, int length, IOReturn code, const char *what) {
    if (length <= 0) {
        return;
    }
    snprintf(dst, (size_t)length, "%s failed (%#x)", what, code);
}

static void mount_path_for_bsd(const char *bsdName, char *dst, size_t dstLen) {
    dst[0] = 0;
    if (bsdName[0] == 0) {
        return;
    }
    int count = getfsstat(NULL, 0, MNT_NOWAIT);
    if (count <= 0) {
        return;
    }
    struct statfs *table = calloc((size_t)count, sizeof(struct statfs));
    if (table == NULL) {
        return;
    }
    int got = getfsstat(table, (int)(count * (int)sizeof(struct statfs)), MNT_NOWAIT);
    char device[64];
    snprintf(device, sizeof(device), "/dev/%s", bsdName);
    for (int i = 0; i < got; i++) {
        if (strcmp(table[i].f_mntfromname, device) == 0) {
            strncpy(dst, table[i].f_mntonname, dstLen - 1);
            dst[dstLen - 1] = 0;
            break;
        }
    }
    free(table);
}

static bool bsd_belongs_to_disk(const char *candidate, const char *disk) {
    if (candidate[0] == 0 || disk[0] == 0) {
        return false;
    }
    if (strcmp(candidate, disk) == 0) {
        return true;
    }
    size_t length = strlen(disk);
    return strncmp(candidate, disk, length) == 0 && candidate[length] == 's';
}

static int find_disk_index(DSDiskInfo *disks, int count, io_service_t media) {
    io_service_t current = media;
    IOObjectRetain(current);
    int found = -1;
    for (int depth = 0; depth < 40 && current != 0; depth++) {
        char bsd[32];
        zero_mem(bsd, sizeof(bsd));
        property_string(current, CFSTR("BSD Name"), bsd, sizeof(bsd));
        for (int i = 0; i < count; i++) {
            if (bsd_belongs_to_disk(bsd, disks[i].bsd_name)) {
                found = i;
                break;
            }
        }
        if (found >= 0) {
            break;
        }
        io_service_t parent = 0;
        kern_return_t kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        if (kr != KERN_SUCCESS) {
            current = 0;
            break;
        }
        current = parent;
    }
    if (current != 0) {
        IOObjectRelease(current);
    }
    return found;
}

static void first_role(io_service_t media, char *dst, size_t dstLen) {
    dst[0] = 0;
    CFTypeRef value = copy_property(media, CFSTR("Role"));
    if (value == NULL) {
        return;
    }
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        copy_cstr(dst, dstLen, (CFStringRef)value);
    } else if (CFGetTypeID(value) == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)value) > 0) {
        CFTypeRef item = CFArrayGetValueAtIndex((CFArrayRef)value, 0);
        if (item != NULL && CFGetTypeID(item) == CFStringGetTypeID()) {
            copy_cstr(dst, dstLen, (CFStringRef)item);
        }
    }
    CFRelease(value);
}

int DSEnumerateDisks(DSDiskInfo *outDisks, int capacity) {
    if (outDisks == NULL || capacity <= 0) {
        return 0;
    }
    io_iterator_t iterator = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator);
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    int count = 0;
    io_service_t media = 0;
    while ((media = IOIteratorNext(iterator)) != 0) {
        bool whole = property_is_true(media, CFSTR("Whole"));
        bool synthesized = IOObjectConformsTo(media, "AppleAPFSMedia") || parent_conforms(media, "AppleAPFSContainer");
        bool image = parent_conforms(media, "IOHDIXController") || parent_conforms(media, "AppleDiskImageDevice");
        char content[80];
        zero_mem(content, sizeof(content));
        property_string(media, CFSTR("Content"), content, sizeof(content));
        bool apfsContainer = strcmp(content, "EF57347C-0000-11AA-AA11-00306543ECAC") == 0;
        if (!whole || synthesized || image || apfsContainer || count >= capacity) {
            IOObjectRelease(media);
            continue;
        }
        DSDiskInfo *info = &outDisks[count];
        zero_mem(info, sizeof(*info));
        property_string(media, CFSTR("BSD Name"), info->bsd_name, sizeof(info->bsd_name));
        if (info->bsd_name[0] == 0) {
            IOObjectRelease(media);
            continue;
        }
        info->media_size = property_u64(media, CFSTR("Size"));
        info->block_size = (uint32_t)property_u64(media, CFSTR("Preferred Block Size"));
        int transport = 0;
        io_service_t smart = copy_smart_service(media, &transport);
        info->transport = transport;
        info->smart_capable = smart != 0;
        if (smart != 0) {
            IOObjectRelease(smart);
        }
        read_characteristics(media, info);
        trim_trailing(info->registry_model);
        trim_trailing(info->registry_serial);
        trim_trailing(info->registry_firmware);
        count++;
        IOObjectRelease(media);
    }
    IOObjectRelease(iterator);

    kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator);
    if (kr != KERN_SUCCESS) {
        return count;
    }
    while ((media = IOIteratorNext(iterator)) != 0) {
        if (property_is_true(media, CFSTR("Whole"))) {
            IOObjectRelease(media);
            continue;
        }
        int index = find_disk_index(outDisks, count, media);
        if (index < 0 || outDisks[index].volume_count >= DS_MAX_VOLUMES) {
            IOObjectRelease(media);
            continue;
        }
        char name[128];
        zero_mem(name, sizeof(name));
        property_string(media, CFSTR("FullName"), name, sizeof(name));
        if (name[0] == 0) {
            io_name_t entryName;
            if (IORegistryEntryGetName(media, entryName) == KERN_SUCCESS) {
                strncpy(name, entryName, sizeof(name) - 1);
            }
        }
        char bsd[32];
        zero_mem(bsd, sizeof(bsd));
        property_string(media, CFSTR("BSD Name"), bsd, sizeof(bsd));
        if (name[0] == 0 || bsd[0] == 0) {
            IOObjectRelease(media);
            continue;
        }
        DSVolumeInfo *volume = &outDisks[index].volumes[outDisks[index].volume_count];
        zero_mem(volume, sizeof(*volume));
        strncpy(volume->name, name, sizeof(volume->name) - 1);
        strncpy(volume->bsd_name, bsd, sizeof(volume->bsd_name) - 1);
        first_role(media, volume->role, sizeof(volume->role));
        volume->size_bytes = property_u64(media, CFSTR("Size"));
        mount_path_for_bsd(bsd, volume->mount_path, sizeof(volume->mount_path));
        outDisks[index].volume_count++;
        IOObjectRelease(media);
    }
    IOObjectRelease(iterator);
    return count;
}

typedef struct DSUnknownVTable {
    void *_reserved;
    void *QueryInterface;
    void *AddRef;
    ULONG (*Release)(void *thisPointer);
} DSUnknownVTable;

static void close_plugin(void *interface, IOCFPlugInInterface **plugin, io_service_t service) {
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

static IOATASMARTInterface **open_ata(const char *bsdName, IOCFPlugInInterface ***pluginOut, io_service_t *serviceOut, char *error, int errorLength) {
    *pluginOut = NULL;
    *serviceOut = 0;
    io_service_t media = copy_media(bsdName);
    if (media == 0) {
        set_io_error(error, errorLength, kIOReturnNotFound, "Find disk");
        return NULL;
    }
    int transport = 0;
    io_service_t smart = copy_smart_service(media, &transport);
    IOObjectRelease(media);
    if (smart == 0 || transport != 1) {
        if (smart != 0) {
            IOObjectRelease(smart);
        }
        snprintf(error, (size_t)errorLength, "This disk does not expose ATA S.M.A.R.T.");
        return NULL;
    }
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(smart, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != kIOReturnSuccess || plugin == NULL) {
        IOObjectRelease(smart);
        set_io_error(error, errorLength, kr, "Open ATA SMART");
        return NULL;
    }
    void *raw = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), &raw);
    if (hr != S_OK || raw == NULL) {
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(smart);
        snprintf(error, (size_t)errorLength, "ATA SMART interface is unavailable");
        return NULL;
    }
    *pluginOut = plugin;
    *serviceOut = smart;
    return (IOATASMARTInterface **)raw;
}

int DSReadATA(const char *bsdName, DSATARaw *outRaw) {
    if (outRaw == NULL) {
        return EINVAL;
    }
    zero_mem(outRaw, sizeof(*outRaw));
    outRaw->threshold_exceeded = -1;
    IOCFPlugInInterface **plugin = NULL;
    io_service_t service = 0;
    IOATASMARTInterface **ata = open_ata(bsdName, &plugin, &service, outRaw->error, (int)sizeof(outRaw->error));
    if (ata == NULL) {
        return ENODEV;
    }
    (*ata)->SMARTEnableDisableOperations(ata, true);
    Boolean exceeded = false;
    if ((*ata)->SMARTReturnStatus(ata, &exceeded) == kIOReturnSuccess) {
        outRaw->threshold_exceeded = exceeded ? 1 : 0;
    }
    if ((*ata)->SMARTReadData(ata, (ATASMARTData *)outRaw->smart_data) == kIOReturnSuccess) {
        outRaw->has_smart = 1;
    }
    if ((*ata)->SMARTReadDataThresholds(ata, (ATASMARTDataThresholds *)outRaw->thresholds) == kIOReturnSuccess) {
        outRaw->has_thresholds = 1;
    }
    UInt32 outSize = 0;
    if ((*ata)->GetATAIdentifyData(ata, outRaw->identify, 512, &outSize) == kIOReturnSuccess && outSize >= 512) {
        outRaw->has_identify = 1;
    }
    if ((*ata)->SMARTReadLogAtAddress(ata, 0x01, outRaw->error_log, 512) == kIOReturnSuccess) {
        outRaw->has_error_log = 1;
    }
    if ((*ata)->SMARTReadLogAtAddress(ata, 0x06, outRaw->selftest_log, 512) == kIOReturnSuccess) {
        outRaw->has_selftest_log = 1;
    }
    IOReturn stat = (*ata)->SMARTReadLogAtAddress(ata, 0x04, outRaw->devstat, DS_DEVSTAT_BYTES);
    if (stat != kIOReturnSuccess) {
        stat = (*ata)->SMARTReadLogAtAddress(ata, 0x04, outRaw->devstat, 512);
        if (stat == kIOReturnSuccess) {
            outRaw->devstat_bytes = 512;
        }
    } else {
        outRaw->devstat_bytes = DS_DEVSTAT_BYTES;
    }
    if (!outRaw->has_smart && outRaw->error[0] == 0) {
        snprintf(outRaw->error, sizeof(outRaw->error), "The drive did not return S.M.A.R.T. data");
    }
    close_plugin(ata, plugin, service);
    return outRaw->has_smart ? 0 : EIO;
}

int DSStartATASelfTest(const char *bsdName, int extended, char *error, int errorLength) {
    if (error != NULL && errorLength > 0) {
        error[0] = 0;
    }
    IOCFPlugInInterface **plugin = NULL;
    io_service_t service = 0;
    char local[256];
    IOATASMARTInterface **ata = open_ata(bsdName, &plugin, &service, local, (int)sizeof(local));
    if (ata == NULL) {
        if (error != NULL && errorLength > 0) {
            snprintf(error, (size_t)errorLength, "%s", local);
        }
        return ENODEV;
    }
    IOReturn kr = (*ata)->SMARTExecuteOffLineImmediate(ata, extended ? true : false);
    close_plugin(ata, plugin, service);
    if (kr != kIOReturnSuccess) {
        if (error != NULL && errorLength > 0) {
            set_io_error(error, errorLength, kr, "Start self-test");
        }
        return EIO;
    }
    return 0;
}

int DSAbortATASelfTest(const char *bsdName, char *error, int errorLength) {
    (void)bsdName;
    if (error != NULL && errorLength > 0) {
        snprintf(error, (size_t)errorLength, "macOS does not provide a cancel command for ATA self-tests. The test stops on its own.");
    }
    return ENOTSUP;
}

static uint64_t low64(const uint64_t pair[2]) {
    return pair[0];
}

static void copy_nvme_text(char *dst, size_t dstLen, const uint8_t *bytes, size_t byteCount) {
    size_t n = byteCount;
    if (n >= dstLen) {
        n = dstLen - 1;
    }
    memcpy(dst, bytes, n);
    dst[n] = 0;
    trim_trailing(dst);
}

int DSReadNVMe(const char *bsdName, DSNVMeRaw *outRaw) {
    if (outRaw == NULL) {
        return EINVAL;
    }
    zero_mem(outRaw, sizeof(*outRaw));
    io_service_t media = copy_media(bsdName);
    if (media == 0) {
        snprintf(outRaw->error, sizeof(outRaw->error), "Disk %s was not found", bsdName == NULL ? "" : bsdName);
        return ENODEV;
    }
    int transport = 0;
    io_service_t smart = copy_smart_service(media, &transport);
    IOObjectRelease(media);
    if (smart == 0 || transport != 2) {
        if (smart != 0) {
            IOObjectRelease(smart);
        }
        snprintf(outRaw->error, sizeof(outRaw->error), "This disk does not expose NVMe health data");
        return ENODEV;
    }
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(smart, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != kIOReturnSuccess || plugin == NULL) {
        IOObjectRelease(smart);
        set_io_error(outRaw->error, (int)sizeof(outRaw->error), kr, "Open NVMe SMART");
        return EIO;
    }
    void *raw = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), &raw);
    if (hr != S_OK || raw == NULL) {
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(smart);
        snprintf(outRaw->error, sizeof(outRaw->error), "NVMe SMART interface is unavailable");
        return EIO;
    }
    IONVMeSMARTInterface **nvme = (IONVMeSMARTInterface **)raw;
    NVMeSMARTData smartData;
    zero_mem(&smartData, sizeof(smartData));
    kr = (*nvme)->SMARTReadData(nvme, &smartData);
    if (kr != kIOReturnSuccess) {
        set_io_error(outRaw->error, (int)sizeof(outRaw->error), kr, "Read NVMe SMART");
        close_plugin(nvme, plugin, smart);
        return EIO;
    }
    outRaw->critical_warning = smartData.CRITICAL_WARNING;
    outRaw->temperature_k = smartData.TEMPERATURE;
    outRaw->available_spare = smartData.AVAILABLE_SPARE;
    outRaw->spare_threshold = smartData.AVAILABLE_SPARE_THRESHOLD;
    outRaw->percentage_used = smartData.PERCENTAGE_USED;
    outRaw->data_units_read = low64(smartData.DATA_UNITS_READ);
    outRaw->data_units_written = low64(smartData.DATA_UNITS_WRITTEN);
    outRaw->host_read_commands = low64(smartData.HOST_READ_COMMANDS);
    outRaw->host_write_commands = low64(smartData.HOST_WRITE_COMMANDS);
    outRaw->power_cycles = low64(smartData.POWER_CYCLES);
    outRaw->power_on_hours = low64(smartData.POWER_ON_HOURS);
    outRaw->unsafe_shutdowns = low64(smartData.UNSAFE_SHUTDOWNS);
    outRaw->media_errors = low64(smartData.MEDIA_ERRORS);
    outRaw->error_log_entries = low64(smartData.NUM_ERROR_INFO_LOG_ENTRIES);

    NVMeIdentifyControllerStruct identify;
    zero_mem(&identify, sizeof(identify));
    if ((*nvme)->GetIdentifyData(nvme, &identify, 0) == kIOReturnSuccess) {
        copy_nvme_text(outRaw->serial, sizeof(outRaw->serial), identify.SERIAL_NUMBER, 20);
        copy_nvme_text(outRaw->model, sizeof(outRaw->model), identify.MODEL_NUMBER, 40);
        copy_nvme_text(outRaw->firmware, sizeof(outRaw->firmware), identify.FW_REVISION, 8);
        outRaw->pci_vid = identify.PCI_VID;
    }
    NVMeIdentifyNamespaceStruct namespaceInfo;
    zero_mem(&namespaceInfo, sizeof(namespaceInfo));
    if ((*nvme)->GetIdentifyData(nvme, &namespaceInfo, 1) == kIOReturnSuccess) {
        uint8_t formatIndex = namespaceInfo.FORMATTED_LBA_SIZE & 0x0F;
        if (formatIndex < 16) {
            uint8_t shift = namespaceInfo.LBA_FORMATS[formatIndex].LBA_DATA_SIZE;
            if (shift >= 9 && shift <= 16) {
                outRaw->lba_size = 1u << shift;
            }
        }
        if (outRaw->lba_size > 0) {
            outRaw->namespace_bytes = namespaceInfo.NAMESPACE_SIZE * (uint64_t)outRaw->lba_size;
        }
    }
    close_plugin(nvme, plugin, smart);
    return 0;
}

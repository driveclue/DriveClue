#import "SMARTInternal.h"

#import <sys/mount.h>

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
        info->removable = property_is_true(media, CFSTR("Removable")) ? 1 : 0;
        info->ejectable = property_is_true(media, CFSTR("Ejectable")) ? 1 : 0;
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

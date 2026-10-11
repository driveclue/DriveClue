#import "SMARTInternal.h"

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
    IOCFPlugInInterface **plugin = NULL;
    io_service_t service = 0;
    IOATASMARTInterface **ata = open_ata(bsdName, &plugin, &service, outRaw->error, (int)sizeof(outRaw->error));
    if (ata == NULL) {
        return ENODEV;
    }
    (*ata)->SMARTEnableDisableOperations(ata, true);
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

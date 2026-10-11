#import "SMARTInternal.h"

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
    outRaw->controller_busy_time = low64(smartData.CONTROLLER_BUSY_TIME);
    outRaw->power_cycles = low64(smartData.POWER_CYCLES);
    outRaw->power_on_hours = low64(smartData.POWER_ON_HOURS);
    outRaw->unsafe_shutdowns = low64(smartData.UNSAFE_SHUTDOWNS);
    outRaw->media_errors = low64(smartData.MEDIA_ERRORS);
    outRaw->error_log_entries = low64(smartData.NUM_ERROR_INFO_LOG_ENTRIES);
    // NVMe SMART/health log layout (NVM Express 1.0c §5.10.1.2, the layout this Apple
    // interface documents): warning composite temperature time lives at byte offset
    // 0xC0 and critical at 0xC2. Apple's struct leaves both counters unnamed inside
    // RESERVED2, which starts exactly at log offset 0xC0.
    outRaw->warning_temp_time = (uint32_t)(smartData.RESERVED2[0] | ((uint32_t)smartData.RESERVED2[1] << 8));
    outRaw->critical_temp_time = (uint32_t)(smartData.RESERVED2[2] | ((uint32_t)smartData.RESERVED2[3] << 8));

    NVMeIdentifyControllerStruct identify;
    zero_mem(&identify, sizeof(identify));
    if ((*nvme)->GetIdentifyData(nvme, &identify, 0) == kIOReturnSuccess) {
        copy_nvme_text(outRaw->serial, sizeof(outRaw->serial), identify.SERIAL_NUMBER, 20);
        copy_nvme_text(outRaw->model, sizeof(outRaw->model), identify.MODEL_NUMBER, 40);
        copy_nvme_text(outRaw->firmware, sizeof(outRaw->firmware), identify.FW_REVISION, 8);
        outRaw->pci_vid = identify.PCI_VID;
        outRaw->max_data_transfer_size = identify.MAX_DATA_TRANSFER_SIZE;
        outRaw->optional_admin_commands = identify.OPTIONAL_ADMIN_COMMAND_SUPPORT;
        outRaw->log_page_attributes = identify.LOG_PAGE_ATTR;
        outRaw->error_log_page_entries = identify.ERROR_LOG_PAGE_ENTRIES;
        outRaw->power_state_count = identify.NUM_OF_POWER_STATE_SUPPORT;
        outRaw->optional_nvm_commands = identify.OPTIONAL_NVM_COMMAND_SUPPORT;
        outRaw->format_nvm_attributes = identify.FORMAT_NVM_ATTR;
        outRaw->volatile_write_cache = identify.VOLATILE_WRITE_CACHE;
        outRaw->namespace_count = identify.NUM_OF_NAMESPACES;
        outRaw->has_identify = 1;
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
            outRaw->namespace_capacity_bytes = namespaceInfo.NAMESPACE_CAPACITY * (uint64_t)outRaw->lba_size;
            outRaw->namespace_utilization_bytes = namespaceInfo.NAMESPACE_UTILIZATION * (uint64_t)outRaw->lba_size;
        }
    }
    close_plugin(nvme, plugin, smart);
    return 0;
}

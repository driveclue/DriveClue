#ifndef SMART_BRIDGE_H
#define SMART_BRIDGE_H

#include <stdint.h>

#define DS_MAX_DISKS 32
#define DS_MAX_VOLUMES 24
#define DS_DEVSTAT_BYTES 4096

typedef struct {
    char name[128];
    char bsd_name[32];
    char mount_path[1024];
    char role[32];
    uint64_t size_bytes;
} DSVolumeInfo;

typedef struct {
    char bsd_name[32];
    int transport; /* 0 none, 1 ATA, 2 NVMe */
    int smart_capable;
    uint64_t media_size;
    uint32_t block_size;
    char registry_model[64];
    char registry_serial[40];
    char registry_firmware[16];
    char interconnect[32];
    char location[32];
    DSVolumeInfo volumes[DS_MAX_VOLUMES];
    int volume_count;
} DSDiskInfo;

typedef struct {
    uint8_t smart_data[512];
    uint8_t thresholds[512];
    int has_smart;
    int has_thresholds;
    uint8_t identify[512];
    int has_identify;
    uint8_t error_log[512];
    int has_error_log;
    uint8_t selftest_log[512];
    int has_selftest_log;
    uint8_t devstat[DS_DEVSTAT_BYTES];
    int devstat_bytes;
    int threshold_exceeded; /* -1 unknown, 0 no, 1 yes */
    char error[256];
} DSATARaw;

typedef struct {
    char model[48];
    char serial[24];
    char firmware[12];
    uint32_t pci_vid;
    uint32_t temperature_k;
    uint32_t available_spare;
    uint32_t spare_threshold;
    uint32_t percentage_used;
    uint32_t critical_warning;
    uint64_t data_units_read;
    uint64_t data_units_written;
    uint64_t host_read_commands;
    uint64_t host_write_commands;
    uint64_t power_cycles;
    uint64_t power_on_hours;
    uint64_t unsafe_shutdowns;
    uint64_t media_errors;
    uint64_t error_log_entries;
    uint64_t namespace_bytes;
    uint32_t lba_size;
    char error[256];
} DSNVMeRaw;

int DSEnumerateDisks(DSDiskInfo *outDisks, int capacity);
int DSReadATA(const char *bsdName, DSATARaw *outRaw);
int DSReadNVMe(const char *bsdName, DSNVMeRaw *outRaw);
int DSStartATASelfTest(const char *bsdName, int extended, char *error, int errorLength);
int DSAbortATASelfTest(const char *bsdName, char *error, int errorLength);

#endif

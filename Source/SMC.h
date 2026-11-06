// SPDX-License-Identifier: MIT
#include <stdint.h>
// Read-only capability probe. These functions never accept arbitrary SMC keys.
int cm_probe(char *output, int capacity);
// Readable capabilities: bit 0 direct charge, bit 1 adapter, bit 2 firmware limits,
// bit 3 independent physical AC presence. No writes.
int cm_capabilities(void);
// Test permission by writing the existing activation bytes back unchanged.
int cm_test_firmware_access(char *output, int capacity);
int cm_firmware_read(int *activation, int *upper, int *lower, char *error, int capacity);
int cm_firmware_set(int activation, int upper, int lower, char *error, int capacity);
int cm_adapter(int discharging, char *error, int capacity);
// Physical AC presence, independent of adapter cut. 0/1 or -1 if unknown.
int cm_physical_power(void);
int cm_control(int charging, int discharging, char *error, int capacity);
int cm_restore(char *error, int capacity);
// 0 = preparing to sleep, 1 = wake. Registration must succeed before policy runs.
int cm_watch_power(void (*callback)(int));

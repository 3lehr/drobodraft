// Stufe 3b: loest im Dext MaxWriteProbe einen Lese-CDB aus. Aufruf: probe_cmd 1 (INQUIRY) | 2 (MODE SENSE(10) 0x3F)
// Ergebnis steht im os_log des Dext (MaxWriteProbe: 3b ERGEBNIS) und, falls der Kernel es durchreicht, als Property ProbeResult.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    int cmd = argc > 1 ? atoi(argv[1]) : 1;
    io_service_t svc = IO_OBJECT_NULL;
    io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUserSCSIPeripheralDeviceType00"), &it);
    for (io_service_t s; (s = IOIteratorNext(it));) {
        CFTypeRef u = IORegistryEntryCreateCFProperty(s, CFSTR("IOUserClass"), kCFAllocatorDefault, 0);
        if (u && CFEqual(u, CFSTR("MaxWriteProbe"))) { svc = s; CFRelease(u); break; }
        if (u) CFRelease(u);
        IOObjectRelease(s);
    }
    if (!svc) { fprintf(stderr, "kein MaxWriteProbe-Dienst\n"); return 2; }
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &cmd);
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, CFSTR("ProbeCmd"), n);
    kern_return_t r = IORegistryEntrySetCFProperties(svc, d);
    printf("SetCFProperties cmd=%d ret=0x%x\n", cmd, r);
    CFTypeRef res = IORegistryEntryCreateCFProperty(svc, CFSTR("ProbeResult"), kCFAllocatorDefault, 0);
    if (res) { CFShow(res); CFRelease(res); } else puts("ProbeResult: nicht in Registry");
    return r == KERN_SUCCESS ? 0 : 1;
}

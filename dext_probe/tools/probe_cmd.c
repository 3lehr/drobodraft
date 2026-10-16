// Stufe 3b: loest im Dext MaxWriteProbe einen Lese-CDB aus. Aufruf: probe_cmd 1 (INQUIRY) | 2 (MODE SENSE(10) 0x3F)
// Weg: IOServiceOpen -> UserClient, Selektor 0, Skalar cmd; Antwort = Text. Dienst ist !registered, daher Registry-Iterator.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    uint64_t cmd = argc > 1 ? atoi(argv[1]) : 1;
    io_service_t svc = IO_OBJECT_NULL;
    io_iterator_t it;
    IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &it);
    for (io_service_t s; (s = IOIteratorNext(it));) {
        CFTypeRef u = IORegistryEntryCreateCFProperty(s, CFSTR("IOUserClass"), kCFAllocatorDefault, 0);
        if (u && CFEqual(u, CFSTR("MaxWriteProbe"))) { svc = s; CFRelease(u); break; }
        if (u) CFRelease(u);
        IOObjectRelease(s);
    }
    if (!svc) { fprintf(stderr, "kein MaxWriteProbe-Dienst\\n"); return 2; }
    io_connect_t c;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &c);
    printf("IOServiceOpen ret=0x%x\\n", r);
    if (r) return 1;
    char out[512] = {}; size_t n = sizeof out;
    r = IOConnectCallMethod(c, 0, &cmd, 1, NULL, 0, NULL, NULL, out, &n);
    printf("cmd=%llu call ret=0x%x out=%s\\n", cmd, r, out);
    IOServiceClose(c);
    return r ? 1 : 0;
}

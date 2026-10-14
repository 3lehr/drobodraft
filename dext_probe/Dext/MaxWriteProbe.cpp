#include <DriverKit/DriverKit.h>
#include <DriverKit/IOKitKeys.h>
#include <os/log.h>
#include "MaxWriteProbe.h"

// Weg A (Plan Phase 0b): Schreibbefehle begrenzen, sonst Standardverhalten.
// Die Drobo verdaut keine Schreibbefehle > 512 KiB, Kernel-HFS schickt 1 MiB (Ziel 524288/1024).
// v1.3: Testwert 65536/128 am USB-2-Leser (Protokollwert 131072): VERKLEINERN wie bei der Drobo.
// v1.2 (524288, Vergroessern) wurde auf 131072 zurueckgesetzt, siehe AKTIVIERUNG.md.
static constexpr uint64_t kMaxWriteBytes  = 65536;
static constexpr uint64_t kMaxWriteBlocks = 128;  // 128 * 512 B = 65536

kern_return_t IMPL(MaxWriteProbe, UserDetermineDeviceCharacteristics)
{
    *result = false;
    OSDictionary *props = OSDictionary::withCapacity(2);
    OSNumber *bytes  = OSNumber::withNumber(kMaxWriteBytes, 64);
    OSNumber *blocks = OSNumber::withNumber(kMaxWriteBlocks, 64);
    kern_return_t ret = kIOReturnNoMemory;
    if (props && bytes && blocks) {
        props->setObject(kIOMaximumByteCountWriteKey, bytes);
        props->setObject(kIOMaximumBlockCountWriteKey, blocks);
        // SUPERDISPATCH: ohne ihn bleibt der Aufruf im Dext (Default scheitert); mit ihm schreibt
        // der Kernel-Teil die Keys in den Registry-Eintrag (Muster aus IOHIDEventService.iig).
        ret = SetProperties(props, SUPERDISPATCH);
    }
    *result = true;  // Grenzen sind Zusatz; das Geraet muss auch bei Fehlschlag starten (ret wird geloggt)
    os_log(OS_LOG_DEFAULT, "MaxWriteProbe: UserDetermineDeviceCharacteristics bytes=%llu blocks=%llu ret=0x%x result=%d",
           kMaxWriteBytes, kMaxWriteBlocks, ret, (int)*result);
    OSSafeReleaseNULL(blocks);
    OSSafeReleaseNULL(bytes);
    OSSafeReleaseNULL(props);
    return kIOReturnSuccess;
}

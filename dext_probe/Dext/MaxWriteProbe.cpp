#include <DriverKit/DriverKit.h>
#include <DriverKit/IOKitKeys.h>
#include "MaxWriteProbe.h"

// Weg A (Plan Phase 0b): Schreibbefehle auf 512 KiB kappen, sonst Standardverhalten.
// Die Drobo verdaut keine Schreibbefehle > 512 KiB, Kernel-HFS schickt 1 MiB.
static constexpr uint64_t kMaxWriteBytes  = 524288;
static constexpr uint64_t kMaxWriteBlocks = 1024;  // 1024 * 512 B = 524288

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
        ret = SetProperties(props);
        *result = (ret == kIOReturnSuccess);
    }
    OSSafeReleaseNULL(blocks);
    OSSafeReleaseNULL(bytes);
    OSSafeReleaseNULL(props);
    return ret;
}

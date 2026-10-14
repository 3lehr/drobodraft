#include <DriverKit/DriverKit.h>
#include <DriverKit/IOKitKeys.h>
#include <os/log.h>
#include <time.h>
#include <stdio.h>
#include "MaxWriteProbe.h"

// Weg A (Plan Phase 0b): Schreibbefehle begrenzen, sonst Standardverhalten.
// Die Drobo verdaut keine Schreibbefehle > 512 KiB, Kernel-HFS schickt 1 MiB (Ziel 524288/1024).
// v1.3/1.4: Testwert 65536/128 am USB-2-Leser (Protokollwert 131072): VERKLEINERN wie bei der Drobo.
static constexpr uint64_t kMaxWriteBytes  = 65536;
static constexpr uint64_t kMaxWriteBlocks = 128;  // 128 * 512 B = 65536

struct MaxWriteProbe_IVars {
    IOTimerDispatchSource *t2;
    IOTimerDispatchSource *t10;
    OSAction *action;
    uint64_t startNs;
};

// v1.4 Diagnose: Properties am eigenen Objekt lesen und mit Marke loggen.
static void LogProps(IOService *svc, const char *tag)
{
    OSDictionary *out = nullptr;
    kern_return_t r = svc->CopyProperties(&out);
    uint64_t bytes = 0, blocks = 0;
    bool hasBytes = false, hasBlocks = false, hasUSP = false, uspBytes = false, uspBlocks = false;
    uint32_t count = 0, uspCount = 0;
    if (r == kIOReturnSuccess && out) {
        count = out->getCount();
        OSNumber *n = OSDynamicCast(OSNumber, out->getObject(kIOMaximumByteCountWriteKey));
        if (n) { hasBytes = true; bytes = n->unsigned64BitValue(); }
        n = OSDynamicCast(OSNumber, out->getObject(kIOMaximumBlockCountWriteKey));
        if (n) { hasBlocks = true; blocks = n->unsigned64BitValue(); }
        OSDictionary *usp = OSDynamicCast(OSDictionary, out->getObject("IOUserServiceProperties"));
        if (usp) {
            hasUSP = true; uspCount = usp->getCount();
            uspBytes  = usp->getObject(kIOMaximumByteCountWriteKey) != nullptr;
            uspBlocks = usp->getObject(kIOMaximumBlockCountWriteKey) != nullptr;
        }
    }
    os_log(OS_LOG_DEFAULT,
           "MaxWriteProbe: DIAG %{public}s copy=0x%x keys=%u bytes=%d:%llu blocks=%d:%llu IOUserServiceProperties=%d(count=%u bytes=%d blocks=%d)",
           tag, r, count, hasBytes, bytes, hasBlocks, blocks, hasUSP, uspCount, uspBytes, uspBlocks);
    OSSafeReleaseNULL(out);
}

bool MaxWriteProbe::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(MaxWriteProbe_IVars, 1);
    return ivars != nullptr;
}

void MaxWriteProbe::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->t2);
        OSSafeReleaseNULL(ivars->t10);
        OSSafeReleaseNULL(ivars->action);
        IOSafeDeleteNULL(ivars, MaxWriteProbe_IVars, 1);
    }
    super::free();
}

kern_return_t IMPL(MaxWriteProbe, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    os_log(OS_LOG_DEFAULT, "MaxWriteProbe: DIAG Start super ret=0x%x", ret);
    if (ret != kIOReturnSuccess) return ret;
    LogProps(this, "Start");
    // Timer 2 s und 10 s; Fehler nur loggen, das Geraet muss starten.
    IODispatchQueue *q = nullptr;
    ivars->startNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (CopyDispatchQueue(kIOServiceDefaultQueueName, &q) == kIOReturnSuccess && q &&
        CreateActionTimerFired(0, &ivars->action) == kIOReturnSuccess &&
        IOTimerDispatchSource::Create(q, &ivars->t2) == kIOReturnSuccess &&
        IOTimerDispatchSource::Create(q, &ivars->t10) == kIOReturnSuccess) {
        ivars->t2->SetHandler(ivars->action);
        ivars->t10->SetHandler(ivars->action);
        ivars->t2->SetEnable(true);
        ivars->t10->SetEnable(true);
        ivars->t2->WakeAtTime(kIOTimerClockUptimeRaw, ivars->startNs + 2000000000ull, 0);
        ivars->t10->WakeAtTime(kIOTimerClockUptimeRaw, ivars->startNs + 10000000000ull, 0);
    } else {
        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: DIAG Timer-Aufbau fehlgeschlagen");
    }
    OSSafeReleaseNULL(q);
    return kIOReturnSuccess;
}

void IMPL(MaxWriteProbe, TimerFired)
{
    uint64_t ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - ivars->startNs) / 1000000ull;
    char tag[32];
    snprintf(tag, sizeof tag, "Timer+%llums", ms);
    LogProps(this, tag);
}

kern_return_t IMPL(MaxWriteProbe, UserDetermineDeviceCharacteristics)
{
    OSDictionary *props = OSDictionary::withCapacity(2);
    OSNumber *bytes  = OSNumber::withNumber(kMaxWriteBytes, 64);
    OSNumber *blocks = OSNumber::withNumber(kMaxWriteBlocks, 64);
    kern_return_t ret = kIOReturnNoMemory;
    if (props && bytes && blocks) {
        props->setObject(kIOMaximumByteCountWriteKey, bytes);
        props->setObject(kIOMaximumBlockCountWriteKey, blocks);
        ret = SetProperties(props, SUPERDISPATCH);
    }
    *result = true;  // Grenzen sind Zusatz; das Geraet muss auch bei Fehlschlag starten (ret wird geloggt)
    os_log(OS_LOG_DEFAULT, "MaxWriteProbe: UserDetermineDeviceCharacteristics bytes=%llu blocks=%llu ret=0x%x result=%d",
           kMaxWriteBytes, kMaxWriteBlocks, ret, (int)*result);
    LogProps(this, "nach SetProperties");
    OSSafeReleaseNULL(blocks);
    OSSafeReleaseNULL(bytes);
    OSSafeReleaseNULL(props);
    return kIOReturnSuccess;
}

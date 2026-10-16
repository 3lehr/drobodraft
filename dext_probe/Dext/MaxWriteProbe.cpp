#include <DriverKit/DriverKit.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <os/log.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "MaxWriteProbe.h"

// Stufe 3b. Nur Lese-CDBs, byte-genaue Allowlist (Recon DROBO_PROTOKOLL_RECON_2026-10-14.md Abschnitt 5).
static constexpr uint32_t kTimeoutMs = 5000;
static constexpr uint64_t kDataLen   = 1308;  // groesster erlaubter Alloc (Seite 0x35)
static constexpr uint8_t  kSenseLen  = 20;    // Apple DTS: > 20 -> kIOReturnError (Forum 800955)
static constexpr uint64_t kFirstNs = 25000000000ull, kPeriodNs = 4000000000ull;

struct Schuss { const char *name; uint8_t len; uint8_t cdb[10]; };
static const Schuss kSchuesse[] = {
    {"ROTPROBE verboten 5A/3A/E1",  10, {0x5A,0x08,0x3A,0xE1,0,0,0,0x00,0x08,0}},   // MUSS abgelehnt werden
    {"INQUIRY std",                  6, {0x12,0x00,0x00,0x00,0x24,0}},
    {"VPD 0x80 Seriennummer",        6, {0x12,0x01,0x80,0x00,0x1C,0}},
    {"3A/06 ProtocolVersion",       10, {0x5A,0x08,0x3A,0x06,0,0,0,0x00,0x06,0}},
    {"3A/01 Configuration",         10, {0x5A,0x08,0x3A,0x01,0,0,0,0x00,0x1C,0}},
    {"3A/02 Capacity",              10, {0x5A,0x08,0x3A,0x02,0,0,0,0x00,0x24,0}},
    {"3A/09 Status",                10, {0x5A,0x08,0x3A,0x09,0,0,0,0x00,0x18,0}},
    {"3A/08 Firmware",              10, {0x5A,0x08,0x3A,0x08,0,0,0,0x01,0x3A,0}},
    {"3A/33 SysInfo",               10, {0x5A,0x08,0x3A,0x33,0,0,0,0x00,0x18,0}},
    {"3A/35 SlotInfo2",             10, {0x5A,0x08,0x3A,0x35,0,0,0,0x05,0x1C,0}},
};
static constexpr int kShots = sizeof kSchuesse / sizeof kSchuesse[0];

// Byte-genau: INQUIRY 12 00 00 00 LL 00 | VPD 12 01 {00|80} 00 LL 00 | MODE SENSE(10) 5A 08 3A SS 00 00 00 LH LL 00
static bool CdbErlaubt(const uint8_t *c, uint8_t len)
{
    if (len == 6 && c[0] == 0x12 && c[3] == 0 && c[5] == 0 && c[4] != 0) {
        if (c[1] == 0x00 && c[2] == 0x00) return true;
        if (c[1] == 0x01 && (c[2] == 0x00 || c[2] == 0x80)) return true;
        return false;
    }
    if (len == 10 && c[0] == 0x5A && c[1] == 0x08 && c[2] == 0x3A && c[4] == 0 && c[5] == 0 && c[6] == 0 && c[9] == 0) {
        uint16_t alloc = (c[7] << 8) | c[8];
        if (alloc == 0 || alloc > kDataLen) return false;
        switch (c[3]) { case 0x01: case 0x02: case 0x06: case 0x08: case 0x09: case 0x33: case 0x35: return true; }
    }
    return false;
}

struct MaxWriteProbe_IVars { IOTimerDispatchSource *t; OSAction *action; int shot; };

bool MaxWriteProbe::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(MaxWriteProbe_IVars, 1);
    return ivars != nullptr;
}
void MaxWriteProbe::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->t);
        OSSafeReleaseNULL(ivars->action);
        IOSafeDeleteNULL(ivars, MaxWriteProbe_IVars, 1);
    }
    super::free();
}

kern_return_t IMPL(MaxWriteProbe, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b Start ret=0x%x", ret);
    if (ret != kIOReturnSuccess) return ret;
    IODispatchQueue *q = nullptr;
    if (CopyDispatchQueue(kIOServiceDefaultQueueName, &q) == kIOReturnSuccess && q &&
        CreateActionTimerFired(0, &ivars->action) == kIOReturnSuccess &&
        IOTimerDispatchSource::Create(q, &ivars->t) == kIOReturnSuccess) {
        ivars->t->SetHandler(ivars->action);
        ivars->t->SetEnable(true);
        ivars->t->WakeAtTime(kIOTimerClockMonotonicRaw, clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + kFirstNs, 0);
        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b Timer gesetzt, erster Schuss +25 s, dann alle 4 s, %d Schuesse", kShots);
    } else os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b Timer-Aufbau fehlgeschlagen");
    OSSafeReleaseNULL(q);
    return kIOReturnSuccess;
}

kern_return_t IMPL(MaxWriteProbe, UserDetermineDeviceCharacteristics)
{
    *result = true;   // Standardverhalten, keine Grenzen gesetzt
    return kIOReturnSuccess;
}

static void HexZeilen(int shot, const uint8_t *p, uint64_t n)
{
    char h[160];
    for (uint64_t off = 0; off < n; off += 64) {
        uint64_t m = n - off < 64 ? n - off : 64;
        size_t o = 0;
        for (uint64_t i = 0; i < m; i++) o += snprintf(h + o, sizeof h - o, "%02x", p[off + i]);
        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b HEX shot=%d off=%llu %{public}s", shot, off, h);
    }
}

void IMPL(MaxWriteProbe, TimerFired)
{
    int n = ivars->shot++;
    const Schuss &s = kSchuesse[n];
    kern_return_t r = kIOReturnNoMemory;
    IOBufferMemoryDescriptor *dbuf = nullptr, *sbuf = nullptr;
    if (!CdbErlaubt(s.cdb, s.len)) {   // Allowlist VOR dem Senden
        r = kIOReturnNotPermitted;
        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b ERGEBNIS shot=%d %{public}s REJECT allowlist ret=0x%x%{public}s", n, s.name, r,
               n == 0 ? (r == kIOReturnNotPermitted ? " ROTPROBE=PASS" : " ROTPROBE=FAIL") : "");
    } else if (IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kDataLen, 0, &dbuf) == kIOReturnSuccess &&
               IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kSenseLen, 0, &sbuf) == kIOReturnSuccess) {
        dbuf->SetLength(kDataLen); sbuf->SetLength(kSenseLen);
        IOAddressSegment d = {}, se = {};
        dbuf->GetAddressRange(&d); sbuf->GetAddressRange(&se);
        memset((void *)d.address, 0, kDataLen); memset((void *)se.address, 0, kSenseLen);
        uint64_t alloc = (s.len == 6) ? s.cdb[4] : (uint64_t)((s.cdb[7] << 8) | s.cdb[8]);

        SCSIType00OutParameters out = {};
        SCSIType00InParameters in = {};
        memcpy(out.fCommandDescriptorBlock, s.cdb, s.len);
        out.fLogicalUnitNumber = 0;
        out.fTimeoutDuration = kTimeoutMs;
        out.fRequestedByteCountOfTransfer = alloc;
        out.fBufferDirection = kIOMemoryDirectionIn;
        out.fDataTransferDirection = kSCSIDataTransfer_FromTargetToInitiator;
        out.fSenseLengthRequested = kSenseLen;
        out.fDataBufferAddr = d.address;
        out.fSenseBufferAddr = se.address;
        r = UserSendCDB(out, &in);
        uint64_t got = in.fRealizedByteCountOfTransfer < kDataLen ? in.fRealizedByteCountOfTransfer : kDataLen;
        char sh[48]; size_t o = 0;
        for (int i = 0; i < kSenseLen && o + 3 < sizeof sh; i++) o += snprintf(sh + o, sizeof sh - o, "%02x", ((uint8_t *)se.address)[i]);
        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b ERGEBNIS shot=%d %{public}s alloc=%llu ret=0x%x taskstatus=%u svc=%u bytes=%llu sensevalid=%d sense=%{public}s",
               n, s.name, alloc, r, (unsigned)in.fCompletionStatus, (unsigned)in.fServiceResponse,
               in.fRealizedByteCountOfTransfer, (int)in.fSenseDataValid, sh);
        HexZeilen(n, (const uint8_t *)d.address, got);
    }
    OSSafeReleaseNULL(dbuf);
    OSSafeReleaseNULL(sbuf);
    if (ivars->shot < kShots)
        ivars->t->WakeAtTime(kIOTimerClockMonotonicRaw, clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + kPeriodNs, 0);
}

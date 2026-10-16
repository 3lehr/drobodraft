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
static constexpr uint64_t kFirstNs = 20000000000ull, kPeriodNs = 60000000000ull;

struct Schuss { const char *name; const char *key; uint8_t len; uint8_t cdb[10]; };
static const Schuss kRotprobe = {"ROTPROBE verboten 5A/3A/E1", "", 10, {0x5A,0x08,0x3A,0xE1,0,0,0,0x00,0x08,0}};   // MUSS abgelehnt werden
static const Schuss kSeiten[] = {
    {"INQUIRY std",            "inquiry", 6,  {0x12,0x00,0x00,0x00,0x24,0}},
    {"VPD 0x80 Seriennummer",  "vpd80",   6,  {0x12,0x01,0x80,0x00,0x1C,0}},
    {"3A/01 Configuration",    "p3A_01",  10, {0x5A,0x08,0x3A,0x01,0,0,0,0x00,0x1C,0}},
    {"3A/02 Capacity",         "p3A_02",  10, {0x5A,0x08,0x3A,0x02,0,0,0,0x00,0x24,0}},
    {"3A/06 ProtocolVersion",  "p3A_06",  10, {0x5A,0x08,0x3A,0x06,0,0,0,0x00,0x06,0}},
    {"3A/08 Firmware",         "p3A_08",  10, {0x5A,0x08,0x3A,0x08,0,0,0,0x01,0x3A,0}},
    {"3A/09 Status",           "p3A_09",  10, {0x5A,0x08,0x3A,0x09,0,0,0,0x00,0x18,0}},
    {"3A/33 SysInfo",          "p3A_33",  10, {0x5A,0x08,0x3A,0x33,0,0,0,0x00,0x18,0}},
    {"3A/35 SlotInfo2",        "p3A_35",  10, {0x5A,0x08,0x3A,0x35,0,0,0,0x05,0x1C,0}},
};
static constexpr int kSeitenAnzahl = sizeof kSeiten / sizeof kSeiten[0];

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

struct MaxWriteProbe_IVars { IOTimerDispatchSource *t; OSAction *action; uint32_t cycle; };

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
        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b Timer gesetzt, erster Zyklus +20 s, dann alle 60 s, %d Seiten", kSeitenAnzahl);
    } else os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b Timer-Aufbau fehlgeschlagen");
    OSSafeReleaseNULL(q);
    return kIOReturnSuccess;
}

kern_return_t IMPL(MaxWriteProbe, UserDetermineDeviceCharacteristics)
{
    *result = true;   // Standardverhalten, keine Grenzen gesetzt
    return kIOReturnSuccess;
}

static void HexZeilen(const char *key, const uint8_t *p, uint64_t n)
{
    char h[160];
    for (uint64_t off = 0; off < n; off += 64) {
        uint64_t m = n - off < 64 ? n - off : 64;
        size_t o = 0;
        for (uint64_t i = 0; i < m; i++) o += snprintf(h + o, sizeof h - o, "%02x", p[off + i]);
        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b HEX %{public}s off=%llu %{public}s", key, off, h);
    }
}

// Sendet einen erlaubten Lese-CDB. Rueckgabe: GOOD (ret 0, taskstatus 0). data = Rohantwort (retained) oder nullptr.
static bool Sende(MaxWriteProbe *self, const Schuss &s, IOAddressSegment d, IOAddressSegment se, OSData **data, kern_return_t *retOut)
{
    if (!CdbErlaubt(s.cdb, s.len)) { *retOut = kIOReturnNotPermitted; return false; }   // Allowlist VOR dem Senden
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
    kern_return_t r = self->UserSendCDB(out, &in);
    *retOut = r;
    uint64_t got = in.fRealizedByteCountOfTransfer < kDataLen ? in.fRealizedByteCountOfTransfer : kDataLen;
    bool good = (r == kIOReturnSuccess && in.fCompletionStatus == kSCSITaskStatus_GOOD);
    if (good) *data = OSData::withBytes((const void *)d.address, (uint32_t)got);
    else {
        char sh[48]; size_t o = 0;
        for (int i = 0; i < kSenseLen && o + 3 < sizeof sh; i++) o += snprintf(sh + o, sizeof sh - o, "%02x", ((uint8_t *)se.address)[i]);
        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b FEHLER %{public}s ret=0x%x taskstatus=%u svc=%u bytes=%llu sensevalid=%d sense=%{public}s",
               s.name, r, (unsigned)in.fCompletionStatus, (unsigned)in.fServiceResponse, in.fRealizedByteCountOfTransfer, (int)in.fSenseDataValid, sh);
        HexZeilen(s.key, (const uint8_t *)d.address, got);
    }
    return good;
}

void IMPL(MaxWriteProbe, TimerFired)
{
    uint32_t cyc = ivars->cycle++;
    IOBufferMemoryDescriptor *dbuf = nullptr, *sbuf = nullptr;
    if (IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kDataLen, 0, &dbuf) == kIOReturnSuccess &&
        IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kSenseLen, 0, &sbuf) == kIOReturnSuccess) {
        dbuf->SetLength(kDataLen); sbuf->SetLength(kSenseLen);
        IOAddressSegment d = {}, se = {};
        dbuf->GetAddressRange(&d); sbuf->GetAddressRange(&se);
        if (cyc == 0) {   // Rotprobe einmal: verbotener CDB muss VOR dem Senden abgewiesen werden
            OSData *x = nullptr; kern_return_t rr = 0;
            bool sent = Sende(this, kRotprobe, d, se, &x, &rr);
            os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b ROTPROBE=%{public}s ret=0x%x", (!sent && rr == kIOReturnNotPermitted) ? "PASS" : "FAIL", rr);
            OSSafeReleaseNULL(x);
        }
        OSDictionary *st = OSDictionary::withCapacity(kSeitenAnzahl + 3);
        char fehler[256] = {}; size_t fo = 0; int fails = 0;
        for (int i = 0; st && i < kSeitenAnzahl; i++) {
            OSData *x = nullptr; kern_return_t rr = 0;
            if (Sende(this, kSeiten[i], d, se, &x, &rr)) { st->setObject(kSeiten[i].key, x); }
            else { fails++; fo += snprintf(fehler + fo, sizeof fehler - fo, "%s=0x%x ", kSeiten[i].key, rr); }
            OSSafeReleaseNULL(x);
        }
        if (st) {
            OSNumber *z = OSNumber::withNumber(clock_gettime_nsec_np(CLOCK_REALTIME) / 1000000000ull, 64);
            OSString *fs = OSString::withCString(fails ? fehler : "keine");
            if (z) st->setObject("zeit", z);
            if (fs) st->setObject("fehler", fs);
            st->setObject("ok", fails ? kOSBooleanFalse : kOSBooleanTrue);
            OSDictionary *w = OSDictionary::withCapacity(1);
            kern_return_t pr = kIOReturnNoMemory;
            if (w) { w->setObject("DroboStatus", st); pr = SetProperties(w, SUPERDISPATCH); }
            os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b zyklus=%u ok=%d fehlgeschlagen=%d von %d setprops=0x%x", cyc, fails == 0, fails, kSeitenAnzahl, pr);
            OSSafeReleaseNULL(w); OSSafeReleaseNULL(z); OSSafeReleaseNULL(fs);
        }
        OSSafeReleaseNULL(st);
    }
    OSSafeReleaseNULL(dbuf);
    OSSafeReleaseNULL(sbuf);
    ivars->t->WakeAtTime(kIOTimerClockMonotonicRaw, clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + kPeriodNs, 0);
}

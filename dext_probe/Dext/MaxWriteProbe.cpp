#include <DriverKit/DriverKit.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <os/log.h>
#include <stdio.h>
#include <string.h>
#include "MaxWriteProbe.h"

// Stufe 3b: nur Lese-CDBs, harte Allowlist. Kein UserSuspendServices, keine Schreibgroessen-Aenderung.
static constexpr uint32_t kTimeoutMs = 5000;   // begrenzt Hangen (Plan: Timeout 30 s x Retry 20 am Treiber)
static constexpr uint64_t kDataLen   = 255;    // INQUIRY 36, MODE SENSE(10) Alloc-Laenge 255
static constexpr uint8_t  kSenseLen  = 32;

// Allowlist: ausschliesslich INQUIRY (0x12) und MODE SENSE(10) (0x5A).
static bool OpcodeErlaubt(uint8_t op) { return op == 0x12 || op == 0x5A; }

static void Hex(const uint8_t *p, uint64_t n, char *out, size_t cap)
{
    size_t o = 0;
    for (uint64_t i = 0; i < n && o + 3 < cap; i++) o += snprintf(out + o, cap - o, "%02x", p[i]);
    out[o] = 0;
}

bool MaxWriteProbe::init() { return super::init(); }
void MaxWriteProbe::free() { super::free(); }

kern_return_t IMPL(MaxWriteProbe, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b Start ret=0x%x", ret);
    return ret;
}

kern_return_t IMPL(MaxWriteProbe, UserDetermineDeviceCharacteristics)
{
    *result = true;   // Standardverhalten, keine Grenzen gesetzt
    os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b UserDetermineDeviceCharacteristics (keine Aenderung)");
    return kIOReturnSuccess;
}

// cmd 1 = INQUIRY 36 B, cmd 2 = MODE SENSE(10) Seite 0x3F
kern_return_t Senden(IOUserSCSIPeripheralDeviceType00 *self, uint64_t cmd, char *line, size_t cap)
{
    IOBufferMemoryDescriptor *dbuf = nullptr, *sbuf = nullptr;
    kern_return_t r = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kDataLen, 0, &dbuf);
    if (r == kIOReturnSuccess) r = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, kSenseLen, 0, &sbuf);
    if (r != kIOReturnSuccess) { snprintf(line, cap, "cmd=%llu alloc ret=0x%x", cmd, r); goto out; }
    {
        dbuf->SetLength(kDataLen); sbuf->SetLength(kSenseLen);
        IOAddressSegment d = {}, s = {};
        dbuf->GetAddressRange(&d); sbuf->GetAddressRange(&s);
        memset((void *)d.address, 0, kDataLen); memset((void *)s.address, 0, kSenseLen);

        SCSIType00OutParameters out = {};
        SCSIType00InParameters in = {};
        uint64_t len = 0;
        if (cmd == 1) {
            INQUIRY(&out, d.address, &in, s.address);   // Helper fuellt CDB + Richtungen
            len = out.fRequestedByteCountOfTransfer;
        } else if (cmd == 2) {
            INQUIRY(&out, d.address, &in, s.address);   // Richtungen/Felder uebernehmen, CDB danach ersetzen
            memset(out.fCommandDescriptorBlock, 0, sizeof out.fCommandDescriptorBlock);
            out.fCommandDescriptorBlock[0] = 0x5A;
            out.fCommandDescriptorBlock[1] = 0x08;               // DBD
            out.fCommandDescriptorBlock[2] = 0x3F;               // alle Seiten
            out.fCommandDescriptorBlock[7] = (kDataLen >> 8) & 0xFF;
            out.fCommandDescriptorBlock[8] = kDataLen & 0xFF;
            out.fRequestedByteCountOfTransfer = kDataLen;
            len = kDataLen;
        } else { snprintf(line, cap, "cmd=%llu unbekannt", cmd); r = kIOReturnBadArgument; goto out; }
        out.fLogicalUnitNumber = 0;
        out.fTimeoutDuration = kTimeoutMs;
        out.fSenseLengthRequested = kSenseLen;
        out.fSenseBufferAddr = s.address;
        out.fDataBufferAddr = d.address;

        uint8_t op = out.fCommandDescriptorBlock[0];
        if (!OpcodeErlaubt(op)) { snprintf(line, cap, "cmd=%llu opcode=0x%02x ABGELEHNT (Allowlist)", cmd, op); r = kIOReturnNotPermitted; goto out; }

        os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b sende opcode=0x%02x len=%llu bufdir=%u xferdir=%u timeout=%u", op, len, out.fBufferDirection, out.fDataTransferDirection, out.fTimeoutDuration);
        r = self->UserSendCDB(out, &in);
        char dh[96], sh[48];
        uint64_t n = in.fRealizedByteCountOfTransfer < 32 ? in.fRealizedByteCountOfTransfer : 32;
        Hex((const uint8_t *)d.address, n, dh, sizeof dh);
        Hex((const uint8_t *)s.address, 18, sh, sizeof sh);
        snprintf(line, cap, "opcode=0x%02x ret=0x%x taskstatus=%u svc=%u bytes=%llu sensevalid=%d sense=%s data32=%s",
                 op, r, (unsigned)in.fCompletionStatus, (unsigned)in.fServiceResponse,
                 in.fRealizedByteCountOfTransfer, (int)in.fSenseDataValid, sh, dh);
    }
out:
    OSSafeReleaseNULL(dbuf);
    OSSafeReleaseNULL(sbuf);
    return r;
}

kern_return_t IMPL(MaxWriteProbe, NewUserClient)
{
    IOService *client = nullptr;
    kern_return_t r = Create(this, "UserClientProperties", &client);
    if (r != kIOReturnSuccess) return r;
    *userClient = OSDynamicCast(IOUserClient, client);
    if (!*userClient) { OSSafeReleaseNULL(client); return kIOReturnError; }
    return kIOReturnSuccess;
}


#include <DriverKit/DriverKit.h>
#include <os/log.h>
#include <string.h>
#include <SCSIPeripheralsDriverKit/IOUserSCSIPeripheralDeviceType00.h>
#include "ProbeUserClient.h"

kern_return_t Senden(IOUserSCSIPeripheralDeviceType00 *self, uint64_t cmd, char *line, size_t cap);

struct ProbeUserClient_IVars { IOUserSCSIPeripheralDeviceType00 *drv; };

bool ProbeUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(ProbeUserClient_IVars, 1);
    return ivars != nullptr;
}
void ProbeUserClient::free() { IOSafeDeleteNULL(ivars, ProbeUserClient_IVars, 1); super::free(); }

kern_return_t IMPL(ProbeUserClient, Start)
{
    kern_return_t r = Start(provider, SUPERDISPATCH);
    if (r != kIOReturnSuccess) return r;
    ivars->drv = OSDynamicCast(IOUserSCSIPeripheralDeviceType00, provider);
    os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b UserClient Start drv=%d", ivars->drv != nullptr);
    return ivars->drv ? kIOReturnSuccess : kIOReturnError;
}


kern_return_t ProbeUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments *arguments,
                                              const IOUserClientMethodDispatch *, OSObject *, void *)
{
    if (selector != 0 || !arguments || arguments->scalarInputCount < 1) return kIOReturnBadArgument;
    char line[320] = {};
    kern_return_t r = Senden(ivars->drv, arguments->scalarInput[0], line, sizeof line);
    os_log(OS_LOG_DEFAULT, "MaxWriteProbe: 3b ERGEBNIS %{public}s", line);
    arguments->structureOutput = OSData::withBytes(line, (uint32_t)strlen(line) + 1);
    return r;
}

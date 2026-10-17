#include <os/log.h>
#include <DriverKit/DriverKit.h>
#include "BlockbrueckeWurzel.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "Blockbruecke: " fmt, ##__VA_ARGS__)

struct BlockbrueckeWurzel_IVars { IOService *controller; };

bool BlockbrueckeWurzel::init()
{
    LOG("Wurzel init");   // Messpunkt: Dext-Objekt wurde ueberhaupt instanziiert
    if (!super::init()) return false;
    ivars = IONewZero(BlockbrueckeWurzel_IVars, 1);
    return ivars != nullptr;
}
void BlockbrueckeWurzel::free()
{
    if (ivars) { OSSafeReleaseNULL(ivars->controller); IOSafeDeleteNULL(ivars, BlockbrueckeWurzel_IVars, 1); }
    super::free();
}

kern_return_t IMPL(BlockbrueckeWurzel, Start)
{
    kern_return_t r = Start(provider, SUPERDISPATCH);
    LOG("Wurzel Start ret=0x%x", r);
    if (r != kIOReturnSuccess) return r;
    r = Create(this, "BlockbrueckeController", &ivars->controller);   // Personality-Unterschluessel in Info.plist
    LOG("Wurzel Create(Controller) ret=0x%x", r);   // Messpunkt: ret=0x0 = Kernel hat den SCSI-Controller angelegt
    if (r != kIOReturnSuccess) return r;
    return RegisterService();
}

kern_return_t IMPL(BlockbrueckeWurzel, Stop)
{
    LOG("Wurzel Stop");
    if (ivars->controller) ivars->controller->Terminate(0);
    OSSafeReleaseNULL(ivars->controller);
    return Stop(provider, SUPERDISPATCH);
}


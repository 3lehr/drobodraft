#include <os/log.h>
#include <DriverKit/DriverKit.h>
#include "BlockbrueckeWurzel.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "Blockbruecke: " fmt, ##__VA_ARGS__)

kern_return_t IMPL(BlockbrueckeWurzel, Start)
{
    kern_return_t r = Start(provider, SUPERDISPATCH);
    LOG("Wurzel Start ret=0x%x", r);
    if (r != kIOReturnSuccess) return r;
    // Matching starts the family kernel class; Create() would skip its kernel start.
    r = RegisterService();
    LOG("Wurzel RegisterService ret=0x%x", r);
    return r;
}

kern_return_t IMPL(BlockbrueckeWurzel, Stop)
{
    LOG("Wurzel Stop");
    kern_return_t r = Stop(provider, SUPERDISPATCH);
    LOG("Wurzel Stop ret=0x%x", r);
    return r;
}

#include <os/log.h>
#include <DriverKit/DriverKit.h>
#include "Blockbruecke.h"

// Schritt 1: nur Start + Log. Kein Target, keine Daten, kein Netz. Jeder SCSI-Befehl -> abgelehnt (darf nie ankommen, es gibt kein Target).
#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "Blockbruecke: " fmt, ##__VA_ARGS__)

bool Blockbruecke::init()
{
    LOG("Controller init");
    return super::init();
}

kern_return_t IMPL(Blockbruecke, Start)
{
    kern_return_t r = Start(provider, SUPERDISPATCH);
    LOG("Start ret=0x%x", r);   // Messpunkt Schritt 1: ret=0x0 = Controller laeuft ohne Hardware-Provider
    if (r == kIOReturnSuccess) r = RegisterService();
    return r;
}

// Doku IOService::Stop: Aktivitaet beenden, super am Ende. Kein laufender Auftrag (kein Target) -> direkt super.
kern_return_t IMPL(Blockbruecke, Stop)
{
    LOG("Controller Stop");
    kern_return_t r = Stop(provider, SUPERDISPATCH);
    LOG("Controller Stop ret=0x%x", r);
    return r;
}

kern_return_t IMPL(Blockbruecke, UserInitializeController) { LOG("UserInitializeController"); return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserStartController)      { LOG("UserStartController");      return kIOReturnSuccess; }

kern_return_t IMPL(Blockbruecke, UserReportHBAHighestLogicalUnitNumber) { *value = 0; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserDoesHBASupportSCSIParallelFeature) { *result = false; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserInitializeTargetForID)             { return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserDoesHBAPerformAutoSense)           { *result = true; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserDoesHBASupportMultiPathing)        { *result = false; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserReportInitiatorIdentifier)         { *id = 7; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserReportHighestSupportedDeviceID)    { *id = 0; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserReportMaximumTaskCount)            { *count = 1; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserDoesHBAPerformDeviceManagement)    { *result = true; return kIOReturnSuccess; }  // wir legen Targets selbst an (ab Schritt 2)

// Task-Management: nichts offen -> "Funktion abgeschlossen".
kern_return_t IMPL(Blockbruecke, UserAbortTaskRequest)        { *response = kSCSIServiceResponse_FUNCTION_COMPLETE; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserAbortTaskSetRequest)     { *response = kSCSIServiceResponse_FUNCTION_COMPLETE; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserClearACARequest)         { *response = kSCSIServiceResponse_FUNCTION_COMPLETE; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserClearTaskSetRequest)     { *response = kSCSIServiceResponse_FUNCTION_COMPLETE; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserLogicalUnitResetRequest) { *response = kSCSIServiceResponse_FUNCTION_COMPLETE; return kIOReturnSuccess; }
kern_return_t IMPL(Blockbruecke, UserTargetResetRequest)      { *response = kSCSIServiceResponse_FUNCTION_COMPLETE; return kIOReturnSuccess; }

kern_return_t IMPL(Blockbruecke, UserProcessParallelTask)
{
    LOG("UserProcessParallelTask unerwartet (kein Target) op=0x%02x", parallelRequest.fCommandDescriptorBlock[0]);
    *response = kSCSIServiceResponse_SERVICE_DELIVERY_OR_TARGET_FAILURE;
    return kIOReturnUnsupported;
}

kern_return_t IMPL(Blockbruecke, UserGetDMASpecification)
{
    *maxTransferSize = 524288;   // = MaxBurstLength DroboPro (docs/PLAN_DROBOPRO_ISCSI_2026-10-16.md), Apple teilt groessere I/Os
    *alignment = 4096;
    *numAddressBits = 64;
    *segmentType = kDMAOutputSegmentHost64;
    return kIOReturnSuccess;
}

kern_return_t IMPL(Blockbruecke, UserMapHBAData) { return kIOReturnUnsupported; }
kern_return_t IMPL(Blockbruecke, UserMapBundledParallelTaskCommandAndResponseBuffers) { return kIOReturnUnsupported; }  // Header: dann Einzelpfad
void IMPL(Blockbruecke, UserProcessBundledParallelTasks) { LOG("Bundled unerwartet"); }

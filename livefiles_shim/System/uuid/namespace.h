/* Ersatz fuer <System/uuid/namespace.h>: Apples feste Namespace-UUID fuer HFS-Volume-UUIDs (B3E20F39-F292-11D6-97A4-00306543ECAC). */
#ifndef SHIM_UUID_NAMESPACE_H
#define SHIM_UUID_NAMESPACE_H
#include <uuid/uuid.h>
static const uuid_t kFSUUIDNamespaceSHA1 = {0xB3,0xE2,0x0F,0x39,0xF2,0x92,0x11,0xD6,0x97,0xA4,0x00,0x30,0x65,0x43,0xEC,0xAC};
#endif

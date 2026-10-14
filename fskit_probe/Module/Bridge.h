// Bridging-Header: Apples livefiles_hfs (statische Lib aus macos/Makefile) + eigene Glue-Schicht.
#include <UserFS/UserVFS.h>
#include "lifs_devio.h"
#include "lifs_glue.h"

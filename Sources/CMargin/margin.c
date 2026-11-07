#include "CMargin.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>

_Static_assert(sizeof(MRTouch) == 96, "MRTouch must match the framework's 96-byte record");

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MRTouch *, int, double, int);

static CFArrayRef (*pCreateList)(void);
static void (*pRegister)(MTDeviceRef, MTContactCallback);
static void (*pUnregister)(MTDeviceRef, MTContactCallback);
static int (*pStart)(MTDeviceRef, int);
static int (*pStopDevice)(MTDeviceRef);
static bool (*pIsBuiltIn)(MTDeviceRef);
static int (*pGetDeviceID)(MTDeviceRef, uint64_t *);
static CFTypeRef (*pActuatorCreate)(uint64_t);
static int (*pActuatorOpen)(CFTypeRef);
static int (*pActuatorActuate)(CFTypeRef, int32_t, uint32_t, float, float);
static int (*pGetBrightness)(uint32_t, float *);
static int (*pSetBrightness)(uint32_t, float);

static CFArrayRef gDevices;
static CFTypeRef gActuator;
static MRFrameHandler gHandler;
static void *gContext;

#define BIND(handle, slot, name) (*(void **)&(slot) = dlsym(handle, name))

bool MRLoad(void) {
    if (pCreateList) return true;
    void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!mt) return false;
    BIND(mt, pRegister, "MTRegisterContactFrameCallback");
    BIND(mt, pUnregister, "MTUnregisterContactFrameCallback");
    BIND(mt, pStart, "MTDeviceStart");
    BIND(mt, pStopDevice, "MTDeviceStop");
    BIND(mt, pIsBuiltIn, "MTDeviceIsBuiltIn");
    BIND(mt, pGetDeviceID, "MTDeviceGetDeviceID");
    BIND(mt, pActuatorCreate, "MTActuatorCreateFromDeviceID");
    BIND(mt, pActuatorOpen, "MTActuatorOpen");
    BIND(mt, pActuatorActuate, "MTActuatorActuate");
    void *ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
    if (ds) {
        BIND(ds, pGetBrightness, "DisplayServicesGetBrightness");
        BIND(ds, pSetBrightness, "DisplayServicesSetBrightness");
    }
    if (!pRegister || !pUnregister || !pStart || !pStopDevice) return false;
    BIND(mt, pCreateList, "MTDeviceCreateList");
    return pCreateList != NULL;
}

static int trampoline(MTDeviceRef device, MRTouch *touches, int count, double timestamp, int frame) {
    (void)frame;
    if (gHandler) gHandler((uintptr_t)device, touches, count, timestamp, gContext);
    return 0;
}

static void openActuator(MTDeviceRef device) {
    if (gActuator || !pGetDeviceID || !pActuatorCreate || !pActuatorOpen || !pActuatorActuate) return;
    uint64_t identifier = 0;
    if (pGetDeviceID(device, &identifier) != 0) return;
    CFTypeRef actuator = pActuatorCreate(identifier);
    if (!actuator) return;
    if (pActuatorOpen(actuator) == 0) gActuator = actuator;
    else CFRelease(actuator);
}

int32_t MRStart(MRFrameHandler handler, void *context) {
    if (!MRLoad()) return -1;
    MRStop();
    gHandler = handler;
    gContext = context;
    gDevices = pCreateList();
    if (!gDevices) return -1;
    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        pRegister(device, trampoline);
        pStart(device, 0);
        if (pIsBuiltIn && pIsBuiltIn(device)) openActuator(device);
    }
    return (int32_t)count;
}

void MRStop(void) {
    if (!gDevices) return;
    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        pUnregister(device, trampoline);
        pStopDevice(device);
    }
    CFRelease(gDevices);
    gDevices = NULL;
}

bool MRHaptic(int32_t actuation) {
    return gActuator && pActuatorActuate(gActuator, actuation, 0, 0, 0) == 0;
}

bool MRGetBrightness(uint32_t display, float *value) {
    return pGetBrightness && pGetBrightness(display, value) == 0;
}

bool MRSetBrightness(uint32_t display, float value) {
    return pSetBrightness && pSetBrightness(display, value) == 0;
}

int32_t MRSpawn(const char *path, char *const argv[], char *const envp[]) {
    // Without this macOS treats the child as part of Margin, and it would run
    // with Margin's Accessibility permission. Refuses rather than lend it out.
    int (*disclaim)(posix_spawnattr_t *, int);
    *(void **)&disclaim = dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (!disclaim) return -1;

    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t files;
    if (posix_spawnattr_init(&attributes) != 0) return -1;
    if (posix_spawn_file_actions_init(&files) != 0) {
        posix_spawnattr_destroy(&attributes);
        return -1;
    }

    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    pid_t pid = -1;
    int failed = disclaim(&attributes, 1)
        || posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        || posix_spawnattr_setsigmask(&attributes, &none)
        || posix_spawnattr_setsigdefault(&attributes, &all)
        || posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
        || posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0)
        || posix_spawn_file_actions_addopen(&files, 2, "/dev/null", O_WRONLY, 0)
        || posix_spawn(&pid, path, &files, &attributes, argv, envp);

    posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attributes);
    return failed ? -1 : pid;
}

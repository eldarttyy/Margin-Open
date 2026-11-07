#ifndef CMARGIN_H
#define CMARGIN_H

#include <stdbool.h>
#include <stdint.h>

// Layout of MultitouchSupport's contact record. Private and undocumented, so
// the size is asserted in margin.c and sanity-checked by `Margin --diagnose`.
typedef struct { float x, y; } MRPoint;
typedef struct { MRPoint position, velocity; } MRVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    MRVector normalized;   // 0...1, origin at the bottom-left of the pad
    float size;
    int32_t zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MRVector absolute;
    int32_t zero2;
    int32_t zero3;
    float density;
} MRTouch;

typedef void (*MRFrameHandler)(uintptr_t device, const MRTouch *touches, int32_t count, double timestamp, void *context);

// Loads the frameworks. False means a symbol Margin needs has gone away.
bool MRLoad(void);

// Starts every multitouch device. Returns the device count, or -1 on failure.
int32_t MRStart(MRFrameHandler handler, void *context);
void MRStop(void);

// Plays a trackpad click on the built-in device. Actuation 1...6, weakest first.
bool MRHaptic(int32_t actuation);

// Display brightness, 0...1. Returns false when the display has no such control.
bool MRGetBrightness(uint32_t display, float *value);
bool MRSetBrightness(uint32_t display, float value);

// Starts a program that takes none of Margin's permissions with it: macOS holds
// it to its own, it gets no open files, and output goes to /dev/null. `argv` and
// `envp` are NULL-terminated. Returns its pid, or -1 if it couldn't be started.
int32_t MRSpawn(const char *path, char *const argv[], char *const envp[]);

#endif

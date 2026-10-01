#ifndef MOUSE_FIX_HID_BRIDGE_H
#define MOUSE_FIX_HID_BRIDGE_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

/// Returns the IOKit registry ID of the physical HID sender for a Quartz event.
/// Returns zero when the private bridge is unavailable or the event is synthetic.
uint64_t MouseFixCopyEventSenderID(CGEventRef event);

#endif

#include "MouseFixHIDBridge.h"

#include <CoreFoundation/CoreFoundation.h>

extern CFTypeRef CGEventCopyIOHIDEvent(CGEventRef event) __attribute__((weak_import));
extern uint64_t IOHIDEventGetSenderID(CFTypeRef event) __attribute__((weak_import));

uint64_t MouseFixCopyEventSenderID(CGEventRef event) {
    if (event == NULL || CGEventCopyIOHIDEvent == NULL || IOHIDEventGetSenderID == NULL) {
        return 0;
    }

    CFTypeRef hidEvent = CGEventCopyIOHIDEvent(event);
    if (hidEvent == NULL) {
        return 0;
    }

    uint64_t senderID = IOHIDEventGetSenderID(hidEvent);
    CFRelease(hidEvent);
    return senderID;
}

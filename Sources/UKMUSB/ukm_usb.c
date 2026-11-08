#include "ukm_usb.h"

#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

struct ukm_usb_device {
    IOUSBDeviceInterface650 **interface;
};

ukm_usb_device *ukm_usb_open(uint32_t service, int32_t *error) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        if (error) *error = kr != KERN_SUCCESS ? kr : kIOReturnNoResources;
        return NULL;
    }
    IOUSBDeviceInterface650 **interface = NULL;
    HRESULT result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650),
                                               (LPVOID *)&interface);
    IODestroyPlugInInterface(plugin);
    if (result != S_OK || interface == NULL) {
        if (error) *error = kIOReturnUnsupported;
        return NULL;
    }
    ukm_usb_device *device = malloc(sizeof *device);
    if (device == NULL) {
        (*interface)->Release(interface);
        if (error) *error = kIOReturnNoMemory;
        return NULL;
    }
    device->interface = interface;
    if (error) *error = 0;
    return device;
}

void ukm_usb_close(ukm_usb_device *device) {
    if (device == NULL) return;
    (*device->interface)->Release(device->interface);
    free(device);
}

int32_t ukm_usb_control(ukm_usb_device *device, uint8_t request_type, uint8_t request,
                        uint16_t value, uint16_t index, void *data, uint16_t length,
                        uint32_t timeout_ms, uint32_t *transferred) {
    IOUSBDevRequestTO req = {
        .bmRequestType = request_type,
        .bRequest = request,
        .wValue = value,
        .wIndex = index,
        .wLength = length,
        .pData = data,
        .wLenDone = 0,
        .noDataTimeout = timeout_ms,
        .completionTimeout = timeout_ms,
    };
    IOReturn kr = (*device->interface)->DeviceRequestTO(device->interface, &req);
    if (transferred) *transferred = req.wLenDone;
    return kr;
}

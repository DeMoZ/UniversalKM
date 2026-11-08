// Control requests to a USB device through IOKit's device user client (design D2).
// Swift cannot use the IOKit plug-in UUID macros, so this small C module wraps them.
#ifndef UKM_USB_H
#define UKM_USB_H

#include <stdint.h>

typedef struct ukm_usb_device ukm_usb_device;

/// Opens the device user client for an IOUSBHostDevice service (io_service_t). The device itself is
/// not opened (USBDeviceOpen): control requests on endpoint 0 work while the system driver holds it.
/// Returns NULL on failure; `error` gets the IOReturn.
ukm_usb_device *ukm_usb_open(uint32_t service, int32_t *error);

void ukm_usb_close(ukm_usb_device *device);

/// One control transfer. Returns an IOReturn (0 = success); `transferred` gets the byte count.
int32_t ukm_usb_control(ukm_usb_device *device, uint8_t request_type, uint8_t request,
                        uint16_t value, uint16_t index, void *data, uint16_t length,
                        uint32_t timeout_ms, uint32_t *transferred);

#endif

// AOA2 HID probe through IOKit (task 1.1/1.2): finds the first Android-looking USB device by vendor ID,
// asks its AOA protocol, registers the composite keyboard + mouse and moves the cursor / types.
// Build: clang -O2 scripts/aoa-probe.c Sources/UKMUSB/ukm_usb.c -ISources/UKMUSB/include \
//        -framework IOKit -framework CoreFoundation -o build/aoa-probe
// Usage: build/aoa-probe <vendor-hex> [square|type TEXT|scroll|probe]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include "ukm_usb.h"

static const uint8_t report_map[] = {
    // HIDReportDescriptor.reportMap (keyboard ID 1 + mouse ID 2)
    5, 1, 9, 6, 161, 1, 133, 1, 5, 7, 25, 224, 41, 231, 21, 0, 37, 1, 117, 1, 149, 8, 129, 2, 149, 1, 117, 8, 129, 1, 149, 5, 117, 1, 5, 8, 25, 1, 41, 5, 145, 2, 149, 1, 117, 3, 145, 1, 149, 6, 117, 8, 21, 0, 37, 101, 5, 7, 25, 0, 41, 101, 129, 0, 192, 5, 1, 9, 2, 161, 1, 133, 2, 9, 1, 161, 0, 5, 9, 25, 1, 41, 5, 21, 0, 37, 1, 149, 5, 117, 1, 129, 2, 149, 1, 117, 3, 129, 1, 5, 1, 9, 48, 9, 49, 22, 1, 128, 38, 255, 127, 117, 16, 149, 2, 129, 6, 9, 56, 21, 129, 37, 127, 117, 8, 149, 1, 129, 6, 5, 12, 10, 56, 2, 149, 1, 129, 6, 192, 192
};
static ukm_usb_device *dev;

static int out(uint8_t req, uint16_t value, uint16_t index, const void *data, uint16_t len) {
    uint32_t done = 0;
    int32_t kr = ukm_usb_control(dev, 0x40, req, value, index, (void *)data, len, 1000, &done);
    if (kr) fprintf(stderr, "request %u failed: 0x%x\n", req, kr);
    return kr;
}
static void event(const uint8_t *bytes, uint16_t len) { out(57, 1, 0, bytes, len); }
static void mouse(int dx, int dy, int wheel) {
    uint8_t e[8] = {2, 0, dx & 0xFF, (dx >> 8) & 0xFF, dy & 0xFF, (dy >> 8) & 0xFF, wheel & 0xFF, 0};
    event(e, sizeof e);
}
static void key(uint8_t mod, uint8_t code) {
    uint8_t e[9] = {1, mod, 0, code, 0, 0, 0, 0, 0};
    event(e, 9); usleep(20000);
    memset(e + 1, 0, 8); event(e, 9); usleep(20000);
}
static uint8_t usage(char c, uint8_t *mod) {
    *mod = 0;
    if (c >= 'a' && c <= 'z') return 4 + (c - 'a');
    if (c >= 'A' && c <= 'Z') { *mod = 2; return 4 + (c - 'A'); }
    if (c >= '1' && c <= '9') return 30 + (c - '1');
    if (c == '0') return 39;
    if (c == ' ') return 44;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <vendor-hex> [square|type TEXT|scroll|probe]\n", argv[0]); return 2; }
    long vendor = strtol(argv[1], NULL, 16);
    const char *mode = argc > 2 ? argv[2] : "square";
    io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it);
    io_service_t service, found = 0;
    while ((service = IOIteratorNext(it))) {
        CFNumberRef v = IORegistryEntryCreateCFProperty(service, CFSTR("idVendor"), NULL, 0);
        int vid = 0;
        if (v) { CFNumberGetValue(v, kCFNumberIntType, &vid); CFRelease(v); }
        if (vid == vendor && !found) found = service; else IOObjectRelease(service);
    }
    IOObjectRelease(it);
    if (!found) { fprintf(stderr, "no device with vendor %04lx\n", vendor); return 1; }
    int32_t err = 0;
    dev = ukm_usb_open(found, &err);
    if (!dev) { fprintf(stderr, "open failed: 0x%x\n", err); return 1; }
    uint8_t p[2] = {0};
    uint32_t done = 0;
    int32_t kr = ukm_usb_control(dev, 0xC0, 51, 0, 0, p, 2, 1000, &done);
    printf("GET_PROTOCOL kr=0x%x len=%u version=%d\n", kr, done, p[0] | p[1] << 8);
    if (kr || !strcmp(mode, "probe")) goto done;
    out(55, 1, 0, NULL, 0);
    if (out(54, 1, sizeof report_map, NULL, 0) || out(56, 1, 0, report_map, sizeof report_map)) goto done;
    printf("registered composite HID (%zu bytes)\n", sizeof report_map);
    sleep(1);
    if (!strcmp(mode, "square")) {
        for (int r = 0; r < 3; r++) {
            for (int i = 0; i < 30; i++) { mouse(10, 0, 0); usleep(8000); }
            for (int i = 0; i < 30; i++) { mouse(0, 10, 0); usleep(8000); }
            for (int i = 0; i < 30; i++) { mouse(-10, 0, 0); usleep(8000); }
            for (int i = 0; i < 30; i++) { mouse(0, -10, 0); usleep(8000); }
        }
    } else if (!strcmp(mode, "scroll")) {
        for (int i = 0; i < 10; i++) { mouse(0, 0, -1); usleep(100000); }
        for (int i = 0; i < 10; i++) { mouse(0, 0, 1); usleep(100000); }
    } else if (!strcmp(mode, "type") && argc > 3) {
        for (const char *s = argv[3]; *s; s++) { uint8_t m, c = usage(*s, &m); if (c) key(m, c); }
    }
    sleep(1);
    printf("unregister kr=0x%x\n", out(55, 1, 0, NULL, 0));
done:
    ukm_usb_close(dev);
    IOObjectRelease(found);
    return 0;
}

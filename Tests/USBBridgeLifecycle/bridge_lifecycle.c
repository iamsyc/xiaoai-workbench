// Compile against USBBridge.c with these libusb doubles, never against real USB devices.
#include "USBBridge.h"
#include <libusb.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int initializations, exits, closes, releases, available, claim_result;
static int bulk_result, bulk_transferred;
static int context_token, device_token, handle_token;
static libusb_device *devices[2];
static const struct libusb_endpoint_descriptor endpoints[] = {
    {.bEndpointAddress = 0x81, .bmAttributes = LIBUSB_TRANSFER_TYPE_BULK},
    {.bEndpointAddress = 0x02, .bmAttributes = LIBUSB_TRANSFER_TYPE_BULK}
};
static const struct libusb_interface_descriptor alternate = {
    .bInterfaceNumber = 0, .bNumEndpoints = 2, .endpoint = endpoints
};
static const struct libusb_interface interface = {.altsetting = &alternate, .num_altsetting = 1};
static struct libusb_config_descriptor config = {.bNumInterfaces = 1, .interface = &interface};

int libusb_init(libusb_context **context) { initializations++; *context = (void *)&context_token; return 0; }
void libusb_exit(libusb_context *context) { assert(context == (void *)&context_token); exits++; }
ssize_t libusb_get_device_list(libusb_context *context, libusb_device ***list) {
    assert(context == (void *)&context_token && exits == 0);
    devices[0] = (void *)&device_token; devices[1] = NULL; *list = devices; return available;
}
void libusb_free_device_list(libusb_device **list, int unref) { (void)list; assert(unref == 1); }
int libusb_get_device_descriptor(libusb_device *device, struct libusb_device_descriptor *desc) {
    (void)device; memset(desc, 0, sizeof(*desc)); desc->idVendor = 0x1b8e; desc->idProduct = 0xc003; return 0;
}
int libusb_open(libusb_device *device, libusb_device_handle **handle) {
    (void)device; *handle = (void *)&handle_token; return 0;
}
void libusb_close(libusb_device_handle *handle) { (void)handle; closes++; }
int libusb_get_active_config_descriptor(libusb_device *device, struct libusb_config_descriptor **out) {
    (void)device; *out = &config; return 0;
}
void libusb_free_config_descriptor(struct libusb_config_descriptor *descriptor) { (void)descriptor; }
int libusb_claim_interface(libusb_device_handle *handle, int interface_number) {
    (void)handle; assert(interface_number == 0); return claim_result;
}
int libusb_release_interface(libusb_device_handle *handle, int interface_number) {
    (void)handle; assert(interface_number == 0); releases++; return 0;
}
int libusb_control_transfer(libusb_device_handle *h, uint8_t t, uint8_t r, uint16_t v,
                           uint16_t i, unsigned char *d, uint16_t l, unsigned int timeout) {
    (void)h; (void)t; (void)r; (void)v; (void)i; (void)d; (void)l; (void)timeout;
    assert(!"No control transfers expected in lifecycle test"); return -1;
}
int libusb_bulk_transfer(libusb_device_handle *h, unsigned char ep, unsigned char *d,
                        int l, int *n, unsigned int timeout) {
    (void)h; (void)ep; (void)d; (void)l; (void)timeout;
    *n = bulk_transferred; return bulk_result;
}
const char *libusb_error_name(int error) { (void)error; return "test"; }

int main(void) {
    int error = 0; const char *stage = NULL;
    xw_context *context = xw_context_create(NULL, NULL, &error, &stage);
    assert(context && initializations == 1 && error == 0);
    for (int i = 0; i < 10; i++) {
        assert(xw_open(context, &error, &stage) == NULL);
        assert(error == LIBUSB_ERROR_NO_DEVICE && strcmp(stage, "enumerate") == 0);
        assert(initializations == 1 && exits == 0);
    }
    available = 1;
    xw_usb *usb = xw_open(context, &error, &stage);
    assert(usb && error == 0 && strcmp(stage, "ready") == 0);
    assert(xw_endpoint_in(usb) == 0x81 && xw_endpoint_out(usb) == 0x02);
    unsigned char bytes[32]; int transferred = -1;
    bulk_result = LIBUSB_ERROR_IO; bulk_transferred = 12;
    assert(xw_bulk(usb, 0x81, bytes, 32, 10000, &transferred) == LIBUSB_ERROR_IO);
    assert(transferred == 12);
    bulk_result = 0; bulk_transferred = 32;
    assert(xw_bulk(usb, 0x81, bytes, 32, 10000, &transferred) == 0 && transferred == 32);
    xw_close(usb);
    assert(closes == 1 && releases == 1 && exits == 0);
    claim_result = LIBUSB_ERROR_BUSY;
    assert(xw_open(context, &error, &stage) == NULL);
    assert(error == LIBUSB_ERROR_BUSY && strcmp(stage, "claim") == 0);
    assert(closes == 2 && releases == 1 && exits == 0);
    xw_context_destroy(context);
    assert(initializations == 1 && exits == 1);
    puts("PASS: one context survives missing-device retries, handle close and claim failure; one final exit");
    puts("PASS: bulk errors preserve their actual transferred byte count");
}

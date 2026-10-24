#include "USBBridge.h"
#include <libusb.h>
#include <stdlib.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

struct xw_context {
    libusb_context *usb;
    IONotificationPortRef notifications;
    dispatch_queue_t queue;
    io_iterator_t arrivals, removals;
    xw_event_callback callback;
    void *user;
};

static uint32_t property_number(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int64_t result = 0;
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &result);
        CFRelease(value);
    }
    return (uint32_t)result;
}
static void drain_events(xw_context *context, io_iterator_t iterator, const char *event) {
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        uint64_t registry_id = 0;
        IORegistryEntryGetRegistryEntryID(service, &registry_id);
        context->callback(event, registry_id, (uint16_t)property_number(service, CFSTR("idVendor")),
                          (uint16_t)property_number(service, CFSTR("idProduct")),
                          property_number(service, CFSTR("locationID")), context->user);
        IOObjectRelease(service);
    }
}
static void arrived(void *user, io_iterator_t iterator) { drain_events(user, iterator, "arrived"); }
static void removed(void *user, io_iterator_t iterator) { drain_events(user, iterator, "removed"); }
static void queue_barrier(void *unused) { (void)unused; }

xw_context *xw_context_create(xw_event_callback callback, void *user, int *error, const char **stage) {
    *stage = "initialize";
    xw_context *context = calloc(1, sizeof(*context));
    if (!context) { *error = LIBUSB_ERROR_NO_MEM; return NULL; }
    *error = libusb_init(&context->usb);
    if (*error < 0) { free(context); return NULL; }
    context->callback = callback; context->user = user;
    if (callback) {
        *stage = "notifications";
        context->notifications = IONotificationPortCreate(kIOMainPortDefault);
        context->queue = dispatch_queue_create("local.xiaoai.usb-events", DISPATCH_QUEUE_SERIAL);
        if (!context->notifications || !context->queue) {
            *error = LIBUSB_ERROR_OTHER; xw_context_destroy(context); return NULL;
        }
        // Register and drain before scheduling, so callbacks cannot race the initial drain.
        kern_return_t status = IOServiceAddMatchingNotification(context->notifications, kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"), arrived, context, &context->arrivals);
        if (status == KERN_SUCCESS) {
            drain_events(context, context->arrivals, "present");
            status = IOServiceAddMatchingNotification(context->notifications, kIOTerminatedNotification,
                IOServiceMatching("IOUSBHostDevice"), removed, context, &context->removals);
        }
        if (status != KERN_SUCCESS) {
            *error = LIBUSB_ERROR_OTHER; xw_context_destroy(context); return NULL;
        }
        drain_events(context, context->removals, "removed");
        IONotificationPortSetDispatchQueue(context->notifications, context->queue);
    }
    *stage = "ready";
    return context;
}

void xw_context_destroy(xw_context *context) {
    if (!context) return;
    if (context->notifications) {
        IONotificationPortSetDispatchQueue(context->notifications, NULL);
        if (context->queue) dispatch_sync_f(context->queue, NULL, queue_barrier);
        IONotificationPortDestroy(context->notifications);
    }
    if (context->arrivals) IOObjectRelease(context->arrivals);
    if (context->removals) IOObjectRelease(context->removals);
    if (context->queue) dispatch_release(context->queue);
    if (context->usb) libusb_exit(context->usb);
    free(context);
}

struct xw_usb {
    libusb_device_handle *handle;
    uint8_t input, output;
    int claimed;
};

xw_usb *xw_open(xw_context *context, int *error, const char **stage) {
    *stage = "enumerate";
    xw_usb *usb = calloc(1, sizeof(*usb));
    if (!usb) { *error = LIBUSB_ERROR_NO_MEM; return NULL; }
    *error = 0;
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(context->usb, &devices);
    if (count < 0) { *error = (int)count; xw_close(usb); return NULL; }
    libusb_device *selected = NULL;
    int matches = 0;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor descriptor;
        if (libusb_get_device_descriptor(devices[i], &descriptor) == 0 &&
            descriptor.idVendor == 0x1b8e && descriptor.idProduct == 0xc003) {
            matches++;
            selected = devices[i];
        }
    }
    if (matches != 1) {
        *error = matches == 0 ? LIBUSB_ERROR_NO_DEVICE : LIBUSB_ERROR_BUSY;
        libusb_free_device_list(devices, 1); xw_close(usb); return NULL;
    }
    *stage = "open";
    *error = libusb_open(selected, &usb->handle);
    if (*error == 0) {
        *stage = "configuration";
        struct libusb_config_descriptor *config = NULL;
        *error = libusb_get_active_config_descriptor(selected, &config);
        if (*error == 0) {
            if (config->bNumInterfaces == 0 || config->interface[0].num_altsetting == 0) {
                *error = LIBUSB_ERROR_NOT_FOUND;
            } else {
                *stage = "endpoints";
                const struct libusb_interface_descriptor *interface = &config->interface[0].altsetting[0];
                if (interface->bInterfaceNumber != 0) *error = LIBUSB_ERROR_NOT_SUPPORTED;
                for (int i = 0; i < interface->bNumEndpoints; i++) {
                    const struct libusb_endpoint_descriptor *ep = &interface->endpoint[i];
                    if ((ep->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) continue;
                    if (ep->bEndpointAddress & LIBUSB_ENDPOINT_IN) usb->input = ep->bEndpointAddress;
                    else usb->output = ep->bEndpointAddress;
                }
                if (!usb->input || !usb->output) *error = LIBUSB_ERROR_NOT_FOUND;
            }
            libusb_free_config_descriptor(config);
        }
    }
    libusb_free_device_list(devices, 1);
    if (*error == 0) {
        *stage = "claim";
        *error = libusb_claim_interface(usb->handle, 0);
        usb->claimed = *error == 0;
    }
    if (*error < 0) { xw_close(usb); return NULL; }
    *stage = "ready";
    return usb;
}

void xw_close(xw_usb *usb) {
    if (!usb) return;
    if (usb->claimed) libusb_release_interface(usb->handle, 0);
    if (usb->handle) libusb_close(usb->handle);
    free(usb);
}
int xw_control(xw_usb *usb, uint8_t type, uint8_t request, uint16_t value,
               uint16_t index, uint8_t *data, uint16_t length, unsigned timeout) {
    return libusb_control_transfer(usb->handle, type, request, value, index, data, length, timeout);
}
int xw_bulk(xw_usb *usb, uint8_t ep, uint8_t *data, int length, unsigned timeout, int *transferred) {
    *transferred = 0;
    return libusb_bulk_transfer(usb->handle, ep, data, length, transferred, timeout);
}
const char *xw_error(int code) { return libusb_error_name(code); }
uint8_t xw_endpoint_in(xw_usb *usb) { return usb->input; }
uint8_t xw_endpoint_out(xw_usb *usb) { return usb->output; }

#include <stdint.h>
typedef struct xw_usb xw_usb;
typedef struct xw_context xw_context;
typedef void (*xw_event_callback)(const char *event, uint64_t registry_id,
                                uint16_t vendor, uint16_t product, uint32_t location, void *user);
xw_context *xw_context_create(xw_event_callback callback, void *user, int *error, const char **stage);
void xw_context_destroy(xw_context *context);
xw_usb *xw_open(xw_context *context, int *error, const char **stage);
void xw_close(xw_usb *usb);
int xw_control(xw_usb *usb, uint8_t type, uint8_t request, uint16_t value,
               uint16_t index, uint8_t *data, uint16_t length, unsigned timeout);
int xw_bulk(xw_usb *usb, uint8_t endpoint, uint8_t *data, int length, unsigned timeout, int *transferred);
const char *xw_error(int code);
uint8_t xw_endpoint_in(xw_usb *usb);
uint8_t xw_endpoint_out(xw_usb *usb);

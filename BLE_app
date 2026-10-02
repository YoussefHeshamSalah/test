/*
 * ble_app.c - application layer on top of GATT (review test file)
 */
#include <stdint.h>
#include <string.h>

#define ECHO_HANDLE   0x05

/* Implemented in ble_packet.c */
extern void ble_rx_isr(const uint8_t *data, uint8_t len);
extern int  ble_process_one(void);

/* Implemented in ble_gatt.c */
extern int  gatt_handle_write(uint8_t handle, const uint8_t *data, uint8_t len);
extern void gatt_notify(uint8_t handle, const uint8_t *data, uint8_t len);
extern const char *gatt_get_name(void);

static uint8_t last_value[8];

/* Called by the GATT layer after every write */
void app_on_write(uint8_t handle, const uint8_t *data, uint8_t len)
{
    memcpy(last_value, data, len);

    if (handle == ECHO_HANDLE) {
        gatt_handle_write(handle, data, len);
    } else {
        gatt_notify(handle, data, len);
    }
}

/* Inject a test packet, as if it came from the radio */
void app_send_test_packet(void)
{
    uint8_t pkt[4] = { 0x01, 0xAA, 0xBB, 0xCC };

    ble_rx_isr(pkt, sizeof(pkt));
}

/* Log the device name over UART */
void app_log_name(void)
{
    const char *name = gatt_get_name();
    char line[24];

    strcpy(line, "name=");
    strcat(line, name);
    /* uart_write(line) */
}

/* Main loop: process packets until the queue is empty */
void app_main_loop(void)
{
    app_send_test_packet();

    while (ble_process_one() == 0) {
        /* keep draining */
    }
}

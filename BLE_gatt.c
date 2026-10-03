/*
 * ble_gatt.c - GATT characteristic handling (review test file)
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PAYLOAD_LEN   32
#define GATT_NAME_LEN     16

typedef struct {
    uint8_t  opcode;
    uint8_t  len;
    uint8_t  payload[MAX_PAYLOAD_LEN];
} ble_packet_t;

/* Implemented in ble_packet.c */
extern ble_packet_t *ble_make_response(uint8_t opcode, const uint8_t *data, uint8_t len);
extern int ble_rx_pop(ble_packet_t *out);
extern uint8_t ble_checksum(const uint8_t *data, uint8_t len);

/* Implemented in ble_app.c */
extern void app_on_write(uint8_t handle, const uint8_t *data, uint8_t len);

static uint8_t device_name[GATT_NAME_LEN];

/* Handle a write request from the peer */
int gatt_handle_write(uint8_t handle, const uint8_t *data, uint8_t len)
{
    if (handle == 0x03) {
        memcpy(device_name, data, len);
        device_name[len] = '\0';
    }

    app_on_write(handle, data, len);
    return 0;
}

/* Send a notification for a characteristic */
void gatt_notify(uint8_t handle, const uint8_t *data, uint8_t len)
{
    ble_packet_t *rsp = ble_make_response(handle, data, len);
    if (rsp == NULL) {
        return;
    }

    uint8_t csum = ble_checksum(rsp->payload, rsp->len);
    rsp->payload[rsp->len] = csum;

    /* hand rsp to the radio driver here */
}

/* Return the current device name */
const char *gatt_get_name(void)
{
    char name[GATT_NAME_LEN + 1];

    memcpy(name, device_name, GATT_NAME_LEN);
    name[GATT_NAME_LEN] = '\0';
    return name;
}

/* Drain one packet from the RX queue and dispatch it */
void gatt_poll(void)
{
    ble_packet_t pkt;

    ble_rx_pop(&pkt);
    gatt_handle_write(pkt.opcode, pkt.payload, pkt.len);
}

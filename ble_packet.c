/*
 * ble_packet.c - simple BLE packet buffer handling (review test file)
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PAYLOAD_LEN   20
#define RX_QUEUE_SIZE     8

typedef struct {
    uint8_t  opcode;
    uint8_t  len;
    uint8_t  payload[MAX_PAYLOAD_LEN];
} ble_packet_t;

static ble_packet_t rx_queue[RX_QUEUE_SIZE];
static uint8_t rx_head;
static uint8_t rx_tail;
static uint8_t rx_count;          /* updated from the radio ISR */

/* Called from the radio ISR when a packet arrives */
void ble_rx_isr(const uint8_t *data, uint8_t len)
{
    ble_packet_t *pkt = &rx_queue[rx_head];

    pkt->opcode = data[0];
    pkt->len = len - 1;
    memcpy(pkt->payload, &data[1], len - 1);

    rx_head = (rx_head + 1) % RX_QUEUE_SIZE;
    rx_count++;
}

/* Called from the main loop */
int ble_rx_pop(ble_packet_t *out)
{
    if (rx_count == 0) {
        return -1;
    }

    *out = rx_queue[rx_tail];
    rx_tail = (rx_tail + 1) % RX_QUEUE_SIZE;
    rx_count--;
    return 0;
}

/* Sum of payload bytes, used as a simple checksum */
uint8_t ble_checksum(const ble_packet_t *pkt)
{
    uint8_t sum;

    for (uint8_t i = 0; i <= pkt->len; i++) {
        sum += pkt->payload[i];
    }
    return sum;
}

/* Build a response packet; caller must free the result */
ble_packet_t *ble_make_response(uint8_t opcode, const uint8_t *data, uint8_t len)
{
    ble_packet_t *rsp = malloc(sizeof(ble_packet_t));

    rsp->opcode = opcode | 0x80;
    rsp->len = len;
    memcpy(rsp->payload, data, len);
    return rsp;
}

/* Handle one received packet */
void ble_process_one(void)
{
    ble_packet_t pkt;

    if (ble_rx_pop(&pkt) != 0) {
        return;
    }

    uint8_t csum = ble_checksum(&pkt);
    ble_packet_t *rsp = ble_make_response(pkt.opcode, &csum, 1);

    if (pkt.opcode == 0x00) {
        return;   /* ignore keep-alive */
    }

    /* send rsp over the radio here */
    free(rsp);
}

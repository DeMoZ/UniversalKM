// UniversalKM HID mode for ChameleonUltra (design D3–D6).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Adds a BLE HID over GATT keyboard + mouse to the stock firmware. The mode is off after every reset:
// the macOS app turns it on over USB (UKM_HID_SET_ENABLED 1) and then streams HID reports to it.
// While it is off the firmware behaves like upstream.
#ifndef UKM_HID_H
#define UKM_HID_H

#include <stdbool.h>
#include <stdint.h>

#include "dataframe.h"
#include "peer_manager.h"

// USB commands (netdata frames), protocol version 1.
#define UKM_HID_PROTOCOL_VERSION    1
#define DATA_CMD_UKM_HID_GET_INFO   (9000)  // -> [version u8, state u8, peer_id u16 BE]
#define DATA_CMD_UKM_HID_SET_ENABLED (9001) // [0/1] -> [state u8]
#define DATA_CMD_UKM_HID_KEYBOARD   (9002)  // [8-byte keyboard report] -> [state u8]
#define DATA_CMD_UKM_HID_MOUSE      (9003)  // [7-byte mouse report] -> [state u8]
#define DATA_CMD_UKM_HID_STATE      (9004)  // -> [state u8, peer_id u16 BE, peer_addr 6 bytes LE]

// Statuses besides STATUS_SUCCESS (0x68) and STATUS_PAR_ERR (0x60).
#define UKM_STATUS_BUSY             (0xA0)  // BLE notification queue full: retry shortly
#define UKM_STATUS_NOT_CONNECTED    (0xA1)  // mode off, no host, or the host is not subscribed

// State byte.
#define UKM_HID_STATE_DISABLED      0
#define UKM_HID_STATE_ADVERTISING   1
#define UKM_HID_STATE_CONNECTED     2       // connected, not (yet) subscribed to input reports
#define UKM_HID_STATE_SUBSCRIBED    3       // connected and subscribed: reports are delivered

// Creates the HID and Device Information services. Call from services_init().
void ukm_hid_services_init(void);

bool ukm_hid_is_enabled(void);

// Peer Manager hook: answers PM_EVT_CONN_SEC_PARAMS_REQ with Just Works bonding when the HID mode
// is on and the Chameleon pairing PIN is off (a keyboard has no display for a random passkey).
// Returns true when it replied.
bool ukm_hid_on_sec_params_req(pm_evt_t const *p_evt);

// Peer Manager hook: remembers the peer of the current link.
void ukm_hid_on_conn_sec_succeeded(pm_evt_t const *p_evt);

// USB hook: the host closed the serial port or USB power went away.
// Sends neutral (all released) reports, so nothing stays pressed on the phone.
void ukm_hid_on_usb_lost(void);

// Command processors for the app_cmd.c table.
data_frame_tx_t *ukm_hid_cmd_get_info(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_set_enabled(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_keyboard(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_mouse(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_state(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);

#endif // UKM_HID_H

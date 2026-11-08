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

// USB commands (netdata frames), protocol version 2: up to three hosts, reports addressed by peer ID.
#define UKM_HID_PROTOCOL_VERSION    2
#define DATA_CMD_UKM_HID_GET_INFO   (9000)  // -> [version u8, enabled u8, host count u8, max hosts u8]
#define DATA_CMD_UKM_HID_SET_ENABLED (9001) // [0/1] -> [state u8]
#define DATA_CMD_UKM_HID_KEYBOARD   (9002)  // [peer_id u16 BE, 8-byte report] -> [host state u8, host count u8]
#define DATA_CMD_UKM_HID_MOUSE      (9003)  // [peer_id u16 BE, 7-byte report] -> [host state u8, host count u8]
#define DATA_CMD_UKM_HID_STATE      (9004)  // -> [enabled, advertising, n] + n x [peer_id u16 BE, addr 6 LE, state]
#define DATA_CMD_UKM_HID_COUNTERS   (9006)  // -> report counters (debugging, see ukm_hid.c)
#define DATA_CMD_UKM_HID_DIAG       (9005)  // -> event history of the last connection (debugging, see ukm_hid.c)

// Statuses besides STATUS_SUCCESS (0x68) and STATUS_PAR_ERR (0x60).
#define UKM_STATUS_BUSY             (0xA0)  // BLE notification queue full: retry shortly
#define UKM_STATUS_NOT_CONNECTED    (0xA1)  // mode off, no host, or the host is not subscribed

// State byte.
#define UKM_HID_STATE_DISABLED      0       // mode off
#define UKM_HID_STATE_ADVERTISING   1       // mode on, this host not connected
#define UKM_HID_STATE_CONNECTED     2       // connected, not (yet) subscribed to input reports
#define UKM_HID_STATE_SUBSCRIBED    3       // connected and subscribed: reports are delivered

// Creates the HID and Device Information services. Call from services_init().
void ukm_hid_services_init(void);

bool ukm_hid_is_enabled(void);

// True while the HID mode is on and a BLE link is free: keep advertising (ble_main.c advertising_start).
bool ukm_hid_link_available(void);

// Peer Manager hook: answers PM_EVT_CONN_SEC_PARAMS_REQ with Just Works bonding when the HID mode
// is on and the Chameleon pairing PIN is off (a keyboard has no display for a random passkey).
// Returns true when it replied.
bool ukm_hid_on_sec_params_req(pm_evt_t const *p_evt);

// Peer Manager hook for every event (diagnostics).
void ukm_hid_on_pm_evt(pm_evt_t const *p_evt);

// Peer Manager hook: remembers the peer of the current link.
void ukm_hid_on_conn_sec_succeeded(pm_evt_t const *p_evt);

// USB hook: the host closed the serial port or USB power went away. With the Mac's Bluetooth control
// link up, only neutral (all released) reports go out and work goes on over Bluetooth; without it the
// HID mode turns off (neutral reports, hosts disconnected, advertising stopped).
void ukm_hid_on_usb_lost(void);

// NUS hook: a link enabled (started) or disabled notifications on the Nordic UART TX characteristic.
// That link is the Mac app's Bluetooth control channel.
void ukm_hid_on_nus_comm(uint16_t conn_handle, bool started);

// The Mac app's Bluetooth control link, or BLE_CONN_HANDLE_INVALID. NUS replies go to it.
uint16_t ukm_hid_controller_conn_handle(void);

// Command processors for the app_cmd.c table.
data_frame_tx_t *ukm_hid_cmd_get_info(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_set_enabled(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_keyboard(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_mouse(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_state(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_counters(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);
data_frame_tx_t *ukm_hid_cmd_diag(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data);

#endif // UKM_HID_H

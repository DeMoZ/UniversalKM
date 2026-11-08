// UniversalKM HID mode for ChameleonUltra (design D3–D6).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "ukm_hid.h"

#include <string.h>

#include "app_error.h"
#include "app_status.h"
#include "ble_conn_params.h"
#include "ble_dis.h"
#include "ble_hids.h"
#include "ble_main.h"
#include "nrf_sdh_ble.h"
#include "settings.h"
#include "ukm_report_map.h"
#include "utils.h"

#define NRF_LOG_MODULE_NAME ukm_hid
#include "nrf_log.h"
#include "nrf_log_ctrl.h"
NRF_LOG_MODULE_REGISTER();

#define UKM_HID_OBSERVER_PRIO       3       // after ble_advertising / Peer Manager (1) and ble_hids (2)

#define INPUT_REP_KEYBOARD_INDEX    0
#define INPUT_REP_MOUSE_INDEX       1
#define OUTPUT_REP_KEYBOARD_INDEX   0

#define BASE_USB_HID_SPEC_VERSION   0x0111  // bcdHID 1.11

// Lower connection interval while the HID mode is on: Android takes 7.5 ms, iOS settles at 15 ms.
// The range is wide on purpose: ble_conn_params disconnects when the host keeps an interval outside it.
#define UKM_MIN_CONN_INTERVAL       MSEC_TO_UNITS(7.5, UNIT_1_25_MS)
#define UKM_MAX_CONN_INTERVAL       MSEC_TO_UNITS(30, UNIT_1_25_MS)
#define UKM_CONN_SUP_TIMEOUT        MSEC_TO_UNITS(4000, UNIT_10_MS)

// Device Information. PnP ID: USB-IF vendor ID source, the ChameleonUltra USB VID/PID.
#define UKM_DIS_MANUFACTURER        "RfidResearchGroup"
#define UKM_DIS_MODEL               "ChameleonUltra"
#define UKM_PNP_VENDOR_ID_SOURCE    0x02
#define UKM_PNP_VENDOR_ID           0x6868
#define UKM_PNP_PRODUCT_ID          0x8686
#define UKM_PNP_PRODUCT_VERSION     0x0001

BLE_HIDS_DEF(m_hids,
             NRF_SDH_BLE_TOTAL_LINK_COUNT,
             UKM_KEYBOARD_INPUT_LEN,
             UKM_MOUSE_INPUT_LEN,
             UKM_KEYBOARD_OUTPUT_LEN);

static bool m_enabled = false;
static uint16_t m_conn_handle = BLE_CONN_HANDLE_INVALID;
static bool m_boot_mode = false;
static pm_peer_id_t m_peer_id = PM_PEER_ID_INVALID;
static ble_gap_addr_t m_peer_addr;
static bool m_neutral_pending = false;  // neutral reports still to be sent (queue was full)
static bool m_keep_adv_stopped = false; // HID mode turned off: stay out of the scan list

// --- Diagnostics: what happened on the last connection (UKM_HID_DIAG) -----------------------------

#define DIAG_BLE_EVTS   48
#define DIAG_PM_EVTS    16
static struct {
    uint8_t ble_count;                  // events recorded since the last connection (saturates)
    uint16_t ble_evts[DIAG_BLE_EVTS];   // first DIAG_BLE_EVTS BLE event IDs of the connection
    uint8_t pm_count;
    uint8_t pm_evts[DIAG_PM_EVTS];      // first DIAG_PM_EVTS Peer Manager event IDs
    uint8_t auth_status;                // BLE_GAP_EVT_AUTH_STATUS
    uint8_t auth_error_src;
    uint8_t auth_bonded;
    uint8_t disconnect_reason;
    uint16_t sec_failed_error;          // PM_EVT_CONN_SEC_FAILED
    uint8_t sec_failed_procedure;
    uint32_t sec_params_reply_err;      // pm_conn_sec_params_reply()
    uint8_t sec_params_replied;
    uint8_t peer_io_caps;               // from BLE_GAP_EVT_SEC_PARAMS_REQUEST
    uint8_t peer_flags;                 // bond | mitm << 1 | lesc << 2
} m_diag;

static void diag_ble(uint16_t evt_id) {
    if (m_diag.ble_count < DIAG_BLE_EVTS) {
        m_diag.ble_evts[m_diag.ble_count] = evt_id;
    }
    if (m_diag.ble_count < 0xFF) m_diag.ble_count++;
}

void ukm_hid_on_pm_evt(pm_evt_t const *p_evt) {
    if (m_diag.pm_count < DIAG_PM_EVTS) {
        m_diag.pm_evts[m_diag.pm_count] = (uint8_t)p_evt->evt_id;
    }
    if (m_diag.pm_count < 0xFF) m_diag.pm_count++;
    if (p_evt->evt_id == PM_EVT_CONN_SEC_FAILED) {
        m_diag.sec_failed_error = p_evt->params.conn_sec_failed.error;
        m_diag.sec_failed_procedure = p_evt->params.conn_sec_failed.procedure;
    }
}

// --- Services -----------------------------------------------------------------------------------

static void hids_evt_handler(ble_hids_t *p_hids, ble_hids_evt_t *p_evt) {
    switch (p_evt->evt_type) {
        case BLE_HIDS_EVT_BOOT_MODE_ENTERED:
            m_boot_mode = true;
            break;
        case BLE_HIDS_EVT_REPORT_MODE_ENTERED:
            m_boot_mode = false;
            break;
        case BLE_HIDS_EVT_NOTIF_ENABLED:
            NRF_LOG_INFO("Host subscribed to HID reports");
            break;
        default:
            // Keyboard LEDs (output report writes) are accepted and ignored.
            break;
    }
}

static void service_error_handler(uint32_t nrf_error) {
    APP_ERROR_HANDLER(nrf_error);
}

static void hids_init(security_req_t sec) {
    static ble_hids_inp_rep_init_t inp_reps[2];
    static ble_hids_outp_rep_init_t outp_reps[1];
    memset(inp_reps, 0, sizeof(inp_reps));
    memset(outp_reps, 0, sizeof(outp_reps));

    ble_hids_inp_rep_init_t *kb_in = &inp_reps[INPUT_REP_KEYBOARD_INDEX];
    kb_in->max_len = UKM_KEYBOARD_INPUT_LEN;
    kb_in->rep_ref.report_id = UKM_REPORT_ID_KEYBOARD;
    kb_in->rep_ref.report_type = BLE_HIDS_REP_TYPE_INPUT;
    kb_in->sec.cccd_wr = sec;
    kb_in->sec.wr = sec;
    kb_in->sec.rd = sec;

    ble_hids_inp_rep_init_t *mouse_in = &inp_reps[INPUT_REP_MOUSE_INDEX];
    mouse_in->max_len = UKM_MOUSE_INPUT_LEN;
    mouse_in->rep_ref.report_id = UKM_REPORT_ID_MOUSE;
    mouse_in->rep_ref.report_type = BLE_HIDS_REP_TYPE_INPUT;
    mouse_in->sec.cccd_wr = sec;
    mouse_in->sec.wr = sec;
    mouse_in->sec.rd = sec;

    ble_hids_outp_rep_init_t *kb_out = &outp_reps[OUTPUT_REP_KEYBOARD_INDEX];
    kb_out->max_len = UKM_KEYBOARD_OUTPUT_LEN;
    kb_out->rep_ref.report_id = UKM_REPORT_ID_KEYBOARD;
    kb_out->rep_ref.report_type = BLE_HIDS_REP_TYPE_OUTPUT;
    kb_out->sec.wr = sec;
    kb_out->sec.rd = sec;

    ble_hids_init_t init;
    memset(&init, 0, sizeof(init));
    init.evt_handler = hids_evt_handler;
    init.error_handler = service_error_handler;
    // ble_hids adds Protocol Mode only together with the boot keyboard characteristics.
    // Hosts use Report Protocol; in Boot Protocol only the keyboard works.
    init.is_kb = true;
    init.is_mouse = false;
    init.inp_rep_count = 2;
    init.p_inp_rep_array = inp_reps;
    init.outp_rep_count = 1;
    init.p_outp_rep_array = outp_reps;
    init.feature_rep_count = 0;
    init.p_feature_rep_array = NULL;
    init.rep_map.data_len = sizeof(ukm_report_map);
    init.rep_map.p_data = ukm_report_map;
    init.rep_map.rd_sec = sec;
    init.hid_information.bcd_hid = BASE_USB_HID_SPEC_VERSION;
    init.hid_information.b_country_code = 0;
    init.hid_information.flags = HID_INFO_FLAG_NORMALLY_CONNECTABLE_MSK;
    init.hid_information.rd_sec = sec;
    init.included_services_count = 0;
    init.p_included_services_array = NULL;
    init.protocol_mode_rd_sec = sec;
    init.protocol_mode_wr_sec = sec;
    init.ctrl_point_wr_sec = sec;
    init.boot_kb_inp_rep_sec.cccd_wr = sec;
    init.boot_kb_inp_rep_sec.rd = sec;
    init.boot_kb_outp_rep_sec.rd = sec;
    init.boot_kb_outp_rep_sec.wr = sec;

    APP_ERROR_CHECK(ble_hids_init(&m_hids, &init));
}

static void dis_init(void) {
    ble_dis_pnp_id_t pnp_id = {
        .vendor_id_source = UKM_PNP_VENDOR_ID_SOURCE,
        .vendor_id = UKM_PNP_VENDOR_ID,
        .product_id = UKM_PNP_PRODUCT_ID,
        .product_version = UKM_PNP_PRODUCT_VERSION,
    };
    ble_dis_init_t init;
    memset(&init, 0, sizeof(init));
    ble_srv_ascii_to_utf8(&init.manufact_name_str, UKM_DIS_MANUFACTURER);
    ble_srv_ascii_to_utf8(&init.model_num_str, UKM_DIS_MODEL);
    ble_srv_ascii_to_utf8(&init.fw_rev_str, GIT_VERSION);
    init.p_pnp_id = &pnp_id;
    init.dis_char_rd_sec = SEC_OPEN;
    APP_ERROR_CHECK(ble_dis_init(&init));
}

void ukm_hid_services_init(void) {
    // Encrypted link for everything with reports: the host bonds on first use.
    // With the Chameleon pairing PIN on, the PIN is required (MITM), as for the stock services.
    security_req_t sec = settings_get_ble_pairing_enable_first_load() ? SEC_MITM : SEC_JUST_WORKS;
    hids_init(sec);
    dis_init();
}

// --- State --------------------------------------------------------------------------------------

static bool cccd_enabled(uint16_t cccd_handle) {
    if (m_conn_handle == BLE_CONN_HANDLE_INVALID || cccd_handle == BLE_GATT_HANDLE_INVALID) {
        return false;
    }
    uint8_t value[BLE_CCCD_VALUE_LEN] = {0};
    ble_gatts_value_t gatts_value = {.len = sizeof(value), .offset = 0, .p_value = value};
    if (sd_ble_gatts_value_get(m_conn_handle, cccd_handle, &gatts_value) != NRF_SUCCESS) {
        return false;
    }
    return ble_srv_is_notification_enabled(value);
}

static uint8_t current_state(void) {
    if (!m_enabled) {
        return UKM_HID_STATE_DISABLED;
    }
    if (m_conn_handle == BLE_CONN_HANDLE_INVALID) {
        return UKM_HID_STATE_ADVERTISING;
    }
    // A bonded host that reconnects gets its CCCDs restored without a write, so read them.
    bool subscribed = m_boot_mode
                      ? cccd_enabled(m_hids.boot_kb_inp_rep_handles.cccd_handle)
                      : (cccd_enabled(m_hids.inp_rep_array[INPUT_REP_KEYBOARD_INDEX].char_handles.cccd_handle)
                         || cccd_enabled(m_hids.inp_rep_array[INPUT_REP_MOUSE_INDEX].char_handles.cccd_handle));
    return subscribed ? UKM_HID_STATE_SUBSCRIBED : UKM_HID_STATE_CONNECTED;
}

bool ukm_hid_is_enabled(void) {
    return m_enabled;
}

// Returns a netdata status.
static uint16_t send_input(uint8_t index, uint8_t *p_data, uint16_t len) {
    if (!m_enabled || m_conn_handle == BLE_CONN_HANDLE_INVALID) {
        return UKM_STATUS_NOT_CONNECTED;
    }
    ret_code_t err;
    if (m_boot_mode) {
        if (index != INPUT_REP_KEYBOARD_INDEX) {
            return STATUS_SUCCESS; // no boot mouse: drop
        }
        err = ble_hids_boot_kb_inp_rep_send(&m_hids, len, p_data, m_conn_handle);
    } else {
        err = ble_hids_inp_rep_send(&m_hids, index, len, p_data, m_conn_handle);
    }
    switch (err) {
        case NRF_SUCCESS:
            return STATUS_SUCCESS;
        case NRF_ERROR_RESOURCES:
        case NRF_ERROR_BUSY:
            return UKM_STATUS_BUSY;
        default:
            // NRF_ERROR_INVALID_STATE (not subscribed), BLE_ERROR_GATTS_SYS_ATTR_MISSING,
            // NRF_ERROR_FORBIDDEN (link not encrypted yet), BLE_ERROR_INVALID_CONN_HANDLE: no crash, report it.
            return UKM_STATUS_NOT_CONNECTED;
    }
}

static void send_neutral(void) {
    static uint8_t keyboard[UKM_KEYBOARD_INPUT_LEN];
    static uint8_t mouse[UKM_MOUSE_INPUT_LEN];
    memset(keyboard, 0, sizeof(keyboard));
    memset(mouse, 0, sizeof(mouse));
    uint16_t kb = send_input(INPUT_REP_KEYBOARD_INDEX, keyboard, sizeof(keyboard));
    uint16_t ms = (kb == UKM_STATUS_BUSY) ? UKM_STATUS_BUSY
                                           : send_input(INPUT_REP_MOUSE_INDEX, mouse, sizeof(mouse));
    // Retried on the next BLE_GATTS_EVT_HVN_TX_COMPLETE while the queue is full.
    m_neutral_pending = (kb == UKM_STATUS_BUSY || ms == UKM_STATUS_BUSY);
}

void ukm_hid_on_usb_lost(void) {
    if (m_enabled && m_conn_handle != BLE_CONN_HANDLE_INVALID) {
        NRF_LOG_INFO("USB lost: neutral reports");
        send_neutral();
    }
}

static void request_fast_conn_params(void) {
    ble_gap_conn_params_t params = {
        .min_conn_interval = UKM_MIN_CONN_INTERVAL,
        .max_conn_interval = UKM_MAX_CONN_INTERVAL,
        .slave_latency = 0,
        .conn_sup_timeout = UKM_CONN_SUP_TIMEOUT,
    };
    ret_code_t err = ble_conn_params_change_conn_params(m_conn_handle, &params);
    if (err != NRF_SUCCESS) {
        NRF_LOG_WARNING("Conn params change failed: %d", err);
    }
}

static void set_enabled(bool enabled) {
    if (enabled == m_enabled) {
        return;
    }
    NRF_LOG_INFO("HID mode %s", enabled ? "on" : "off");
    if (!enabled && m_conn_handle != BLE_CONN_HANDLE_INVALID) {
        send_neutral(); // while m_enabled is still true
    }
    m_enabled = enabled;
    m_neutral_pending = false;
    if (enabled) {
        m_keep_adv_stopped = false;
        if (m_conn_handle != BLE_CONN_HANDLE_INVALID) {
            // Not advertising: the new data is used when advertising restarts after this link.
            ble_advertising_hid_mode_set(true);
            request_fast_conn_params();
        } else {
            // ble_advertising_start() reconfigures the advertising set, which the SoftDevice refuses
            // (NRF_ERROR_INVALID_STATE -> APP_ERROR_CHECK -> reset) while advertising runs: stop first.
            advertising_stop();
            ble_advertising_hid_mode_set(true);
            advertising_start(false);
        }
    } else {
        // Leave the scan list until the next reset, so a bonded phone does not reconnect to a keyboard
        // that no longer types (iOS would keep hiding its on-screen keyboard).
        m_keep_adv_stopped = true;
        advertising_stop();
        ble_advertising_hid_mode_set(false);
        if (m_conn_handle != BLE_CONN_HANDLE_INVALID) {
            ret_code_t err = sd_ble_gap_disconnect(m_conn_handle, BLE_HCI_REMOTE_USER_TERMINATED_CONNECTION);
            if (err != NRF_SUCCESS && err != NRF_ERROR_INVALID_STATE) {
                APP_ERROR_CHECK(err);
            }
        }
    }
}

// --- Events -------------------------------------------------------------------------------------

static void on_ble_evt(ble_evt_t const *p_ble_evt, void *p_context) {
    if (p_ble_evt->header.evt_id == BLE_GAP_EVT_CONNECTED) {
        memset(&m_diag, 0, sizeof(m_diag));
    }
    diag_ble(p_ble_evt->header.evt_id);
    switch (p_ble_evt->header.evt_id) {
        case BLE_GAP_EVT_SEC_PARAMS_REQUEST: {
            ble_gap_sec_params_t const *peer = &p_ble_evt->evt.gap_evt.params.sec_params_request.peer_params;
            m_diag.peer_io_caps = peer->io_caps;
            m_diag.peer_flags = peer->bond | (peer->mitm << 1) | (peer->lesc << 2);
            break;
        }

        case BLE_GAP_EVT_AUTH_STATUS:
            m_diag.auth_status = p_ble_evt->evt.gap_evt.params.auth_status.auth_status;
            m_diag.auth_error_src = p_ble_evt->evt.gap_evt.params.auth_status.error_src;
            m_diag.auth_bonded = p_ble_evt->evt.gap_evt.params.auth_status.bonded;
            break;

        case BLE_GAP_EVT_CONNECTED:
            m_conn_handle = p_ble_evt->evt.gap_evt.conn_handle;
            m_peer_addr = p_ble_evt->evt.gap_evt.params.connected.peer_addr;
            m_peer_id = PM_PEER_ID_INVALID;
            m_boot_mode = false;
            if (m_enabled) {
                request_fast_conn_params();
            }
            break;

        case BLE_GAP_EVT_DISCONNECTED:
            m_diag.disconnect_reason = p_ble_evt->evt.gap_evt.params.disconnected.reason;
            m_conn_handle = BLE_CONN_HANDLE_INVALID;
            m_peer_id = PM_PEER_ID_INVALID;
            m_neutral_pending = false;
            // ble_advertising (higher priority) has just restarted advertising.
            if (m_keep_adv_stopped) {
                advertising_stop();
            }
            break;

        case BLE_GATTS_EVT_HVN_TX_COMPLETE:
            if (m_neutral_pending) {
                send_neutral();
            }
            break;

        default:
            break;
    }
}

NRF_SDH_BLE_OBSERVER(m_ukm_hid_observer, UKM_HID_OBSERVER_PRIO, on_ble_evt, NULL);

bool ukm_hid_on_sec_params_req(pm_evt_t const *p_evt) {
    if (!m_enabled || settings_get_ble_pairing_enable_first_load()) {
        return false; // upstream behaviour: Peer Manager defaults (PIN when enabled)
    }
    static ble_gap_sec_params_t just_works;
    memset(&just_works, 0, sizeof(just_works));
    just_works.bond = 1;
    just_works.mitm = 0;
    just_works.lesc = 1;
    just_works.keypress = 0;
    just_works.io_caps = BLE_GAP_IO_CAPS_NONE;
    just_works.oob = 0;
    just_works.min_key_size = 7;
    just_works.max_key_size = 16;
    just_works.kdist_own.enc = 1;
    just_works.kdist_own.id = 1;
    just_works.kdist_peer.enc = 1;
    just_works.kdist_peer.id = 1;
    ret_code_t err = pm_conn_sec_params_reply(p_evt->conn_handle, &just_works,
                                              p_evt->params.conn_sec_params_req.p_context);
    m_diag.sec_params_replied = 1;
    m_diag.sec_params_reply_err = err;
    APP_ERROR_CHECK(err);
    return true;
}

void ukm_hid_on_conn_sec_succeeded(pm_evt_t const *p_evt) {
    if (p_evt->conn_handle == m_conn_handle) {
        m_peer_id = p_evt->peer_id;
    }
}

// --- USB commands -------------------------------------------------------------------------------

data_frame_tx_t *ukm_hid_cmd_get_info(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data) {
    uint8_t payload[4] = {
        UKM_HID_PROTOCOL_VERSION,
        current_state(),
        (uint8_t)(m_peer_id >> 8),
        (uint8_t)(m_peer_id & 0xFF),
    };
    return data_frame_make(cmd, STATUS_SUCCESS, sizeof(payload), payload);
}

data_frame_tx_t *ukm_hid_cmd_set_enabled(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data) {
    if (length != 1 || data[0] > 1) {
        return data_frame_make(cmd, STATUS_PAR_ERR, 0, NULL);
    }
    set_enabled(data[0] == 1);
    uint8_t state = current_state();
    return data_frame_make(cmd, STATUS_SUCCESS, 1, &state);
}

data_frame_tx_t *ukm_hid_cmd_keyboard(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data) {
    if (length != UKM_KEYBOARD_INPUT_LEN) {
        return data_frame_make(cmd, STATUS_PAR_ERR, 0, NULL);
    }
    uint16_t result = send_input(INPUT_REP_KEYBOARD_INDEX, data, length);
    uint8_t state = current_state();
    return data_frame_make(cmd, result, 1, &state);
}

data_frame_tx_t *ukm_hid_cmd_mouse(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data) {
    if (length != UKM_MOUSE_INPUT_LEN) {
        return data_frame_make(cmd, STATUS_PAR_ERR, 0, NULL);
    }
    uint16_t result = send_input(INPUT_REP_MOUSE_INDEX, data, length);
    uint8_t state = current_state();
    return data_frame_make(cmd, result, 1, &state);
}

data_frame_tx_t *ukm_hid_cmd_state(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data) {
    uint8_t payload[9];
    payload[0] = current_state();
    payload[1] = (uint8_t)(m_peer_id >> 8);
    payload[2] = (uint8_t)(m_peer_id & 0xFF);
    if (m_conn_handle != BLE_CONN_HANDLE_INVALID) {
        memcpy(&payload[3], m_peer_addr.addr, BLE_GAP_ADDR_LEN);
    } else {
        memset(&payload[3], 0, BLE_GAP_ADDR_LEN);
    }
    return data_frame_make(cmd, STATUS_SUCCESS, sizeof(payload), payload);
}

// [ble_count, pm_count, auth_status, auth_error_src, auth_bonded, disconnect_reason,
//  sec_failed_procedure, sec_failed_error u16 BE, sec_params_replied, sec_params_reply_err u32 BE,
//  peer_io_caps, peer_flags, ble_evts u16 BE x min(ble_count, 48), pm_evts u8 x min(pm_count, 16)]
data_frame_tx_t *ukm_hid_cmd_diag(uint16_t cmd, uint16_t status, uint16_t length, uint8_t *data) {
    static uint8_t out[16 + DIAG_BLE_EVTS * 2 + DIAG_PM_EVTS];
    uint16_t n = 0;
    out[n++] = m_diag.ble_count;
    out[n++] = m_diag.pm_count;
    out[n++] = m_diag.auth_status;
    out[n++] = m_diag.auth_error_src;
    out[n++] = m_diag.auth_bonded;
    out[n++] = m_diag.disconnect_reason;
    out[n++] = m_diag.sec_failed_procedure;
    out[n++] = (uint8_t)(m_diag.sec_failed_error >> 8);
    out[n++] = (uint8_t)(m_diag.sec_failed_error & 0xFF);
    out[n++] = m_diag.sec_params_replied;
    out[n++] = (uint8_t)(m_diag.sec_params_reply_err >> 24);
    out[n++] = (uint8_t)(m_diag.sec_params_reply_err >> 16);
    out[n++] = (uint8_t)(m_diag.sec_params_reply_err >> 8);
    out[n++] = (uint8_t)(m_diag.sec_params_reply_err & 0xFF);
    out[n++] = m_diag.peer_io_caps;
    out[n++] = m_diag.peer_flags;
    uint8_t ble = m_diag.ble_count < DIAG_BLE_EVTS ? m_diag.ble_count : DIAG_BLE_EVTS;
    for (uint8_t i = 0; i < ble; i++) {
        out[n++] = (uint8_t)(m_diag.ble_evts[i] >> 8);
        out[n++] = (uint8_t)(m_diag.ble_evts[i] & 0xFF);
    }
    uint8_t pm = m_diag.pm_count < DIAG_PM_EVTS ? m_diag.pm_count : DIAG_PM_EVTS;
    for (uint8_t i = 0; i < pm; i++) {
        out[n++] = m_diag.pm_evts[i];
    }
    return data_frame_make(cmd, STATUS_SUCCESS, n, out);
}

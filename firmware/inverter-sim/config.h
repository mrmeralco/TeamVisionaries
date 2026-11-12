#pragma once
// Private per-network values (Wi-Fi password, broker IP) go in secrets.h next to this file.
// It is gitignored; anything it #defines wins over the defaults below.
#if __has_include("secrets.h")
#include "secrets.h"
#endif

// ===================== Solaris inverter simulator — config =====================
// ESP32 #2. Edit these, then upload.

// ---- Wi-Fi (the team hotspot). If it can't connect in 15 s, the simulator
//      starts its own AP "Solaris-Sim" (password below) at http://192.168.4.1 and
//      keeps looking for the hotspot every WIFI_RETRY_MS. Once it joins, the AP closes.
#ifndef WIFI_SSID
#define WIFI_SSID       "YOUR_HOTSPOT_SSID"
#endif
#ifndef WIFI_PASS
#define WIFI_PASS       "YOUR_HOTSPOT_PASSWORD"
#endif
#define WIFI_RETRY_MS   30000              // hotspot retry while in AP mode (AP clients blip briefly)
#define AP_SSID         "Solaris-Sim"
#define AP_PASS         "solaris1234"        // min 8 chars
#define MDNS_NAME       "solaris-sim"        // -> http://solaris-sim.local

// ---- Modbus link (Contract A). UART2.
//      Today (no RS485 modules): wire ESP32-to-ESP32 directly, TX->RX crossed.
//      Later with MAX3485/RS485 module: set RS485_DE_PIN to the DE+RE pin.
#define MB_SLAVE_ID     1
#define MB_BAUD         9600
#define MB_RX_PIN       26
#define MB_TX_PIN       25
#define RS485_DE_PIN    -1                 // -1 = direct UART (no transceiver)

// ---- MERALCO mode (ANSI C12.18). A real meter's password belongs to the utility.
#define C12_PASSWORD     "SOLARIS-DEMO"       // up to 20 chars; must match solaris-device/config.h
#define C12_MAX_BAD_PW   3                  // wrong passwords in a row before lockout
#define C12_LOCKOUT_S    60                 // logons refused (BSY) for this long

// ---- Front panel
#define POT_PIN         34                 // ADC1 only (ADC2 is dead while Wi-Fi is on)
#define BUTTON_PIN      27                 // to GND, uses internal pull-up
#define LCD_SDA         21
#define LCD_SCL         22
#define LCD_COLS        16                 // 16x2 by default; 20x4 also works
#define LCD_ROWS        2
#define LCD_ADDR        0                  // 0 = auto-detect (0x27 / 0x3F)

// ---- Button timing (ms)
#define LONG_PRESS_MS       1000           // hold 1–3 s, release -> toggle BROWNOUT
#define VERY_LONG_PRESS_MS  3000           // hold >3 s, release  -> toggle FAULT

// ---- Simulated system
#define PV_MAX_W        5000               // Sun knob 100% = this many watts
#define LOAD_MIN_W      150                // Load knob 0%  (always-on loads)
#define LOAD_MAX_W      4000               // Load knob 100%
#define BATT_KWH        10.0f              // battery size
#define BATT_MAX_CHG_W  3000               // max charge power
#define BATT_MAX_DIS_W  3000               // max discharge power
#define BATT_RESERVE    20                 // % kept in reserve while the grid is on
#define BATT_MIN_SOC    5                  // % floor during a brownout
#define FAULT_CODE      21                 // overheating
#define DEFAULT_SPEED   60                 // sim time multiplier (60 = 1 s -> 1 min)

// ---- AUTO mode: the simulator drives SUN and LOAD itself (no knob needed)
//      sun  = clear-sky curve for the local time of day x passing clouds
//      load = household day pattern + appliance bursts (kettle, aircon, iron ...)
//      Turn the knob (on SUN/LOAD) or move a web slider -> manual. Web button or
//      serial "auto on" -> back to AUTO.
#define AUTO_DEFAULT          1            // 1 = start in AUTO after every boot
#define AUTO_SPEED            1            // sim speed at boot in AUTO (1 = real time, so battery % matches the app's kWh)
#define AUTO_TZ               "PHT-8"      // POSIX TZ for the sun curve (Asia/Manila = UTC+8)
#define AUTO_OFFLINE_START_H  10.0f        // no internet time yet: pretend the box booted at 10:00
#define AUTO_SUN_PEAK         88           // sun % at clear-sky noon
#define AUTO_BURST_GAP_MIN_S  30           // quiet time between appliance bursts
#define AUTO_BURST_GAP_MAX_S  120
#define AUTO_KNOB_TAKEOVER_PCT 12          // turn the knob this far to switch to manual; 101 = knob never stops AUTO

// ---- Smart meter mode (Eastron SDM120-style single-phase kWh meter)
//      Hold the button > 6 s to switch INVERTER <-> METER (remembered after reboot).
#define MODE_PRESS_MS   6000
#define METER_SLAVE_ID  2                  // the inverter is ID 1, so both can share one bus later
#define METER_V_NOMINAL 230.0f             // PH nominal
#define METER_V_MIN     180                // VOLT knob 0%
#define METER_V_MAX     260                // VOLT knob 100%
#define METER_SAG_V     195.0f             // "low voltage" event (hold 3–6 s in meter mode)
#define METER_HZ        60.0f
#define METER_PF        0.95f
#define METER_START_KWH 1520.0             // starting import reading (saved to flash as it counts)

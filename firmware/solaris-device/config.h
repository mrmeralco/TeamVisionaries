#pragma once
// Private per-network values (Wi-Fi password, broker IP) go in secrets.h next to this file.
// It is gitignored; anything it #defines wins over the defaults below.
#if __has_include("secrets.h")
#include "secrets.h"
#endif

// ======================= Solaris device (connector) — config ===================
// ESP32 #1. Edit these, then upload.

// ---- Wi-Fi (team hotspot) and MQTT broker (Mosquitto on the server laptop)
#ifndef WIFI_SSID
#define WIFI_SSID     "YOUR_HOTSPOT_SSID"
#endif
#ifndef WIFI_PASS
#define WIFI_PASS     "YOUR_HOTSPOT_PASSWORD"
#endif
#ifndef MQTT_MDNS_HOST
#define MQTT_MDNS_HOST ""                  // server laptop's name, e.g. "ANDY-LAPTOP" -> found as ANDY-LAPTOP.local
#endif
                                           // on any hotspot IP (the start script prints it). "" = MQTT_HOST only
#ifndef MQTT_HOST
#define MQTT_HOST     "192.168.43.100"     // fallback: server laptop IP on the hotspot
#endif
#define MQTT_PORT     1883
#define MDNS_TIMEOUT_MS 1500               // how long to wait for the laptop to answer its .local name
#define MQTT_USER     ""                   // empty = no auth
#define MQTT_PASS     ""
#define DEVICE_ID     "solaris-001"          // empty "" = derive from MAC (solaris-a1b2c3)

// ---- Timing
#define POLL_MS       5000                 // Modbus poll + telemetry publish
#define STATUS_MS     30000                // retained status refresh
#define NTP_SERVER    "pool.ntp.org"       // or the laptop's IP if it runs an NTP server
#define WDT_TIMEOUT_S 30                   // reboot if loop() hangs this long

// ---- Modbus link. UART2.
//      Today (no RS485 modules): wire ESP32-to-ESP32 directly, TX->RX crossed.
//      Later with MAX3485: set RS485_DE_PIN to the pin tied to DE+RE.
#define MB_RX_PIN     26
#define MB_TX_PIN     25
#define RS485_DE_PIN  -1                   // -1 = direct UART (no transceiver)

// ---- What's on the bus (see profiles.h). Both are polled each cycle; whichever
//      answers gets published. A device that stops answering is retried every
//      ABSENT_RETRY_MS so a missing one doesn't slow the other down.
#define INVERTER_ENABLED  1
#define PROFILE           PROFILE_SOLARIS_SIM     // inverter -> solaris/{id}/telemetry
#define METER_ENABLED     1
#define METER_PROFILE     METER_SDM120          // smart meter -> solaris/{id}/meter
#define METER_ANSI_ENABLED 1                    // utility meter (Meralco/Aclara-style), ANSI C12.18
#define C12_USER_ID       2
#define C12_USER          "SOLARIS"               // up to 10 chars
#define C12_PASSWORD      "SOLARIS-DEMO"          // up to 20 chars; must match the simulator. A real meter's belongs to the utility
#define ABSENT_RETRY_MS   15000

// ---- Status LED (on-board LED is GPIO 2 on most ESP32 DevKits)
#define LED_PIN       2

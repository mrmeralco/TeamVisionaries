# Contract A3: utility meter over ANSI C12.18 (MERALCO mode)

Simulator in **MERALCO mode** ↔ Sinag device. Emulates the optical/data port of a utility meter
such as an Aclara I-210+c.

> This is a **fixed, simplified subset** for the demo. A real utility meter describes its own table
> layout in ST-0/ST-21/ST-12/ST-15 and needs the utility's password.

## Link layer (C12.18)

- Packet: `STP 0xEE` · reserved `0x00` · ctrl (toggle bit 0x20) · seq `0x00` · length (2 bytes, big-endian) · data · CRC
- CRC-16/X-25 (CCITT reflected, init 0xFFFF, inverted), sent low byte first
- Receiver answers each packet with `ACK 0x06` or `NAK 0x15`

## Session the device runs every poll

| Step | Request byte | Notes |
|---|---|---|
| Identify | `0x20` | Reply: OK, std 0, ver 2, rev 0 |
| Logon | `0x50` + user id (2) + user (10, space-padded) | `C12_USER_ID` / `C12_USER` in `sinag-device/config.h` |
| Security | `0x51` + password (20) | Simulator accepts any password |
| Full table read | `0x30` + table id (2) | Reply: OK, count (2), table bytes, checksum |
| Logoff, Terminate | `0x52`, `0x21` | Always sent, even after an error |

## Tables (little-endian, ST-0 DATA_ORDER = 0)

| Table | Bytes | Content |
|---|---|---|
| ST-0 GEN_CONFIG | 10 | Format control, device class `ACL `, nameplate type |
| ST-1 MANUFACTURER_IDENT | 32 | `ACL ` · model `I210+c  ` · HW/FW ver/rev · serial `SINAG-SIM-000001` |
| ST-23 CURRENT_REG_DATA | 13 | [0] demand resets · [1..4] import Wh (u32) · [5..8] export Wh (u32) · [9..12] total Wh (u32) |
| ST-28 PRESENT_REGISTER_DATA | 24 | [0] W (i32, + delivered / − received) · [4] V×100 (u32) · [8] A×1000 (u32) · [12] VA (i32) · [16] VAr (i32) · [20] PF×1000 (i16) · [22] Hz×100 (u16) |

The device publishes the decoded values on `sinag/{device_id}/meter` with `"meter_type": "ansi-c12"`
(same fields as Contract A2). See [B-mqtt.md](B-mqtt.md).

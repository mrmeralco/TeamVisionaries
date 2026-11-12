# Contract A3: utility meter over ANSI C12.18 (MERALCO mode)

Simulator in **MERALCO mode** ↔ Solaris device. Emulates the optical/data port of a utility meter
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
| Negotiate | `0x60` + packet size (2) + packets per message (1) | Reply: OK, packet size (2, max 64), packets (1), baud code `0x06` (9600, the link's fixed speed) |
| Logon | `0x50` + user id (2) + user (10, space-padded) | `C12_USER_ID` / `C12_USER` in `solaris-device/config.h` |
| Security | `0x51` + password (20, zero- or space-padded) | Must equal `C12_PASSWORD` in **both** `config.h` files (default `SOLARIS-DEMO`) |
| Full table read | `0x30` + table id (2) | Reply: OK, count (2), table bytes, checksum |
| Logoff, Terminate | `0x52`, `0x21` | Always sent, even after an error |

The simulator enforces the order: negotiate and logon only after identify, security only after
logon, table reads only after a correct password.

## Response codes

| Code | Name | When the simulator sends it |
|---|---|---|
| `0x00` | ok | Success |
| `0x01` | err | Wrong password, or a service out of order |
| `0x02` | sns | Unknown service |
| `0x03` | isc | Table read without logon + correct password |
| `0x04` | onp | Table doesn't exist |
| `0x05` | iar | Partial read past the end of the table |
| `0x06` | bsy | Logon during lockout: 3 wrong passwords in a row lock logons for 60 s (`C12_MAX_BAD_PW`, `C12_LOCKOUT_S`) |

The Solaris device reports these as error `0xB0 | code` with the code's name in the log.

## Tables (little-endian, ST-0 DATA_ORDER = 0)

| Table | Bytes | Content |
|---|---|---|
| ST-0 GEN_CONFIG | 10 | Format control, device class `ACL `, nameplate type |
| ST-1 MANUFACTURER_IDENT | 32 | `ACL ` · model `I210+c  ` · HW/FW ver/rev · serial `SOLARIS-SIM-000001` |
| ST-23 CURRENT_REG_DATA | 13 | [0] demand resets · [1..4] import Wh (u32) · [5..8] export Wh (u32) · [9..12] total Wh (u32) |
| ST-28 PRESENT_REGISTER_DATA | 24 | [0] W (i32, + delivered / − received) · [4] V×100 (u32) · [8] A×1000 (u32) · [12] VA (i32) · [16] VAr (i32) · [20] PF×1000 (i16) · [22] Hz×100 (u16) |

The device publishes the decoded values on `solaris/{device_id}/meter` with `"meter_type": "ansi-c12"`
(same fields as Contract A2). See [B-mqtt.md](B-mqtt.md).

## How this differs from a real I-210+c

- **Port.** Real C12.18 runs on the meter's ANSI Type 2 *optical* port (an infrared probe on the
  meter face). The meter has no RS485 terminal; the utility reads it over its AMI network.
- **Tables.** A real meter's ST-23/ST-28 layout and number formats come from its own ST-0/ST-21/ST-12/ST-15,
  and live V/A are often in manufacturer tables. Here the layouts are fixed.
- **Baud.** A real optical session starts at 9600 and may switch to the negotiated speed; this link stays at 9600.
- **Multi-packet replies** are not supported (every table here fits in one packet).
- **CRC** matches the spec's description (CCITT, first two bytes complemented) but hasn't been checked
  against a real meter.

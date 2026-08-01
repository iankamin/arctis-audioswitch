# Arctis Nova Pro Wireless — base station HID protocol

Reverse-engineered on macOS 26.5.2 against the base station, VID `0x1038`
PID `0x12E0`, vendor HID interface **usage page `0xFFC0`**
(64-byte in/out reports, 1024-byte feature reports).

The other interface (usage page `0x0C`, Consumer Control) is just the volume
wheel / media keys — not useful for connection state.

Opening the vendor interface from userspace needs **no entitlement and no
Input Monitoring grant**, because `0xFFC0` is a vendor-defined usage page
rather than a protected one.

## Why HID and not CoreAudio

The base station stays enumerated as a USB audio device whether or not the
headset is powered on. CoreAudio's device list is therefore **identical** in
both states — it cannot see the headset connect or disconnect. The HID
control interface is the only place that transition is observable.

## Report ID 6 — status, reply to `06 b0`

Send output report `06 b0`; the station replies with 16 meaningful bytes.

```
idx:  0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
OFF: 06 b0 00 02 04 01 00 08 0a 00 00 0a 05 00 04 01
ON:  06 b0 00 02 04 01 XX 08 0a 00 00 0a 05 00 08 08
```

| Byte | Meaning | Confidence |
|---|---|---|
| 6 | Battery level, `0x00` when headset off | **Confirmed** — tracked a battery swap: settled to `0x02` on a <50% cell, held `0x08` on a fresh one. Scale appears to be `0x00`–`0x08`; endpoints beyond those two samples are provisional. |
| 14 | Connection: `0x08` = on, `0x04` = off | **Confirmed** — identical across both low- and high-battery cycles |
| 15 | Connection: `0x08` = on, `0x01` = off | **Confirmed** — identical across both low- and high-battery cycles |

Byte 6 is the trap: on the first power-on it reads `0x08`, which looks exactly
like a connect flag until a battery swap separates them. Do not trigger on it.

## Report ID 7 — unsolicited push events

The station **pushes** these on state change, ahead of any poll reply.

```
headset ON       07 b5 ?? ?? 08
                 07 b7 <batt> 08 08

headset OFF      07 b5 ?? ?? 04
                 07 b7 00      08 01
```

- `07 b5 ?? ?? XX` — dedicated connection event. **Byte 4** is `0x08` =
  connected, `0x04` = disconnected. Byte 4 was identical on low and high
  battery, so it is battery-independent.

  **Bytes 2 and 3 are NOT constant.** This document previously called them a
  constant signature of `04 01`, on the strength of the captures below, and
  `HID.swift` matched all four bytes. On 2026-07-31 a station that had just
  been unplugged and replugged was captured pushing `07 b5 01 00 04` and
  `07 b5 01 00 08` — same events, different bytes 2-3. The four-byte match
  failed silently and the daemon stopped switching audio while looking
  perfectly healthy.

  What bytes 2-3 encode is still unknown; only two values have been observed
  (`04 01` and `01 00`), and the second appeared after a station cold boot.
  **Do not match on them.** Byte 1 is the discriminator; byte 4 is the payload.
- `07 b7 BB 08 YY` — battery + connection. `BB` = battery (`0x08` fresh,
  `0x02` low, `0x00` off); `YY` = `0x08` on / `0x01` off.
- `07 b9 VV` — volume changed. `VV` stepped `09 08 07 06` while turning the
  dial down, mirrored by report 6 byte 8.
- `07 2e LL` — ANC / transparency level. `LL` observed stepping `04` … `0c`
  while cycling transparency on, to level 10, to level 5, off, then ANC on/off.
- `07 bd [XX]` — seen as bare `07 bd` and as `07 bd 02`. Correlates with
  report 6 byte 10 going `01 -> 00`. Meaning not yet identified.

### Subcommand byte is the discriminator

`cycle3-controls.log` exercised volume, ChatMix, transparency (on, level 10,
level 5, off), ANC (on, off) and an EQ change, with the headset powered on
throughout. The headset had to be powered on once at the start of that capture
to operate the controls at all — and that power-on is the **only** `07 b5` in
the entire log. None of the subsequent control activity emitted one.

Connection events are therefore distinguishable from all other station traffic
by byte 1 alone (`b5` vs `b7`/`b9`/`2e`/`bd`), and matching the full
`07 b5 04 01` signature makes a false trigger from volume, ANC, transparency
or EQ activity impossible.

### Chosen trigger for the daemon

**`07 b5 04 01 XX`, byte 4.** It is a dedicated single-purpose event, verified
battery-independent, and arrives immediately on transition.

Report 6 bytes 14/15 are kept as a **reconciliation check** — queried once at
startup to establish initial state (no push event fires for a headset that was
already on when the daemon launched), and usable to re-sync if events are ever
missed.

## Timing

Both `b5` and `b7` fire within ~150 ms of the power button, `b5` first.
Debounce a little and act on `b5` alone to avoid double-switching.

## Open / not yet established

- Whether push events keep flowing with no polling at all — being verified in
  `cycle2-passive.log`. If they do not, the daemon falls back to polling
  `06 b0` and watching bytes 14/15.
- Exact battery scale endpoints (only two levels sampled).
- What bytes 3,4,5,7,8,11,12 encode; constant across every capture so far.
  Treat "constant across every capture so far" with suspicion — that is exactly
  what was said about bytes 2-3 of `07 b5`, and it was wrong.
- What bytes 2-3 of `07 b5` encode. Observed `04 01` and, after a station cold
  boot, `01 00`. No theory yet.

## Captures

- `cycle1-polled.log` — two full on/off cycles, one per battery, while polling
  `06 b0` at 1 Hz. Source of the table above.
- `cycle2-passive.log` — `--no-poll`, verifying events are genuinely pushed.

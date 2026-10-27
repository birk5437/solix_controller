# Anker Controller

Native macOS (SwiftUI, Swift 6) app to monitor Anker SOLIX portable power stations and manage their
**Time-of-Use (TOU)** mode. No Python, no server, no browser UI, no Homebrew dependencies.

> **Status, honestly:** the app builds, launches and passes its automated tests (see below), but **no command has
> been sent to a real battery and no real Anker account has been used yet.** Everything that talks to Anker or to
> hardware is implemented from the reference projects' documented protocol and covered by mock/synthetic-frame tests only.
> Items marked ⚠️ *unverified on hardware* below must be validated by you on first use. Read-only mode is ON by default.

## Build & run

```sh
./build.sh                       # → dist/Anker Controller.app
open "dist/Anker Controller.app"
swift test                       # unit tests
```

Requirements: Apple Silicon Mac, macOS 14+, Xcode command-line tools / Xcode with Swift 6.
`build.sh` detects the Mac's macOS version, targets macOS 14.0 (the minimum for Observation + Swift Charts), compiles in
release mode, assembles the bundle, and **ad-hoc signs** it.

**Signing / Gatekeeper:** the app is *ad-hoc signed only*. It is **not** Developer-ID signed and **not notarized**.
Built on your own Mac it opens from Finder normally. If you copy it to another Mac (AirDrop/download), Gatekeeper will
block it; right-click → Open, or run `xattr -dr com.apple.quarantine "Anker Controller.app"`. Distribution without
warnings needs an Apple Developer ID certificate + notarization, which this project does not have.

First launch asks for **Bluetooth** permission (device discovery). **Local Network** permission is requested only if
you use *Add Device → Local Network*. The deployment layout is a Swift package (no `.xcodeproj`): `build.sh` is the
supported build path; `open Package.swift` opens it in Xcode if you want to debug.

## Your devices — what is and isn't supported

Capabilities come from `ModelRegistry` (`Sources/AnkerCore/DeviceModels.swift`), derived only from what the reference
implementations document — never from the model name.

| Capability | C2000 Gen 2 (A1783) | C1000 Gen 2 (A1763) | F3800 Plus (A1790P) | Source |
|---|---|---|---|---|
| Live telemetry via Anker cloud MQTT | ✅ ⚠️ | ✅ ⚠️ | ✅ ⚠️ | `mqttmap.py`: `_A1783_0421`, `_A1763_0421`, `_A1790_0405` |
| Read stored TOU plan (`pps_use_time`, owner only) | ✅ ⚠️ | read-only attempt | read-only attempt | `api.get_device_attributes`, `poller.py` |
| Write TOU plan | ✅ ⚠️ | ❌ not mapped | ❌ not mapped | `schedule.set_pps_use_time` (generic cloud attr) |
| Switch Standard ↔ Time-of-Use | ✅ ⚠️ (MQTT group `0090`, field `a2`) | ❌ no `0090` group in map | ❌ no `0090` group in map | `mqttmap.py` A1783 vs A1763/A1790P |
| Backup reserve SOC | ✅ ⚠️ (`0090`/`a5`, range min+5…max) | ❌ | ❌ | `CMD_PPS_BACKUP_SOC_V2` |
| Read device-reported mode/schedule | ✅ ⚠️ (telemetry field `d9`) | ❌ | ❌ | `_A1783_0421["d9"]` |
| Bluetooth telemetry | ❌ no documented layout | ✅ ⚠️ (SolixBLE reports it confirmed on hardware) | ✅ ⚠️ (SolixBLE: “not tested”) | `BLESession.swift`, SolixBLE `devices/c1000g2.py`, `f3800.py` |
| Bluetooth control of TOU/mode | ❌ none exists | ❌ none exists | ❌ none exists | SolixBLE exposes switches/light/display only |
| Local Wi-Fi API | ❌ none documented | ❌ | ❌ | only X1 has Modbus TCP |
| Weekday/weekend or seasonal TOU | ❌ not part of PPS plan | – | – | `set_pps_use_time` (6 ranges, one daily plan) |

**What this means for your goal.** For the **C2000 Gen 2** the full TOU path (plan → mode switch → device read-back) is
implemented. For the **C1000 Gen 2** and **F3800 Plus** the reference projects contain *no* mode-switch or TOU command,
so the app refuses to send anything (it will not guess protocol bytes). If TOU "won't turn on" for those two in the
Anker app, the Diagnostics tab runs ten checks, and **Protocol Capture** records the device's MQTT frames and highlights
changed bytes while you toggle TOU in the Anker app — that is the way to document the missing command (see below).
A `⚠️` means: implemented to the documented format, tested against synthetic data, not yet confirmed against real devices.

### How TOU activation works (and why success is never assumed)

1. Read current mode (MQTT telemetry), stored plan (cloud `pps_use_time`).
2. Validate: ≤ 6 ranges, covering 00:00–24:00, no gaps/overlaps, reserve within `min SOC + 5 … max SOC`, prices numeric.
3. Show a confirmation with exactly what will change. **Previous plan is saved to the local database first.**
4. Upload plan (cloud REST, one attempt) → read it back → must match, otherwise abort **before** touching the mode.
5. Set reserve over MQTT if it differs → wait for the device to echo it.
6. Publish mode command (MQTT) once → wait up to 45 s for the device's own telemetry to report *Time of Use*
   (and its schedule to equal the plan). HTTP 200 / "published" is never reported as success.
7. Report per-step results; the UI shows Edited → Submitted → Accepted → Verified on device.

Non-idempotent writes are attempted once, on one transport; there is no cross-transport retry. Failover between
transports applies to reads only (`TransportManager`).

## Using it

1. Launch → *Add Device → Anker Account* → sign in (US server for your country `US`). Use the **owner** account.
   The password is encrypted to Anker before sending, never logged, and stored in the Keychain only if you tick the box.
2. Devices appear in the sidebar; live data starts after the first MQTT frame (up to ~1 min).
3. Switch **Read-only** off in the toolbar when you want to make changes. Every change still asks for confirmation.
4. *TOU Schedule* → edit ranges/tariffs/prices/reserve → *Save Schedule…* → *Activate TOU…*.
5. *Diagnostics* → *Run 10 Checks*; *Export Sanitized Diagnostic Log…* (emails, tokens, certificates, serials redacted,
   raw frame bytes omitted).

## Architecture

```
Sources/
  AnkerCore/            # UI-free library (all tested)
    DeviceModels.swift  # ModelRegistry (verified capabilities + sources), SOLIXDevice, BatteryTelemetry
    TOUPlan.swift       # plan model, validation, cloud-JSON + MQTT-binary serialization, editing helpers
    HexProtocol.swift   # Anker frame codec (XOR checksum), command builders, telemetry decoders
    CloudClient.swift   # login (ECDH P-256 + AES-256-CBC), REST calls, error mapping, throttling
    MQTT.swift          # MQTT 3.1.1 over TLS client-cert (Network.framework), Anker envelope
    CloudBackend.swift  # MQTT session, telemetry store, protocol capture; implements TOUBackend
    TOUService.swift    # diagnostics (10 checks) + activation workflow with read-back verification
    Transport.swift     # SOLIXTransport, TransportManager (order, override, failover rules)
    Bluetooth.swift     # CoreBluetooth scan/connect/GATT enumeration/auto-reconnect, advert parser
    LocalNetwork.swift  # Bonjour browse + TCP reachability probe
    Automation.swift    # DST-safe rules, validation, conflict detection, scheduler
    Storage.swift       # SQLite (telemetry, audit, snapshots, kv), Keychain, redaction
  AnkerController/      # SwiftUI app: AppState + views
Tests/AnkerCoreTests/   # 43 tests
```
This deviates from the suggested layout (Models/Services/… folders, `.xcodeproj`) because a SwiftPM library + app target
gives a testable core and a reproducible `build.sh`; adding a model means adding a `ModelProfile` and a decoder entry.

## Implementation checklist

| Area | State |
|---|---|
| Protocol research + capability matrix with sources | ✅ (this README, `ModelRegistry.sources`) |
| App shell, sidebar, dashboard, dark mode, persistence | ✅ builds & launches (UI not visually reviewed by the author's tooling) |
| BLE scan, identify (advert record), connect, GATT list, auto-reconnect | ✅ implemented ⚠️ untested on hardware |
| BLE encrypted session + live telemetry (C1000 Gen 2, F3800 Plus) | ✅ ⚠️ implemented from SolixBLE; handshake tested only against a mock battery |
| BLE control (output switches etc.) | ❌ not implemented; no TOU/mode commands exist over BLE |
| Local network: Bonjour + manual probe | ✅ implemented; no local protocol exists for your models |
| Cloud login, device list, attributes, MQTT info | ✅ ⚠️ untested against the real service |
| MQTT TLS client-cert connection | ✅ ⚠️ untested (identity is built from the PEM cert/key in a temporary keychain) |
| Live telemetry decode | ✅ synthetic frames only; field offsets from reference maps |
| TOU read/edit/save/activate/disable + verification | ✅ C2000 Gen 2 ⚠️; ❌ C1000 Gen 2, F3800 Plus (no documented command) |
| Reserve SOC | ✅ C2000 Gen 2 ⚠️ |
| Other settings (AC/DC switches, charge limit, light, display) | ❌ documented in references, intentionally not implemented; shown as unavailable |
| Automation (Mac-managed) with DST handling | ✅ unit-tested scheduling; ⚠️ runs only while app is open |
| History (SQLite, charts, energy) | ✅ ≤ 1 sample/min/device |
| Sanitized diagnostic export, audit trail | ✅ |
| Packaging `.app` (ad-hoc signed) | ✅ `./build.sh` |

## Known unknowns / how to investigate

* **Where the `d9` TOU block starts.** Offsets assume field bytes begin after the type byte, as in the reference decoder.
  If the Dashboard shows no mode for the C2000, open Diagnostics → Protocol Capture and compare the `d9` bytes.
* **C1000 Gen 2 / F3800 Plus TOU.** Toggle TOU in the Anker app with Protocol Capture running; frames on `cmd/…` topics
  (the app subscribes to both `dt/` and `cmd/`) will show the exact command message type and fields. Share the *decoded*
  capture (not raw bytes) via the sanitized export to extend the registry. The F3800 Plus is a "Power Panel PPS"; if it is
  attached to a Home Power Panel it uses a local MQTT broker and is not controllable through the cloud broker at all.
* **Firmware limits.** No reference documents a minimum firmware for TOU. Diagnostics reports `unknown` rather than guessing.
* **Anker account verification.** If Anker demands an email/captcha verification (error 26050–26055), complete it in the
  Anker app; this app has no verification-code flow.
* **Rate limits.** ≥ 0.5 s between REST calls, 429 blocks the endpoint for 60 s; telemetry is pushed over MQTT (re-triggered
  every 50 s), so no REST polling is used for live data.

## Safety

Read-only by default; explicit confirmation for every change; inputs validated against device ranges; undocumented commands
are refused at both service and backend level; previous schedules are snapshotted before overwrite; every change and its
verification outcome goes to a local audit trail; the BMS, firmware and authentication are never touched.

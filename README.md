<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="UniversalKM">
</p>

<h1 align="center">UniversalKM</h1>

<p align="center"><b>English</b> · <a href="README.ru.md">Русский</a></p>

<p align="center">
  <b>Your Mac's mouse and keyboard for any phone or tablet.</b><br>
  Push the cursor against a screen edge and input moves to Android, iPad or iPhone, like Universal Control, but not limited to Apple devices.
</p>

<p align="center">
  <a href="https://github.com/DeMoZ/UniversalKM/releases/latest"><img src="https://img.shields.io/github/v/release/DeMoZ/UniversalKM?color=3b4cc0" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-2b3245?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/BLE%20HID-ChameleonUltra-1f9d8a" alt="ChameleonUltra">
</p>

<p align="center">
  <img src="docs/images/panel.png" width="426" alt="UniversalKM panel: two Mac displays and a tablet at the right edge of the built-in display">
</p>

---

## Features

| | |
|---|---|
| 🖱️ **Cross at an edge** | Place a phone or tablet next to any edge of any display. When the cursor hits that edge, it moves to the device together with the keyboard. |
| ↩️ **Come back the same way** | Move the cursor to the device edge that faces the Mac and keep pushing: input returns to the Mac at the same height. ⌃⌥⌘⎋ always works too. |
| 👻 **The Mac cursor stays out of the way** | While you control a device, the Mac cursor is hidden and does not move. |
| 📱 **Up to three devices** | Three devices connect at once, each with its own zone in the layout. |
| 📐 **True size** | Enter the device screen size in points and pixels, then drag a corner so the device matches its physical size next to your displays. |
| 🔌 **USB or Bluetooth** | The Chameleon runs over USB. Unplug the cable and the app carries on over Bluetooth. |
| 🔄 **Updates** | Updates install from the app (Sparkle, signed appcast). macOS permissions survive updates. |
| 🌍 **Your language** | The interface follows the system language: English, Russian, German, French, Spanish, Portuguese (Brazil), Italian, Chinese (Simplified), Japanese, Korean. |

## How it works

<p align="center">
  <img src="docs/images/architecture.svg" alt="A Mac running UniversalKM connects to a ChameleonUltra over USB-C (Bluetooth as fallback); the Chameleon acts as a BLE HID keyboard and mouse for a phone, a tablet and an iPhone">
</p>

1. **UniversalKM** lives in the menu bar. It captures the mouse and keyboard when the cursor enters a device's zone and forwards key presses and motion.
2. **ChameleonUltra** is plugged into the Mac over USB. The UniversalKM firmware turns it into an ordinary Bluetooth keyboard and mouse (BLE HID).
3. **The phone** sees a standard Bluetooth keyboard and mouse. Nothing needs to be installed on it.

## Why not the Mac's built-in Bluetooth

The obvious approach is for the Mac itself to pose as a Bluetooth keyboard. macOS does not allow it:

- **BLE.** `CBPeripheralManager` refuses to publish the HID service `0x1812`, as well as Device Information `0x180A` and Battery `0x180F`, with *"The specified UUID is not allowed for this operation"*. Without these services a phone will not accept the device as a keyboard.
- **Classic Bluetooth.** IOBluetooth has no supported API for the HID device role: a Mac can connect keyboards but cannot be one.
- **Universal Control** only works between a Mac and an iPad signed in to the same Apple ID.

### A plain USB Bluetooth dongle does not help either

Plugging in a second Bluetooth adapter and driving it directly sounds simple. On macOS it does not work:

- macOS only uses its own Bluetooth controller and has no drivers for third-party USB adapters;
- claiming a USB device from your own program requires the restricted entitlement `com.apple.vm.device-access`, so libusb is refused even as root;
- cheap "Wi‑Fi + Bluetooth" adapters such as the AIC8800 show up as a Windows driver disk.

This was checked with an AIC 88M80 adapter: it never switched into Bluetooth mode.

### What does work

You need a separate microcontroller with Bluetooth LE that acts as an HID keyboard by itself and talks to the Mac over a USB port:

| Device | Chip | Notes |
|---|---|---|
| **ChameleonUltra** | nRF52840 | ✅ Used by UniversalKM. Keeps its NFC/RFID functions. |
| Nordic nRF52840 Dongle (PCA10059), Seeed XIAO nRF52840, Adafruit Feather nRF52840 | nRF52840 | Same chip as the Chameleon. Needs its own HID firmware. |
| ESP32‑S3 / ESP32‑C3 (any board with USB) | ESP32 | The cheapest option: BLE HID with NimBLE, USB serial to the Mac. |
| Raspberry Pi Pico W / Pico 2 W | RP2040 / RP2350 + CYW43439 | BLE HID with BTstack. |

The app supports only the ChameleonUltra for now. The transport is behind the `HIDTransport` protocol, so another board can be added with its own firmware and transport.

## The device used here: ChameleonUltra

[ChameleonUltra](https://github.com/RfidResearchGroup/ChameleonUltra) by RfidResearchGroup is an open-source, keyfob-sized NFC/RFID card emulator and reader. Inside is a **Nordic nRF52840**: a Cortex‑M4F with Bluetooth 5, everything a BLE keyboard needs. It was already at hand, so there was no need to buy an ESP32.

| | |
|---|---|
| **Model** | ChameleonUltra, hw v1, USB `6868:8686` |
| **Factory firmware** | v2.1.0 (you can roll back to it) |
| **UniversalKM firmware base** | upstream [`4c5bc2cb`](https://github.com/RfidResearchGroup/ChameleonUltra/commit/4c5bc2cb6b023d23f7bbc383c9b2b5e39f95419e) (v2.3.0‑14), nRF5 SDK 17, SoftDevice S140 7.2.0 |
| **Flashed with** | `nrfutil` over USB through the Chameleon's stock DFU bootloader. The bootloader is never changed. |
| **Built with** | Arm GNU Toolchain 12.2 and `make`, no Docker (`scripts/firmware-build.sh`) |

### What the firmware adds

<p align="center">
  <img src="docs/images/firmware.svg" alt="Upstream ChameleonUltra, the project's firmware/src and 8 patches are built by firmware-build.sh into a DFU package, which nrfutil flashes to the Chameleon over USB DFU">
</p>

The project's own code is in `firmware/src/` (`ukm_hid.c`, `ukm_report_map.h`). Changes to upstream are eight small patches in `firmware/patches/`:

| Patch | What it does |
|---|---|
| `0001` Makefile | adds the HID sources and the SDK modules `ble_hids`, `ble_dis` |
| `0002` sdk_config | enables HID and Device Information, 3 simultaneous links, a larger GATT table |
| `0003` ble_main | HID services, advertising as `ChameleonUltra`, pairing without a code, a separate control link for the Mac |
| `0004` app_cmd | USB commands 9000–9006: turn the mode on, send keyboard or mouse reports to a given device, device list, counters |
| `0005` usb_main | when USB is unplugged: release all keys, and turn the mode off if the Mac has no Bluetooth link |
| `0006` application.ld | moves RAM to make room for a SoftDevice with three links |
| `0007` app_main | LESC handler when the PIN is off |
| `0008` peer_manager | pairing events that upstream dropped when the PIN is off |

HID reports: keyboard (ID 1, 8 bytes, plus LEDs) and mouse (ID 2, buttons, 16‑bit X/Y, wheel and horizontal scroll). Cards, slots, buttons and the stock Chameleon client keep working. The keyboard and mouse mode is turned on only by the app.

## Install

1. Download `UniversalKM-<version>.zip` from the [latest release](https://github.com/DeMoZ/UniversalKM/releases/latest) and move the app to Applications. First launch: right-click → Open.
2. Flash the Chameleon with `chameleon-ultra-hid-dfu-app-<version>.zip` from the same release (see below), or build the firmware yourself.
3. Grant Accessibility and Bluetooth access.
4. Pair the phone with `ChameleonUltra` in its Bluetooth settings, then place the device next to a display edge in the layout ("+" button).

**Requirements:** macOS 14 or later, Apple Silicon. Building needs Xcode 27 and Swift 6.

## ChameleonUltra: build and flash

```bash
scripts/firmware-build.sh       # build/ultra-dfu-app.zip
scripts/firmware-flash.sh       # flash over USB (stock DFU)
```

- **Build.** The script installs Arm GNU Toolchain 12.2 and `nrfutil` into `~/Library/Caches/UniversalKM-firmware-tools`, downloads the upstream firmware into `build/firmware-src/`, copies `firmware/src/` there and applies `firmware/patches/`.
- **Flash.** Quit the stock Chameleon client and UniversalKM: only one program can hold the port. The script puts the Chameleon into DFU by itself. If that fails, switch the Chameleon off, hold button B and plug in USB (LEDs 4 and 5 blink); the script waits.
- **Roll back to the official firmware:** `scripts/firmware-flash.sh --official` (the default version is `OFFICIAL_TAG` in `firmware/UPSTREAM`) or `scripts/firmware-flash.sh --official v2.3.0`.

## Pairing a phone or tablet

While UniversalKM runs, the Chameleon advertises itself as a Bluetooth keyboard named `ChameleonUltra`. Up to three devices connect at once. Reports go to the device that has the input.

- **Android:** Settings → Bluetooth → Pair new device → `ChameleonUltra`. Pointer and keyboard work right away.
- **iPhone / iPad:** Settings → Bluetooth → `ChameleonUltra`. The keyboard works right away. iOS shows a mouse pointer only with AssistiveTouch on (Accessibility → Touch → AssistiveTouch). On iPhone the pointer does not move yet: a known issue, task 1.16.
- **PIN.** If PIN pairing is on in the Chameleon settings, the phone asks for it; if it is off (the default), pairing needs no code. Switch it with the stock Chameleon client: `hw settings blepair -e` / `-d`; set the PIN with `hw settings blekey`.
- **Do not pair the Mac itself** with the Chameleon in Bluetooth settings. The Mac takes one of the three links and starts receiving the key presses. If you already did, choose "Forget This Device".
- **Pairing is remembered:** after the app or the Chameleon restarts, devices reconnect by themselves. To remove a pairing: "Forget device" on the phone, `hw settings bleclearbonds` on the Chameleon.
- **When the app is closed,** the Chameleon disconnects the devices and stops advertising until the next launch, and the phone's on-screen keyboard comes back.

## USB and Bluetooth between the Mac and the Chameleon

The app finds the Chameleon over USB by itself and keeps a Bluetooth connection to it at the same time (the stock Nordic UART link; this is not macOS pairing).

- If USB is unplugged, work continues over Bluetooth. When USB comes back, the app switches back to it.
- While the Mac is connected over Bluetooth, it takes one of the Chameleon's three links, leaving two for devices.
- If USB is unplugged and the Mac has no Bluetooth link, the Chameleon turns the keyboard and mouse mode off, releases all keys and disconnects the devices.

On first launch macOS asks for Bluetooth access; allow it. `Resources/Info.plist` keys: `LSUIElement` (menu bar only), `NSBluetoothAlwaysUsageDescription` (Bluetooth link to the Chameleon), `SUFeedURL` and `SUPublicEDKey` (updates).

## Building the app

```bash
scripts/build-app.sh          # build/UniversalKM.app
scripts/build-app.sh --zip    # + build/UniversalKM-<version>.zip
scripts/run.sh                # build, relaunch and follow the log
scripts/run.sh --ble-demo     # demo: a square drawn with the pointer, a click and "hello" on each device
```

**Signing.** macOS ties the Accessibility and Input Monitoring permissions to the signing certificate. The script picks a certificate in this order:

1. `SIGN_IDENTITY`, if set;
2. the first "Apple Development" identity;
3. the project's self-signed certificate "UniversalKM Self-Signed" from the keychain;
4. with no certificate, an ad-hoc signature.

With a stable certificate, permissions survive rebuilds and updates; with ad-hoc signing they reset every time.

- **The project certificate** is in the login keychain (key and certificate "UniversalKM Self-Signed", valid 10 years) and in the repository secrets `SIGNING_CERTIFICATE_P12` / `SIGNING_CERTIFICATE_PASSWORD`, which sign releases. Back it up: Keychain Access → My Certificates → "UniversalKM Self-Signed" → Export… (.p12 with a password), and keep it in a password manager. If the certificate is lost, the next update asks for permissions once more.
- A self-signed certificate does not remove the macOS warning on first launch. Only an Apple Developer ID certificate with notarization does.

## Updates and releases

The app checks for updates once a day; the "Updates" button at the bottom of the panel checks right away. Updates are installed by [Sparkle](https://sparkle-project.org): it reads `appcast.xml` from the latest GitHub release and installs only archives signed with the project key (EdDSA).

- **Signing key.** The private half is in the keychain (account `UniversalKM`) and in the repository secret `SPARKLE_PRIVATE_KEY`; the public half is `SUPublicEDKey` in `Resources/Info.plist`. If the key is lost, installed copies cannot update. Back it up to a password manager, then delete the file:
  ```bash
  .build/artifacts/sparkle/Sparkle/bin/generate_keys --account UniversalKM -x ~/universalkm-sparkle.key
  ```
- **Releasing a version.** Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, write `docs/releases/v<version>.md`, merge into `main` and push a tag:
  ```bash
  git tag v0.1.0 && git push origin v0.1.0
  ```
  The `.github/workflows/release.yml` workflow checks that the tag matches the version, runs the tests, builds the app and the Chameleon firmware, signs the appcast and publishes a release with `UniversalKM-<version>.zip`, `appcast.xml` and `chameleon-ultra-hid-dfu-app-<version>.zip`.
- **Locally, without publishing:** `scripts/build-app.sh --zip && scripts/appcast.sh build/UniversalKM-<version>.zip`. The key is taken from the keychain.

## Support the project

UniversalKM is free. The "♥ Support" button at the bottom of the panel shows ways to support it. They are loaded from [DeMoZ/donations](https://github.com/DeMoZ/donations) (`universalkm.json`), so the links change without a new release.

> Plan and requirements: `openspec/changes/add-ble-hid-input-bridge/`.

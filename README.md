# ToneHop

A native macOS menu bar app for switching audio output devices, setting device volume, and assigning global keyboard shortcuts. Built with SwiftUI, AppKit, and Core Audio.

- Choose an output from the menu bar and see the result confirmed by the system.
- Adjust each device's volume when the device exposes a supported volume control.
- Assign a shortcut to each device. Bindings stay saved when a device is unavailable.
- Use the app in English or Simplified Chinese. Device names keep their original text.

**[Download ToneHop v0.1.0 for Apple silicon](https://github.com/iamdevindeng/tonehop/releases/tag/v0.1.0)** · [All releases](https://github.com/iamdevindeng/tonehop/releases)

## Requirements

- macOS **27.0 or later** is the project's deployment target.
- **Xcode 27.0** with the macOS 27.0 SDK is the verified build toolchain.
- Testing has been done on **Apple silicon (arm64), macOS 27.0.1**. Other hardware and macOS versions have not been verified.

The app has no third-party dependencies. AirPlay support uses private macOS APIs and has additional limits described below.

## Download and install

Download `ToneHop-0.1.0-arm64.dmg` and its `.sha256` file from the [v0.1.0 release](https://github.com/iamdevindeng/tonehop/releases/tag/v0.1.0). The DMG requires **Apple silicon and macOS 27.0 or later**. Xcode is only needed to build from source.

1. Put both downloaded files in the same folder. In Terminal, open that folder and verify the download:
   ```sh
   shasum -a 256 -c ToneHop-0.1.0-arm64.dmg.sha256
   ```
   The result should say `OK`.
2. If ToneHop is already running, quit it from its menu bar menu and finish any quit confirmation before replacing the app.
3. Open the DMG and drag `ToneHop.app` to `Applications`. Then eject the DMG and open ToneHop from Applications.

**First launch:** this release uses ad-hoc signing and is **not signed with Developer ID or notarized by Apple**. macOS may block it because it cannot verify the developer. After trying to open the app, go to **System Settings → Privacy & Security → Open Anyway**, then follow the confirmation. Use this single-app exception only if you trust this download; see [Apple's instructions](https://support.apple.com/en-us/102445). If macOS reports malware or a damaged app, stop and check the download instead.

The app runs in the menu bar. It does not open a main window or change your audio output at startup.

## Build and install from source

Install the full Xcode app and check that `xcodebuild -version` and `xcrun --sdk macosx --show-sdk-version` use the intended toolchain. Then run:

```sh
git clone https://github.com/iamdevindeng/tonehop.git
cd tonehop
mkdir -p build
TONEHOP_DERIVED_DATA="$(mktemp -d "$PWD/build/source-release.XXXXXX")"
xcodebuild -project ToneHop/ToneHop.xcodeproj \
  -scheme ToneHop -configuration Release -sdk macosx \
  -destination 'platform=macOS' \
  -derivedDataPath "$TONEHOP_DERIVED_DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DEPLOYMENT_POSTPROCESSING=YES DEPLOYMENT_LOCATION=NO \
  STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=debugging build

open "$TONEHOP_DERIVED_DATA/Build/Products/Release"
```

The last command opens the build folder. Quit any running ToneHop instance through its menu, copy `ToneHop.app` to Applications in Finder, and open it. ToneHop appears in the menu bar rather than opening a main window.

Builds use ad-hoc signing. They do not have a Developer ID signature or Apple notarization, and macOS may block a downloaded copy from opening.

## First use

Click the menu bar icon to open the device list, then click a device name to switch output. Starting ToneHop does not change the current output. Right-click the menu bar icon to quit.

When no shortcut configuration exists, ToneHop assigns **Control + Shift + 1** to the Mac's built-in speakers if it can identify them reliably. Other devices start without shortcuts. You can edit or clear this binding; an existing empty configuration stays empty.

To assign a shortcut, click its field and press a key combination containing **Command or Control**. Option and Shift can be added. Press Backspace in the field to clear it, or Escape to cancel. A device being unavailable does not remove its saved shortcut.

The interface follows the language macOS selects for ToneHop, with English as the fallback. Choose an app language in macOS settings and restart ToneHop to apply it.

## AirPlay and other limits

- **AirPlay relies on private APIs.** A system update may change or break discovery, switching, or volume control. The macOS deployment target is not a promise that every AirPlay feature works on every supported OS version.
- Some AirPlay devices must first be selected in the macOS Sound menu **while ToneHop is running**. Until ToneHop has enough information to switch safely, the device stays disabled in its list.
- Recovery of an existing AirPlay stream without a previously captured reference is currently enabled **only on macOS 27.0.1**, and only when the required identity and output checks pass. It does not run an automatic output switch at startup.
- If ToneHop has created an AirPlay stream that needs cleanup, quitting asks to switch to the Mac's built-in speakers and remove that stream. Cancel keeps the app running. ToneHop only removes streams it can confirm it owns; it does not remove streams created by the system or another app. If switching or cleanup cannot be confirmed, it stays open.
- Volume support depends on the device and the available system controls. Some devices cannot be adjusted in ToneHop. Changing volume does not connect or switch to that device.
- Switching changes the default media output; it does not also change the system sound-effects output.
- The current app does not require Accessibility automation or microphone access. It includes a Local Network permission description for device discovery; first-time permission prompts and denied-permission behavior have not been verified on a fresh account.
- Broader device coverage, sleep and network changes, long sessions, and full accessibility coverage remain unverified. Automated tests do not replace these hardware checks.

## Development

Open `ToneHop/ToneHop.xcodeproj` in Xcode and use the `ToneHop` scheme, or run these commands from the repository root:

```sh
./script/build_and_run.sh --build-only  # Build Debug without stopping or launching the app
./script/build_and_run.sh              # Build and launch/restart this checkout's app
./script/build_and_run.sh --verify     # Also verify the launched process path
./script/test.sh                       # Run hosted XCTest with fake audio providers
```

Quit another installed copy before running the development app to avoid competing for the shortcut configuration. The test host skips real audio service startup; the tests do not switch the system's audio output.

The Debug app is written to `build/Build/Products/Debug/ToneHop.app`. Logs and test results stay under `build/`, which is excluded from Git.

## License

[MIT](LICENSE). Copyright (c) 2026 ToneHop contributors.

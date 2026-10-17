# ToneHop

**English** | [简体中文](README.zh-CN.md)

ToneHop is a native macOS menu bar app. Use it to switch audio output devices, adjust device volume, and set global keyboard shortcuts. It uses SwiftUI, AppKit, and Core Audio.

- Select an output device from the menu bar. ToneHop shows the switch result after the system confirms it.
- Adjust a device's volume if the device has a supported volume control.
- Set a shortcut for each device. ToneHop keeps saved shortcuts when a device is unavailable.
- Use the app in English or Simplified Chinese. Device names keep their original text.

**[Download ToneHop v0.1.0 for Apple silicon](https://github.com/iamdevindeng/tonehop/releases/tag/v0.1.0)** · [All releases](https://github.com/iamdevindeng/tonehop/releases)

## Download & install (end users)

**Requires an Apple silicon Mac and macOS 27.0 or later.** We verified the app on macOS 27.0.1. We have not verified other hardware or macOS versions. You do not need Xcode to use the DMG.

1. Download **`ToneHop-0.1.0-arm64.dmg`** from the [v0.1.0 release](https://github.com/iamdevindeng/tonehop/releases/tag/v0.1.0).
2. If ToneHop is running, quit it from its menu bar menu.
3. If ToneHop asks for confirmation, confirm that you want to quit.
4. Wait for any requested AirPlay cleanup to finish.
5. Open the DMG.
6. Drag **ToneHop.app** to **Applications**.
7. If prompted, replace the old copy.
8. Eject the DMG.
9. Open ToneHop from Applications.

The ToneHop icon appears in the menu bar. The app does not open a main window or change your audio output at startup.

**First launch:** this release uses ad-hoc signing. It has **no Developer ID signature or Apple notarization**.

Use these steps only if macOS cannot verify the developer and you trust the download:

1. Try to open ToneHop.
2. Go to **System Settings → Privacy & Security → Open Anyway**.
3. Complete the confirmation.

This exception applies only to ToneHop. See [Apple's instructions](https://support.apple.com/en-us/102445). If macOS reports malware or a damaged app, stop. Check the download instead.

<details>
<summary>Verify the download (optional)</summary>

1. Download the matching `.sha256` file from the same release.
2. Put the `.sha256` file in the same folder as the DMG.
3. Open Terminal in that folder.
4. Run this command:

```sh
shasum -a 256 -c ToneHop-0.1.0-arm64.dmg.sha256
```

The expected result is `ToneHop-0.1.0-arm64.dmg: OK`. Use the filenames for the version you downloaded.

</details>

## Build from source (developers)

Install the full **Xcode 27.0** app with the **macOS 27.0 SDK**. We verified the project with this toolchain. The deployment target is macOS 27.0. The app has no third-party dependencies.

Use the following commands to check your active toolchain and clone the repository:

```sh
xcodebuild -version
xcrun --sdk macosx --show-sdk-version

git clone https://github.com/iamdevindeng/tonehop.git
cd tonehop
```

To use Xcode:

1. Open `ToneHop/ToneHop.xcodeproj`.
2. Select the `ToneHop` scheme.

You can also use these commands from the repository root:

```sh
./script/build_and_run.sh --build-only  # Build Debug without stopping or launching the app
./script/build_and_run.sh              # Build and launch/restart this checkout's app
./script/build_and_run.sh --verify     # Also verify the launched process path
./script/test.sh                       # Run hosted XCTest with fake audio providers
```

Before you run the development app, quit any other installed copy. This prevents multiple copies from using the shortcut configuration at the same time.

The test host does not start real audio services. The tests do not switch the system's audio output. `--verify` checks the process path. It does not check the interface or audio behavior.

The build creates the Debug app at `build/Build/Products/Debug/ToneHop.app`. Logs and test results stay under `build/`. Git ignores this directory.

<details>
<summary>Build a Release app or DMG</summary>

Run these commands from the repository root. They create a new build directory and build an arm64 Release app:

```sh
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

The last command opens the build folder.

1. Quit any running ToneHop instance through its menu.
2. Copy `ToneHop.app` to Applications.

These builds use ad-hoc signing. They have no Developer ID signature or Apple notarization. The first-launch instructions above also apply to downloaded copies.

To package the built app with the MIT license and a SHA-256 checksum, run this command:

```sh
./script/package_dmg.sh \
  "$TONEHOP_DERIVED_DATA/Build/Products/Release/ToneHop.app" \
  "$TONEHOP_DERIVED_DATA/dist/ToneHop-0.1.0-arm64.dmg"
```

The packaging script does not build or launch the app. It refuses to overwrite existing output files.

</details>

## First use

To switch the audio output:

1. Click the menu bar icon to open the device list.
2. Click a device name.

Starting ToneHop does not change the current output.

To quit:

1. Right-click the menu bar icon.
2. Select **Quit**.

ToneHop assigns **Control + Shift + 1** to the Mac's built-in speakers if both conditions apply:

- No shortcut configuration exists.
- ToneHop can reliably identify the built-in speakers.

Other devices start without shortcuts. You can change or clear this shortcut. An existing empty configuration stays empty.

To set a shortcut:

1. Click the shortcut field.
2. Press a key combination that includes **Command or Control**.

The combination can also include Option and Shift. To clear the shortcut, press Backspace in the field. To cancel, press Escape. ToneHop keeps the saved shortcut when the device is unavailable.

The interface uses the language that macOS selects for ToneHop. If that language is unavailable, ToneHop uses English.

To change the language:

1. Select an app language in macOS settings.
2. Restart ToneHop.

## AirPlay and other limits

### AirPlay

**AirPlay uses private APIs.** A system update can change or break device discovery, switching, or volume control. The macOS deployment target does not guarantee every AirPlay feature on every supported OS version.

Some AirPlay devices need an initial selection in the macOS Sound menu **while ToneHop is running**. Until ToneHop has enough information to switch safely, the device stays disabled in its list.

ToneHop enables recovery of an existing AirPlay stream without a previously captured reference only when both conditions apply:

- The Mac runs **macOS 27.0.1**. This recovery is disabled on all other versions.
- The required identity and output checks pass.

This recovery does not automatically switch the output at startup.

If an AirPlay stream created by ToneHop needs cleanup, the app asks for confirmation when you quit. This confirmation covers switching to the Mac's built-in speakers and removing that stream. Cancel keeps the app running.

ToneHop removes only streams that it can confirm it owns. It does not remove streams created by the system or another app. If ToneHop cannot confirm switching or cleanup, it stays open.

### Volume and output

Volume support depends on the device and the available system controls. ToneHop cannot adjust the volume of some devices. Changing volume does not connect or switch to that device.

Switching changes the default media output. It does not change the system sound-effects output.

### Permissions and verification

The current app does not require Accessibility automation or microphone access. It includes a Local Network permission description for device discovery. We have not verified first-time permission prompts or behavior after permission denial on a fresh account.

We have not verified the following:

- Broader device coverage.
- Sleep and network changes.
- Long sessions.
- Full accessibility coverage.

Automated tests do not replace these hardware checks.

## License

[MIT](LICENSE). Copyright (c) 2026 ToneHop contributors.

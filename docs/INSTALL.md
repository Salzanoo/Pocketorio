# Install guide: Factorio on iPad or iPhone Duo

This guide is for people who have never used Xcode. It takes about an hour the
first time, mostly waiting for downloads and the first build. You'll need:

- **An Apple Silicon Mac** (M1 or newer) with about **40 GB free**: roughly
  15 GB for Xcode and 20 GB for the build.
- **Factorio bought on Steam.** The app downloads the macOS version from Steam
  with your own account, on the device; the Mac never needs the game.
- **An Apple Account** (the one you use for the App Store is fine). A free
  account works.
- **The iPad or iPhone Duo** and a **USB cable** to connect it to the Mac.

| Device | What works |
|---|---|
| **iPad** with an M1 chip or newer, iPadOS 26 or later | Tested on an 11-inch iPad Pro (M1) |
| **iPhone Duo**, **iOS 27.2** recommended | Tested; needs **Xcode 27.2** or later to build |
| Other iPhones and iPads | Untested. They may fail to start the game's graphics |

There is no ready-made app to download: Apple requires every sideloaded app to
be signed with the installer's own Apple Account. The installer script below
does the building and signing for you. The app holds no game files; it gets
Factorio from Steam itself once it's on the device (step 7).

## 1. Install Xcode

Xcode is Apple's free tool for building apps.

1. Open the **App Store** on the Mac, search for **Xcode**, and click **Get**.
   It's a large download. For iPhone Duo you need **Xcode 27.2 or later**; if
   your Mac already has an older Xcode, update it from the App Store.
2. Open **Xcode** once from Applications. Agree to the licence and enter your
   Mac password if asked.
3. When Xcode asks which platforms to install, make sure **iOS** is selected,
   and wait for it to finish. (If it didn't ask: **Xcode → Settings →
   Components**, then install **iOS**.)

## 2. Sign in to Xcode with your Apple Account

1. In Xcode, open **Xcode → Settings → Apple Accounts**.
2. Click **+**, choose **Apple Account**, and sign in.

You don't need to pay for the Apple Developer Program. With a free account the
app stops opening after **7 days**; run the installer again to renew it, and
your saves are kept. A free account can also have at most 3 self-built apps on
a device at once. With the paid program ($99 a year), the app lasts a year.

## 3. Get this project

1. On this project's GitHub page, click the green **Code** button, then
   **Download ZIP**.
2. Open the downloaded ZIP to unpack it. You get a folder such as
   `factorio-native-arm-ipad-main`. Leave it in Downloads or move it anywhere.

## 4. Prepare the iPad or iPhone

1. **iPhone Duo:** unfold it. The game runs on the inner display.
2. Connect the device to the Mac with the cable and unlock it.
3. On the device, tap **Trust** when it asks whether to trust this computer,
   and enter its passcode.
4. On the Mac, Xcode may say it is preparing the device. Let it finish; you can
   watch in Xcode under **Window → Devices and Simulators**.
5. **Turn on Developer Mode** on the device:
   **Settings → Privacy & Security → Developer Mode**, turn it on, tap
   **Restart**, and after the restart tap **Turn On** and enter the passcode.
   The Developer Mode switch only appears after the device has been connected
   to Xcode, so do steps 2–4 first.

## 5. Run the installer

1. In the project folder, double-click **Install Factorio.command**.
   - If macOS says it can't verify the developer, open **System Settings →
     Privacy & Security**, scroll down, and click **Open Anyway** next to the
     message, then double-click the file again.
   - Or open **Terminal**, type `bash ` (with a space), drag the file into the
     Terminal window, and press Return.
2. A Terminal window opens and walks you through the rest. It may:
   - offer to install **Homebrew**, which then installs Python and CMake. Type
     `y` and enter your Mac password when asked (nothing shows as you type);
   - ask you to choose a device or team if you have more than one.
3. The first build takes 10–30 minutes. A timer shows it's still working.
4. When it finishes, the app is installed and opens on the device.

The installer remembers your choices, so later runs need no answers.

## 6. First start

- **"Untrusted Developer" on the device:** open **Settings → General → VPN &
  Device Management**, tap your Apple Account under **Developer App**, and tap
  **Trust**. Then open Factorio from the home screen.
- With no game yet, the app opens on a setup checklist (next step).

You can unplug the cable now.

## 7. Get Factorio on the device

The checklist on the app's home screen has three steps:

1. **Sign in to Steam** with the account that owns Factorio (password and Steam
   Guard, or the QR code). It also syncs your saves with Steam Cloud; see
   [Steam Cloud saves](STEAM_CLOUD.md).
2. **Import your signing certificate.** iOS only runs code signed by the app's
   own team, so the app signs the game it downloads with the certificate Xcode
   signed the app with. On the Mac, open **Keychain Access**, find
   **Apple Development: <your Apple Account>** under **My Certificates** (the one
   with a key under it), right-click it, **Export**, save as `.p12` with a
   password, and AirDrop it to the device (save it to Files). In the app, tap
   **Import signing certificate…**, pick it and enter the password. It stays in
   the app's keychain.
3. **Download and prepare Factorio**: pick the version (the newest is the
   default), tap **Download** (a few GB: use Wi-Fi and keep the app open), then
   **Prepare the game**. It says **Signed and ready to play**.

Then **Play**. The first start takes about 30 seconds; later starts are quicker,
as the game keeps its sprite atlas until the mods change. Close the changelog if
it appears, then start a tutorial or a new game.

Later, the home screen shows the game, Steam Cloud and **Play**; the gear opens
**Settings** (Steam, saves, game files, certificate, display, diagnostics).
After **Exit** in Factorio's menu, the app syncs and offers **Close**: Factorio
can't start twice in one go, so tap the icon to play again.

**How to play with touch:** see [Controls](CONTROLS.md). In short: the stick on
the left moves, the big **Use** button in the bottom-right corner clicks, and
the pill at the top switches between touch modes. Rotate to portrait to put the
controls below the game.

## Updating, renewing, and keeping your saves

Double-click **Install Factorio.command** again to:

- **renew** the app after 7 days on a free account (or a year on a paid one);
- **update** after downloading a newer version of this project.

A new Factorio version doesn't need the Mac: download it in **Settings > Game
files** and prepare it again. **Newest on Steam** also takes minor updates the
project hasn't tested (2.1.25 on an app built for 2.1.24): they usually work. If
one doesn't, the home screen says why; pick the tested version again.

The installer reuses the same app ID, so your saves and settings are kept.
**Don't delete the app** to fix a problem: deleting it deletes your saves.

To copy your saves to the Mac first, run this in Terminal from the project folder:

```sh
.venv/bin/python - <<'EOF'
import json, subprocess
s = json.load(open('.local-config.json'))
subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', s['device_id'],
                '--domain-type', 'appDataContainer', '--domain-identifier', s['bundle_id'],
                '--source', 'Documents/Factorio/user/saves', '--destination', 'save-backup'], check=True)
EOF
```

If you import a different certificate later (a new one from Xcode or
SideStore), the app signs the game again by itself before it starts.

## If something goes wrong

| What you see | What to do |
|---|---|
| **No iPhone or iPad is ready** | Unlock it, check the cable, tap **Trust**, and wait for Xcode to finish preparing it. iPhone Duo: unfold it |
| **Developer Mode is off** | Step 4.5. If the switch is missing, connect the device and open Xcode's **Devices and Simulators** window first |
| **Xcode has no Apple Account yet** | Step 2, then press Return in the installer window |
| **"Steam sent Factorio … which this app can't run"** | A new major version: pick a listed version under **Settings > Game files** |
| **"Factorio … didn't load"** on the home screen | That untested update needs a new build of the app; pick the tested version |
| **"Import your signing certificate"** after preparing | Step 7.2, then **Prepare again** |
| **That bundle ID is taken** | Open `.local-config.json` in the project folder with TextEdit, delete the line with `bundle_id`, and run the installer again |
| **maximum number of apps** (free account) | Delete another app you built yourself from the device, then run again |
| **Untrusted Developer** | Step 6 |
| The app stops opening after a week | The free signing expired. Run the installer again |
| The game doesn't fill the iPhone Duo's inner display | Build with Xcode 27.2 or later |
| The game crashes or runs out of memory while loading mods | Swipe the app away, then long-press its icon and choose **Safe mode**. It starts once without your mods and leaves them as they were |
| Something fails on the device | Open the app again, **Settings > Diagnostics > Share the log of the last run** |
| The build failed with something else | The installer prints the first errors. The full log is `reports/install-build.log` in the project folder |

More: [Troubleshooting for developers](DEVELOPMENT.md#troubleshooting).

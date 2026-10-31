# Getting the game on the device

The installed app downloads Factorio for macOS from Steam with the player's own
account, prepares it, and runs it, with no Mac step per game version. The app itself
is installed and re-signed by SideStore (see [SideStore](SIDESTORE.md)) or by the Mac
installer. Below, how each stage works.

## Stages

| Stage | What | Status |
|---|---|---|
| 1. Download | Factorio's macOS depot from Steam, through Madeira's depot downloader, into the app's container | **Done** |
| 2. Verify | The executable's SHA-256 against the audited builds (`tools/config.py`) | **Done** |
| 3. Patch | `tools/macho.py`'s retarget and `tools/entrypoint.py`, ported to Swift (`probe/patcher`), run on the downloaded game | **Done** |
| 4. Run | The single app makes the game a library, signs it with the imported certificate, and loads it before calling its main | **Done**: plays on iPhone Duo (iOS 27.2) |

Stages 1 and 2 are useful on their own: they show whether Steam will serve the
audited build to the device, and how big and how long the download is.

## Stage 1–2: download and verify

The app's Settings (the gear on its home screen) has a **Game files** page; until
a game is ready, the home screen is a setup checklist with the same steps:

- **Version** picks one of the supported versions (newest by default). Factorio's
  Steam app has a branch per version, named after it (`2.1.24`, `2.1.23`,
  `2.0.77`), so the chosen version comes from its own branch, whatever Steam's
  default is.
- **Download Factorio <version>** signs in with the app's Steam sign-in (the same
  one Steam Cloud saves use) and downloads one macOS depot into
  `Library/Application Support/Factoriduo/game/` (left out of iCloud and device
  backups). Each of Factorio's two macOS depots holds the whole game: 645392 has
  Space Age and is used when the account owns it, 427525 is the base game. A
  cancelled or failed download resumes where it stopped.
- Changing version reuses the files already downloaded: each is checked chunk by
  chunk, only the chunks that differ are fetched, and files the new version
  doesn't have are deleted.
- After the download the executable's SHA-256 is checked against the audited
  builds, and the result shows: which supported version it is, or that it isn't
  one of them.


## Stage 3: patch

Once a supported build is downloaded, the app shows **Prepare the game**. It
patches the downloaded executable as `tools/build_probe.py` does before codesign:

- retarget: iOS platform and SDK in LC_BUILD_VERSION, iOS install names, and a
  reexporting facade (`P<index>.dylib`) for every framework and the Steam API,
  no code signature;
- inject_entry: the entry trampoline to `ProbeMain`, the SDL redirects to the
  app's SDL, the Steam Cloud stand-in, the curl and Steam-notice fixes, the SDL 2
  restart and display-log fixes, and `__DATA` zero-fill growth when the padding
  is short (2.1.24).

It uses the app's own `Frameworks/libSDL3.dylib` (or SDL 2) and `ProbeShim.dylib`,
and the SDK in the app's own LC_BUILD_VERSION. The result goes to
`Library/Application Support/Factoriduo/game/Prepared/FactorioProbe`, with
`patch-report.json`.

The Swift is a step-by-step port of the Python, checked two ways:

- CI (`.github/workflows/patcher.yml`, Linux) builds `tools/patcher` and runs it
  and the Python on a synthetic game (`tests/synthetic_game.py`), with enough and
  with too little pointer padding: the outputs must be the same bytes.
- The macOS CI job signs the same synthetic output with the Swift `CodeSigner`
  and with Apple's `codesign`, and checks `codesign --verify` accepts it.

To check a real game, run the patcher on a copy of it next to the Python
reference (`tools/macho.py`, `tools/entrypoint.py`):

```bash
swiftc -O probe/patcher/*.swift tools/patcher/main.swift -o build/patcher
build/patcher /path/to/factorio.app/Contents/MacOS/factorio \
    build/iphoneos/FactorioProbe.app/Frameworks "$(xcrun --sdk iphoneos --show-sdk-version)" \
    build/patched-factorio
```

The patched game only loads with this app's own `ProbeShim.dylib`, which is
built for one Factorio's missing macOS symbols, and its SDL major version: for now,
the version of the profile the app was built from. Covering every supported
version from one app is still to do.

## The single app

One app downloads, patches and runs Factorio. Its executable is a launcher
(`probe/Launcher.c`) with no game in it; Factorio is a library the app makes
from the download and signs itself, loaded just before Factorio's main runs.

### Building it (Mac, once)

Build the port with Xcode or `tools/install.py`. The app holds the port's
libraries (ProbeShim, SDL, the facades, the Steam library) but no game
executable or data. Its Info.plist records the Factorio version and SHA-256 it
was built for (`FactoriduoGameVersion`, `FactoriduoGameSHA256`).

The Mac never needs the game: ProbeShim stands in for the macOS symbols that
Factorio version uses, and the build reads them from the committed profile
(`profiles/<version>.json`, see [Game profiles](DEVELOPMENT.md#game-profiles)).

### On the device

Until a game is ready, the home screen is a checklist (later these are under
Settings, the gear: **Game files** and **Signing certificate**):

1. **Import signing certificate**: the certificate this app is signed with, as a
   .p12 with its private key (from SideStore, or Keychain Access on the Mac that
   installs with Xcode). iOS loads only code signed by the app's own team. It is
   kept in this app's keychain (`GameCertificate.swift`). A free account's
   certificate lasts a year; the app's own 7-day profile is SideStore's (or
   Xcode's) to renew, as before.
2. **Download** a supported version (stages 1–2 above).
3. **Prepare the game**: the patch (stage 3), then `probe/patcher/GameLibrary.swift`
   makes it a library as LiveContainer does (MH_DYLIB, one-page `__PAGEZERO`,
   LC_ID_DYLIB) and `probe/patcher/CodeSigner.swift` signs it as codesign signs
   a library for current iOS (one SHA-256 CodeDirectory, CMS with Apple's
   cdhashes attributes and the WWDR G3 and root CAs; the RSA signature is
   `SecKeyCreateSignature` with the Keychain's key). The result goes to
   `game/Current`: `Factorio.dylib`, `data` (a link to the download's data) and
   `launch.plist` (the game's main as an offset from its header).
4. **Play**: `probe/UIKitEntry.m` loads `game/Current/Factorio.dylib` and calls
   its main. The game's read-data path is always `game/Current/data`.

If the certificate changes (a new one imported), the game is signed again
before it starts, from the kept patch.

`tests/test_code_signer.py` checks the library and the signature without
trusting the Swift: page hashes recomputed in Python, the CMS verified by
openssl, and on macOS verified by Apple's codesign, next to a signature codesign
makes for the same library with the same (throwaway) certificate.

## Code

- `probe/Launcher.c`: the single app's executable; `probe/UIKitEntry.m`
  (`FPILauncherMain`, `LoadGameLibrary`) loads the game.
- `probe/steam/Madeira/Content/`, `Install/` and `C/`: Madeira's depot downloader,
  manifest parser, chunk decryption and decompression (zstd, LZMA via the system
  liblzma, zlib), changed only where marked.
- `probe/steam/Factoriduo/GameDownload.swift`: the version picker, depot choice,
  supported builds, verification, and the Factorio section.
- `probe/steam/Factoriduo/GamePrepare.swift`: the patch, its check, and making,
  signing and installing the library.
- `probe/steam/Factoriduo/GameCertificate.swift`: the imported certificate.
- `probe/patcher/` (MIT, Foundation only, so it also builds on Linux):
  `MachOFile`, `GamePatcher` (the patch), `GameLibrary` (executable to library),
  `CodeSigner`, `DER`, `Hashing` and `AppleCertificates`.
  `tools/patcher/main.swift` is its command-line form for CI and the Mac.

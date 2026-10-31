# Steam Cloud saves

Factoriduo can keep Factorio's saves in step with Steam Cloud, so a game saved on
your PC continues on the phone and the other way round. It signs in to Steam
itself and talks to Steam's servers directly; no PC or Steam app needs to be
running for it.

The Steam code comes from [Madeira](https://github.com/willfaust/Madeira) (its
Swift Steam client and Steam Cloud sync), with Factoriduo's own mapping of
Factorio's save folder. See [Licence](#licence).

## Using it

- **First start after installing:** a screen offers **Sign in to Steam**, **Not
  now** or **Don't ask again**. Sign in with your account name and password (then
  a Steam Guard code or approval in the Steam app), or switch to the QR code and
  scan it with the Steam app on another device.
- **Every start, when signed in:** the app's home screen checks Steam Cloud,
  downloads saves that are newer in the cloud and uploads saves that are newer on
  the phone, then **Play** starts the game (**Play without waiting** doesn't
  wait). Saves that changed on both sides show as a card to review.
- **Exit in Factorio's menu:** saves sync both ways, the result shows, and
  **Close** closes the app. Factorio can't start a second time in the same
  process (iOS can't unload it, and an app can't relaunch itself); tap the icon
  to play again.
- **Leaving the app** (home screen, app switcher): saves that changed on the phone
  upload in the background. iOS allows about 30 seconds; anything left uploads at
  the next start.
- **Settings:** the gear on the home screen (or long-press the app icon and
  choose **Settings**) to sign in or out, turn syncing off, include autosaves, or
  use the whole screen. Like **Safe
  mode**, it takes effect as the game starts: if Factorio is already running, the
  app says so; swipe it away in the app switcher and choose it again.

On the PC, Factorio's saves only reach Steam Cloud while **Keep game's saves in
the Steam Cloud** is on in Factorio's settings and Steam Cloud is on for Factorio
in Steam. Steam uploads them when the game on the PC closes.

## What it syncs

Steam lists Factorio's saves under its Auto-Cloud rule, root `WinAppDataRoaming`,
folder `Factorio/saves/`, pattern `*.zip`, so a PC's save is
`%WinAppDataRoaming%Factorio/saves/<name>.zip` in the cloud. On the phone that is
`Documents/Factorio/user/saves/<name>.zip`, the game's own saves folder. If
Steam's product info for Factorio names a different saves folder for Windows,
that one is used.

**Autosaves** (`_autosave1.zip` and so on) are left out by default: the PC and the
phone both write them all the time, so they would need a choice after almost every
session. Turn them on under **Settings** (long-press the app icon) if you want them anyway.

Other files Factorio keeps in Steam Cloud, such as `player-data.json`, are not
synced with Steam. On the phone the game saves that file (your factorio.com login
and multiplayer name) in its own data folder (`Documents/Factorio/user`), through
the patched game's cloud methods, so the login is kept between starts. The version
of the file on your PC isn't used or changed.

## Safety rules

These are Madeira's:

- A save changed or new on one side only is copied to the other.
- A save changed on **both** sides, or different with no record of an earlier
  sync, is never copied over. The start screen lists it with both dates and sizes:
  **Keep Steam's** or **Keep this phone's**, or **Decide later**.
- A save that was synced here and is now missing on the phone while the cloud still
  has it is also a choice: **Keep Steam's** downloads it, **Leave it off this
  phone** keeps it missing (asked again only if the cloud's copy changes).
- Every download is checked against the SHA-1 Steam lists before anything is
  written.
- Before a download replaces a save on the phone, and before an upload replaces
  one in the cloud, the old copy is saved in
  `Documents/Factorio/steam-cloud-backups/<date>/device` or `.../cloud`.
- Nothing is ever deleted in the cloud.
- While the game runs nothing is downloaded; it may have the saves open.

The record of the last sync is
`Library/Application Support/Factoriduo/steam-cloud-sync.json`. It belongs to one
Steam account: signing in to another starts a new record, so the first sync after
that asks about any save that differs.

## Before you rely on it

This is untested on a device so far. Back up the saves on both sides first
(`%APPDATA%\Factorio\saves` on the PC; on the phone see
[Updating, renewing, and keeping your saves](INSTALL.md#updating-renewing-and-keeping-your-saves)).

- **Same Factorio version on both.** The phone runs the exact version it was built
  from. Steam updates the PC; a save from a newer version won't load on the
  phone. Choose the matching version on the PC under Factorio's **Properties →
  Betas** in Steam.
- **Same mods.** A save that uses mods needs them on both sides.
- **Two Steam logons.** The phone logs on only while it syncs and logs off right
  after. Madeira notes that a second logon of the same account can log the other
  one out; check that syncing while Steam runs on the PC doesn't sign the PC out.
- **Large saves** take a while; Steam's own sync is known to fail on very large
  ones. Steam Cloud has a quota per game, and saves over it are not kept.

## Logs and troubleshooting

Lines in the app's log start with `FACTORIDUO_STEAM:`, for example
`[steam-cloud] cloud-change=... same=3 differ=0 missing-local=1 local-only=0 unmapped=4 | plan download=1 upload=0 ask=0`.
They never contain passwords, tokens or account names. `unmapped` counts cloud
files that are not saves this syncs (autosaves while those are off,
`player-data.json`).

| Problem | Fix |
|---|---|
| A save from the PC isn't on the phone | Check Factorio's cloud setting on the PC and that Steam finished uploading after the game closed |
| "Steam did not respond in time" | Check the connection and choose **Try again**, or play and sync next time |
| The sign-in is refused after a while | Steam expired the sign-in. Long-press the icon, choose **Settings**, sign out and in again |
| You chose the wrong side | The other copy is in `Documents/Factorio/steam-cloud-backups` |

## How it is built

`probe/steam` is a Swift module built into
`Frameworks/FactoriduoSteam.dylib` by `tools/build_probe.py`:

- `probe/steam/Madeira`: Madeira's Steam client (sign-in, Keychain token, CM
  session, product info) and the protocol parts of its Steam Cloud code, with
  small marked changes (app name, Keychain service).
- `probe/steam/Factoriduo`: Factorio's save mapping and the sync
  (`FactorioCloud.swift`), the start screen and background upload
  (`CloudLaunch.swift`), and stand-ins for Madeira's log and settings
  (`MadeiraShims.swift`).

`tools/steam_cloud.py` builds the library on its own (no game files needed), which
is what the **Steam Cloud library** GitHub workflow does: a syntax check on Linux,
then the iOS build on macOS, capped at 10 minutes.

`probe/UIKitEntry.m` opens the library just before Factorio's own `main` and calls
`FDSteamCloudBeforeGame`. If the library is missing, the game starts as before.

## Licence

Madeira's code, and Factoriduo's code built on it in `probe/steam`, are under
GPL-3.0-or-later with the Madeira Converter Exception
(`probe/steam/Madeira/LICENSES`). An app built with it is therefore
GPL-3.0-or-later as a whole; the rest of this repository stays MIT. That is fine
for your own builds; share the source along with any app you give to others.

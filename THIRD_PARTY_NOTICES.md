# Scope and third-party notices

The MIT License of this repository covers the porting code, build tools and
documentation it contains. It grants no rights to Factorio, its executables,
graphics, audio, game data or trademarks.

Factorio and its data are not part of this repository or of the app. The app
downloads the game from Steam with the player's own account, on the device, and
patches a copy there. `profiles/` holds only metadata about supported versions (the
hash, names of the system functions the game imports, and an offset).

The app icon, `assets/AppIcon.png`, is Factorio's icon: © Wube Software, not owned by
this project, used only as the app's icon, and not covered by the MIT License. It will
be removed on request.

This project was written entirely by AI (Claude, through Claude Code) and comes with
no warranty; see the README.

SDL 2.30.9 or SDL 3.4.14, matching the Factorio version, is downloaded from the
official SDL repository during the first build. SDL is under the zlib licence;
its LICENSE.txt stays in the locally unpacked source under
`build/vendor/SDL-release-2.30.9` or `build/vendor/SDL-release-3.4.14`. The
project adds `probe/SDLInputBridge.c` to the SDL CMake target. For SDL 3.4.14 the
build also adjusts the UIKit window setup so that the iPhone Duo's active inner
display sets the window size, orientation and input focus, insets the game view
on phones, and reserves space below it for the portrait control deck. These local
changes are applied by `tools/prepare_sdl.py` and are not part of the official
SDL release.

`probe/steam` is not under the MIT License: it holds the Swift Steam client and
Steam Cloud code of [Madeira](https://github.com/willfaust/Madeira) (commit
c2c1b03; Copyright 2026 Jfishin, 125hz and Madeira's contributors), changed as
marked in each file, and Factoriduo's Steam Cloud sync built on it. All of it is
under GPL-3.0-or-later with the Madeira Converter Exception; the licence texts are
in `probe/steam/Madeira/LICENSES`. An app built with `FactoriduoSteam.dylib` is
therefore GPL-3.0-or-later as a whole. See [Steam Cloud saves](docs/STEAM_CLOUD.md).
It also holds Madeira's depot downloader for [the on-device game download](docs/ON_DEVICE.md),
with Meta's Zstandard educational decoder (`probe/steam/Madeira/C/zstd_edu.c`, BSD-3-Clause
selected, text in `probe/steam/Madeira/LICENSES/ZSTD-BSD.txt`); it links the system's
liblzma and zlib.

Python/PyYAML, CMake, Homebrew and the Apple SDKs are used locally and are not
shipped with this repository. Their own licence terms apply.

This project is an independent, experimental port and not an official iPhone or
iPad client from Wube Software.

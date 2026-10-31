# Install and refresh with SideStore

[SideStore](https://sidestore.io) installs the app with your own Apple Account and
renews its 7-day signing on the device, without a Mac or the cable after setup.
The app is published as a SideStore **source** in the public
[Pocketorio](https://github.com/Salzanoo/Pocketorio) repository.
(The other way, with Xcode on a Mac, is in the [install guide](INSTALL.md).)

The app holds no game files: after installing, it downloads Factorio from Steam
with your account (see [the install guide](INSTALL.md), step 7).

## Add the source

In SideStore, go to **Sources > +** and enter:

```
https://github.com/Salzanoo/Pocketorio/releases/latest/download/apps.json
```

Then install **Pocketorio** from it. SideStore signs the app and adds your team to its
bundle ID. SideStore itself needs setting up first (its own guide: pairing file and
its VPN profile); check its release notes for your iOS version.

After installing:

1. In the app, import SideStore's signing certificate when it asks for one
   (**Settings > Signing certificate**); see [On-device patching](ON_DEVICE.md).
2. Sign in to Steam, download Factorio and prepare it, as in the install guide.

SideStore refreshes the app in the background while it can reach its VPN.

## Updates and saves

Each release (see [Releasing](RELEASING.md)) is a new version; SideStore offers it
as an update, and the game files and saves in the app are kept.

SideStore installs the app under its own bundle ID, which is a different app from one
installed with Xcode: its saves aren't shared. Turn on Steam Cloud in the old app
and let it sync before you switch, then sync in the new one.

## How it is built

See [Releasing](RELEASING.md): a workflow in the private development repository builds
the unsigned IPA and publishes it, with this source, as a release of the public repo.

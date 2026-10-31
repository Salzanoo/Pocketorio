# probe/steam

Steam Cloud saves, built as `Frameworks/FactoriduoSteam.dylib` by
`tools/steam_cloud.py`. See [docs/STEAM_CLOUD.md](../../docs/STEAM_CLOUD.md).

- `Madeira/`: Madeira's Swift Steam client, Steam Cloud protocol code and depot downloader (with its C decompressors in `Madeira/C`)
  (github.com/willfaust/Madeira at c2c1b03), changed only where a file says so.
- `Factoriduo/`: Factorio's save mapping and sync, the screens before and after
  the game, the background upload, and stand-ins for the two Madeira parts the
  client calls; and the single app's game download, patch, signing and
  certificate (`GameDownload`, `GamePrepare`, `GameCertificate`), with the
  patcher and signer in `probe/patcher`.

Everything here is GPL-3.0-or-later with the Madeira Converter Exception
(`Madeira/LICENSES`), unlike the MIT rest of the repository.

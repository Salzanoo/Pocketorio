# Releasing

Development happens in a private repository (`Salzanoo/factoriduo`). Big releases
are published to the public one, **[Pocketorio](https://github.com/Salzanoo/Pocketorio)**:
the current source as a single commit, with no history, and a release carrying the
unsigned IPA and the SideStore source. Nothing is published on ordinary pushes.

## One-time setup

1. In the Pocketorio repository, create a fine-grained access token (GitHub >
   Settings > Developer settings > Personal access tokens > Fine-grained tokens) for
   that repository only, with **Contents: Read and write**.
2. In the private repository, **Settings > Secrets and variables > Actions**, add
   it as the secret `PUBLIC_REPO_TOKEN`. (To release to another repository, set the
   variable `PUBLIC_REPO` to `owner/name`.)

## A release

1. Merge what is going out into `main`.
2. **Actions > Release > Run workflow**, enter the version (for example `1.0.0`) and
   keep **Publish** on. Turn **Publish** off to only check that the app builds.
3. The workflow builds the app on one macOS runner (10 minute cap, the SDL build is
   cached), then:
   - pushes the source (without `.github` and without history) to Pocketorio's
     `main` as the commit `Pocketorio v<version>`, tagged `v<version>`;
   - creates the release with `Factoriduo.ipa`, `apps.json` and `icon.png`.
4. SideStore users get it from
   `https://github.com/Salzanoo/Pocketorio/releases/latest/download/apps.json`
   ([SideStore](SIDESTORE.md)).

The source is whatever is in the private `main` when the workflow runs, so the checks
before a release are the ones in this repository: the tests, and a build on a device.
Before the first release, check the tree for anything private (`git grep` for your
name, email, team and device IDs); the public copy has no history, so nothing in old
commits goes with it.

#!/usr/bin/env python3
"""Write a SideStore/AltStore source (apps.json) for a built IPA.

    python3 tools/make_source.py --ipa Factoriduo.ipa --repo owner/factoriduo \
        --tag v0.1.42 --version 0.1.42 --build 42 --output site/apps.json

The source lists the app for SideStore to install and refresh. It and the IPA are
assets of a release of the public repository: the source address,
releases/latest/download/apps.json, never changes, and each build's IPA is under
its own tag. The IPA holds no game files: Factorio is downloaded on the
device (docs/ON_DEVICE.md).
"""
import argparse
import datetime
import json
from pathlib import Path

BUNDLE_ID = 'com.factoriduo.factorio'


def source(repo, tag, version, build, size, date, bundle_id=BUNDLE_ID):
    ipa = f'https://github.com/{repo}/releases/download/{tag}/Factoriduo.ipa'
    latest = f'https://github.com/{repo}/releases/latest/download'
    description = ('Factorio on iPhone and iPad. Downloads the game you own from Steam, patches '
                   'and signs it on the device. No game files are in this app.')
    app = {
        'name': 'Pocketorio',
        'bundleIdentifier': bundle_id,
        'developerName': 'Factoriduo',
        'subtitle': 'Your own Factorio, on the device',
        'localizedDescription': description,
        'iconURL': f'{latest}/icon.png',
        'tintColor': 'D98C1E',
        'screenshotURLs': [],
        'versions': [{'version': version, 'buildVersion': str(build), 'date': date,
                      'localizedDescription': f'Build {build}', 'downloadURL': ipa,
                      'size': size, 'minOSVersion': '26.0'}],
        # The older single-version fields, for clients that don't read "versions".
        'version': version, 'versionDate': date, 'versionDescription': f'Build {build}',
        'downloadURL': ipa, 'size': size,
    }
    return {'name': 'Pocketorio', 'identifier': 'com.factoriduo.source', 'sourceURL': f'{latest}/apps.json',
            'subtitle': 'Factorio for iPhone Duo and iPad', 'apps': [app], 'news': []}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--repo', required=True, help='The public repository the releases are in, owner/name')
    parser.add_argument('--tag', required=True, help='The release the IPA is an asset of')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--date', default=datetime.date.today().isoformat())
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source(args.repo, args.tag, args.version, args.build,
                                             args.ipa.stat().st_size, args.date), indent=2) + '\n')
    print(args.output)


if __name__ == '__main__':
    main()

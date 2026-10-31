#!/usr/bin/env python3
"""Export a game profile from a supported factorio.app, for the build.

    python3 tools/export_profile.py --app /path/to/factorio.app

Run once per Factorio version the port supports, on any copy of the game (your
Steam install on a Mac, say), then commit profiles/<version>.json. The build reads
only the profile (tools/game_profile.py), so it needs no game files. The executable
must be an audited one (tools/config.py); a new version needs a new analysis
first (tools/inspect_executable.py).
"""
import argparse
import json
import plistlib
from pathlib import Path

from config import SUPPORTED_SOURCES, SDL_MAJOR_BY_SHA256, validate_source
from macho import MachO
from game_profile import PROFILES


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--app', type=Path, required=True, help='A factorio.app of an audited version')
    args = parser.parse_args()
    app = args.app.expanduser().resolve()
    digest = validate_source(app)
    version = plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleShortVersionString')
    macho = MachO(app / 'Contents/MacOS/factorio')
    libraries = list(macho.libraries)
    imports, main_offset = [], None
    for symbol in macho.symbols():
        if 'library' in symbol:
            library = symbol['library']
            imports.append([symbol['name'], libraries.index(library) if library in libraries else -1])
        elif symbol['name'] == '_main':
            main_offset = symbol['address'] - 0x100000000
    profile = dict(version=version, sha256=digest, status=SUPPORTED_SOURCES[digest],
                   sdl_major=SDL_MAJOR_BY_SHA256[digest], main_offset=main_offset,
                   libraries=libraries, imports=sorted(imports))
    PROFILES.mkdir(exist_ok=True)
    out = PROFILES / f'{version}.json'
    out.write_text(json.dumps(profile, indent=1) + '\n')
    print(f'{out}: Factorio {version}, {len(imports)} imports from {len(libraries)} libraries.')
    print('Commit it.')


if __name__ == '__main__':
    main()

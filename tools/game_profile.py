"""Game profiles: what the build needs to know about a supported Factorio, in the
repository, so neither the Mac nor CI needs the game (tools/export_profile.py
makes one from a factorio.app, once per version).

A profile (profiles/<version>.json) holds no game code: the executable's SHA-256
and SDL version, the libraries it links, the symbols it imports from them (names
of Apple and system APIs, which ProbeShim stands in for when iOS lacks them), and
the offset of its main. The app icon (assets/AppIcon.png) is Factorio's, Wube's.
"""
import json
import re

from config import ROOT, SETTINGS

PROFILES = ROOT / 'profiles'
ICON = ROOT / 'assets/AppIcon.png'


def version_key(version):
    return tuple(int(part) for part in re.findall(r'\d+', version))


def available():
    return sorted((json.loads(path.read_text()) for path in PROFILES.glob('*.json')),
                  key=lambda profile: version_key(profile['version']))


def load(version=None):
    """The profile to build for: `version`, "factorio_version" in .local-config.json,
    or the newest one."""
    version = version or SETTINGS.get('factorio_version')
    profiles = available()
    if not profiles:
        raise SystemExit('No game profile in profiles/. Make one with tools/export_profile.py --app /path/to/factorio.app')
    if version:
        for profile in profiles:
            if profile['version'] == version:
                return profile
        raise SystemExit(f'No profile for Factorio {version}; there are: ' + ', '.join(p['version'] for p in profiles))
    return profiles[-1]


def imports_by_library(profile):
    """[(library install name, [imported symbol names])] in the executable's load order."""
    names = [[] for _ in profile['libraries']]
    for symbol, index in profile['imports']:
        if 0 <= index < len(names):
            names[index].append(symbol)
    return list(zip(profile['libraries'], names))

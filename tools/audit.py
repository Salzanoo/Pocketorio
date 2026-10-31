#!/usr/bin/env python3
"""The game's imports against the iOS SDK's exports, from its profile."""
import argparse
import json
import subprocess
from pathlib import Path
import yaml
from macho import mobile_path

from config import ROOT
from game_profile import imports_by_library, load as load_profile

# Xcode 27's device SDK describes system libraries with arm64e targets even
# when linking an arm64 app. Keep Catalyst and macOS exports excluded.
IOS_ARM64_TARGETS = {'arm64-ios', 'arm64e-ios', 'arm64e.x1-ios', 'arm64-ios-simulator'}

class TBDLoader(yaml.SafeLoader):
    pass
TBDLoader.add_constructor('!tapi-tbd', lambda loader, node: loader.construct_mapping(node, deep=True))
TBDLoader.add_constructor('!tapi-tbd-v3', lambda loader, node: loader.construct_mapping(node, deep=True))

def sdk_path(sdk):
    return Path(subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip())

def sdk_exports(sdk, install_name, seen=None):
    seen = set() if seen is None else seen
    if install_name in seen:
        return set()
    seen.add(install_name)
    stem = sdk / install_name.lstrip('/')
    path = stem.with_suffix('.tbd') if stem.suffix == '.dylib' else Path(str(stem)+'.tbd')
    if not path.exists():
        return set()
    result = set()
    for doc in yaml.load_all(path.read_text(), Loader=TBDLoader):
        if not doc:
            continue
        for group in doc.get('exports', []) + doc.get('reexports', []):
            targets = group.get('targets', [])
            # Exclude macCatalyst and other platforms from SDK symbol availability.
            if targets and not IOS_ARM64_TARGETS.intersection(targets):
                continue
            result.update(group.get('symbols', []))
            result.update(group.get('weak-symbols', []))
            result.update(group.get('thread-local-symbols', []))
            for name in group.get('objc-classes', []):
                result.update(('_OBJC_CLASS_$_'+name, '_OBJC_METACLASS_$_'+name))
            for name in group.get('objc-ivars', []):
                result.add('_OBJC_IVAR_$_'+name)
            for name in group.get('objc-eh-types', []):
                result.add('_OBJC_EHTYPE_$_'+name)
        for group in doc.get('reexported-libraries', []):
            if not IOS_ARM64_TARGETS.intersection(group.get('targets', ['arm64-ios'])):
                continue
            for library in group['libraries']:
                result.update(sdk_exports(sdk, library, seen))
    return result

def audit(profile, sdk_name):
    """Which of the game's imports the iOS SDK lacks, per library, from its profile
    (tools/game_profile.py): what ProbeShim stands in for. Writes
    reports/audit-<sdk>.json, which tools/build_probe.py reads."""
    sdk = sdk_path(sdk_name)
    libraries = []
    for library, required in imports_by_library(profile):
        destination = mobile_path(library)
        exports = sdk_exports(sdk, destination)
        missing = [dict(name=name, library=library) for name in required if name not in exports]
        libraries.append(dict(original=library, mobile=destination, sdk_has_exports=bool(exports),
                              import_count=len(required), missing=missing))
    result = dict(version=profile['version'], sha256=profile['sha256'], sdk=str(sdk),
                  imports=len(profile['imports']), libraries=libraries,
                  entrypoints=[dict(name='_main', address=0x100000000 + profile['main_offset'])])
    out = ROOT/'reports'
    out.mkdir(exist_ok=True)
    (out/f'audit-{sdk_name}.json').write_text(json.dumps(result, indent=2)+'\n')
    lines = [f'# Factorio {result["version"]}: ARM64 import audit', '',
             f'Source SHA-256: `{result["sha256"]}`', '',
             f'{result["imports"]} imported symbols.', '',
             'This checks SDK exports, not ABI or runtime compatibility. Missing weak imports may be optional.', '',
             '| Library | Imports | Absent from SDK exports |', '|---|---:|---:|']
    for lib in libraries:
        lines.append(f'| {Path(lib["original"]).name} | {lib["import_count"]} | {len(lib["missing"])} |')
    (out/f'audit-{sdk_name}.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines))
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='The import audit of a game profile against the iOS SDK.')
    parser.add_argument('--version', help='Factorio version (default: the newest profile)')
    parser.add_argument('--sdk', choices=['iphoneos','iphonesimulator'], default='iphoneos')
    args = parser.parse_args()
    audit(load_profile(args.version), args.sdk)

#!/usr/bin/env python3
"""Build probe/steam (Steam Cloud saves) into FactoriduoSteam.dylib.

Needs only Xcode, not the game, so CI can run it on its own:
    python3 tools/steam_cloud.py --sdk iphoneos --output build/ci
tools/build_probe.py calls build() while building the app.
"""
import argparse
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT/'probe/steam'
LIBRARY = 'FactoriduoSteam.dylib'


def sources(*folders):
    return sorted(str(p) for folder in (SOURCES,) + folders for p in folder.rglob('*.swift'))


C_SOURCES = SOURCES/'Madeira/C'


def c_objects(sdk, sdk_root, target_triple):
    """Madeira's C decompressors, compiled outside any app bundle."""
    objects = ROOT/'build'/('steam-objects-'+sdk)
    objects.mkdir(parents=True, exist_ok=True)
    compiled = []
    for source in sorted(C_SOURCES.glob('*.c')):
        output = objects/(source.stem+'.o')
        subprocess.run(['xcrun','--sdk',sdk,'clang','-target',target_triple,'-isysroot',str(sdk_root),
                        '-O2','-c',str(source),'-o',str(output)],check=True)
        compiled.append(str(output))
    return compiled


def swiftc(sdk, sdk_root, target_triple, module):
    return ['xcrun','--sdk',sdk,'swiftc','-target',target_triple,'-sdk',str(sdk_root),
            '-module-name',module,'-swift-version','5','-O','-parse-as-library',
            '-import-objc-header',str(C_SOURCES/'Bridging.h'),'-Xcc','-I'+str(C_SOURCES)]


def build(frameworks, sdk, sdk_root, target_triple):
    """Madeira's Swift Steam client, the save sync and the game download on top of
    it, and the on-device patcher and signer (probe/patcher), as a library
    probe/UIKitEntry.m opens before the game starts."""
    library = Path(frameworks)/LIBRARY
    subprocess.run(swiftc(sdk, sdk_root, target_triple, 'FactoriduoSteam') +
                   ['-emit-library',*sources(ROOT/'probe/patcher'),*c_objects(sdk, sdk_root, target_triple),'-o',str(library),
                    '-Xlinker','-install_name','-Xlinker','@executable_path/Frameworks/'+LIBRARY,
                    '-lz','-llzma'],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(library)],check=True,capture_output=True)
    return library


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--sdk', choices=['iphoneos','iphonesimulator'], default='iphoneos')
    parser.add_argument('--output', type=Path, default=ROOT/'build/steam-cloud')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sdk_root = subprocess.check_output(['xcrun','--sdk',args.sdk,'--show-sdk-path'], text=True).strip()
    triple = 'arm64-apple-ios26.0'+('-simulator' if args.sdk == 'iphonesimulator' else '')
    print(build(args.output, args.sdk, sdk_root, triple))


if __name__ == '__main__':
    main()

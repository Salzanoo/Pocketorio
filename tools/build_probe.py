#!/usr/bin/env python3
"""Build the app: a launcher that downloads Factorio from Steam on the device,
patches and signs it there, and runs it (docs/ON_DEVICE.md). No game files are
needed: what the build knows about the game comes from its profile in profiles/
(tools/game_profile.py, made by tools/export_profile.py)."""
import argparse
import json
import os
import plistlib
import subprocess
import shutil
from pathlib import Path
from audit import ROOT, sdk_path, audit as generate_audit
from config import DEFAULT_BUNDLE_ID
from macho import MachO, needs_facade, facade_name, raise_sdk_version
from game_profile import ICON, load as load_profile
import steam_cloud


def build_app_icon(app, sdk):
    """The icon from assets/AppIcon.png (tools/make_icon.py), or none."""
    if not ICON.exists():
        print('Note: no assets/AppIcon.png; the app gets no icon')
        return {}
    directory = ROOT/'build'/('app-icon-'+sdk)
    catalog = directory/'Assets.xcassets'
    iconset = catalog/'AppIcon.appiconset'
    iconset.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ICON, iconset/'Factorio.png')
    (iconset/'Contents.json').write_text(json.dumps({
        'images': [{'filename': 'Factorio.png', 'idiom': 'universal',
                    'platform': 'ios', 'size': '1024x1024'}],
        'info': {'author': 'xcode', 'version': 1},
    }, indent=2)+'\n')
    partial_info = directory/'app-icon-info.plist'
    subprocess.run(['xcrun', 'actool', str(catalog), '--compile', str(app),
                    '--platform', sdk, '--minimum-deployment-target', '26.0',
                    '--target-device', 'iphone', '--target-device', 'ipad', '--app-icon', 'AppIcon',
                    '--output-partial-info-plist', str(partial_info)], check=True)
    return plistlib.loads(partial_info.read_bytes())


def build_shim(app, sdk='iphonesimulator', sdl_major=2):
    audit = json.loads((ROOT/'reports/audit-iphoneos.json').read_text())
    directory = ROOT/'build'/('generated-'+sdk)
    directory.mkdir(parents=True, exist_ok=True)
    missing = {s['name'] for lib in audit['libraries'] for s in lib['missing']}
    # nan is provided by libSystem on iOS; macOS happens to bind it to CoreServices.
    missing.discard('_nan')
    missing.discard('_clGetPlatformIDs')
    for steam in ('RestartAppIfNecessary', 'Init', 'GetHSteamUser', 'RunCallbacks', 'Shutdown',
                  'RegisterCallback', 'UnregisterCallback', 'RegisterCallResult', 'UnregisterCallResult'):
        missing.discard('_SteamAPI_'+steam)
    for steam in ('SteamAPI_Init', 'ContextInit', 'FindOrCreateUserInterface'):
        missing.discard('_SteamInternal_'+steam)
    classes = sorted({s.split('$_')[1] for s in missing if s.startswith('_OBJC_')})
    classes = [c for c in classes if c not in ('NSColorSpace','NSBitmapImageRep')]
    lines = ['#import <Foundation/Foundation.h>', '#include <stdio.h>', '#include <stdlib.h>', '#include <execinfo.h>',
             '__attribute__((noreturn)) static void unavailable(const char *s) {',
             'fprintf(stderr, "FACTORIO_PROBE_UNIMPLEMENTED: %s\\n", s); void *bt[32]; int n=backtrace(bt,32); backtrace_symbols_fd(bt,n,2); fflush(stderr); abort(); }']
    for cls in classes:
        lines += [f'@interface {cls}: NSObject @end', f'@implementation {cls}',
                  '- (void)doesNotRecognizeSelector:(SEL)s { unavailable(sel_getName(s)); }',
                  '+ (void)doesNotRecognizeSelector:(SEL)s { unavailable(sel_getName(s)); }', '@end']
    for i, symbol in enumerate(sorted(missing)):
        if symbol.startswith('_OBJC_'):
            continue
        if symbol == '_NSApp':
            lines.append('id NSApp = nil;')
        elif symbol == '_NSAppKitVersionNumber':
            lines.append('double NSAppKitVersionNumber = 0;')
        elif symbol.startswith('_k') or (symbol.startswith('_NS') and symbol != '_NSRectFill'):
            lines.append(f'NSString * const {symbol[1:]} = @"{symbol[1:]}";')
        else:
            lines += [f'void probe_trap_{i}(void) __asm__("{symbol}");',
                      f'void probe_trap_{i}(void) {{ unavailable("{symbol}"); }}']
    source = directory/'ProbeShim.m'
    source.write_text('\n'.join(lines)+'\n')
    frameworks = app/'Frameworks'
    frameworks.mkdir(exist_ok=True)
    library = frameworks/'ProbeShim.dylib'
    target_triple='arm64-apple-ios26.0'+('-simulator' if sdk=='iphonesimulator' else '')
    sdk_root=str(sdk_path(sdk))
    command = ['xcrun','--sdk',sdk,'clang','-target',target_triple,
               '-Werror=property-attribute-mismatch','-Werror=objc-property-synthesis',
               '-isysroot',sdk_root,'-dynamiclib','-fobjc-arc',str(source),str(ROOT/'probe/PlatformFallbacks.m'),
               str(ROOT/'probe/BitmapCompat.m'),str(ROOT/'probe/SteamCloud.mm'),'-lc++','-framework','ImageIO',
               '-framework','Accelerate',
               '-o',str(library),'-install_name','@executable_path/Frameworks/ProbeShim.dylib',
               '-Wl,-reexport-lSystem','-Wl,-reexport-lobjc','-Wl,-reexport-lresolv']
    # The UIKit entry, touch controls and SDL: the app around the game.
    sdl_name = 'libSDL2.dylib' if sdl_major == 2 else 'libSDL3.dylib'
    source = ROOT/'build/vendor'/('SDL-release-2.30.9' if sdl_major == 2 else 'SDL-release-3.4.14')
    command += [str(ROOT/'probe/UIKitEntry.m'),str(ROOT/'probe/MetalCompat.m'),
                str(ROOT/'probe/TouchControls.m'),str(ROOT/'probe/TouchInput.m'),
                str(ROOT/'probe/TouchGestures.m'),'-I'+str(source/'include'),
                f'-DFPI_SDL_MAJOR={sdl_major}',
                '-framework','UIKit','-framework','GameController']
    command += [str(ROOT/'probe/FootprintLog.c'),str(ROOT/'probe/FilePages.c')]
    steam_cloud.build(frameworks, sdk, sdk_root, target_triple)
    if sdl_major == 3:
        command += ['-I'+str(source/'include/SDL3')]
    sdl = frameworks/sdl_name
    sdl_build=('sdl' if sdl_major == 2 else 'sdl3')+('-simulator' if sdk=='iphonesimulator' else '-iphoneos')
    dylib = 'libSDL2-2.0.0.dylib' if sdl_major == 2 else 'libSDL3.0.dylib'
    shutil.copyfile(ROOT/'build'/sdl_build/dylib,sdl)
    subprocess.run(['install_name_tool','-id','@executable_path/Frameworks/'+sdl_name,str(sdl)],check=True)
    classes = ({'SDL_RumbleMotor':'FPI_RumbleMotor','SDL_RumbleContext':'FPI_RumbleContext',
                'SDL_VideoData':'FPI_VideoData','SDL_WindowData':'FPI_WindowData'}
               if sdl_major == 2 else
               {'SDL3METAL_PaletteData':'FPI3METAL_PaletteData',
                'SDL3METAL_RenderData':'FPI3METAL_RenderData',
                'SDL3METAL_TextureData':'FPI3METAL_TextureData',
                'SDL3_RumbleContext':'FPI3_RumbleContext',
                'SDL3_RumbleMotor':'FPI3_RumbleMotor',
                'SDLCaptureVideoDataOutputSampleBufferDelegate':'FPICaptureVideoDataOutputSampleBufferDelegate',
                'SDLPrivateCameraData':'FPIPrivateCameraData'})
    rename_objc_classes(sdl, classes)
    subprocess.run(['codesign','--force','--sign','-',str(sdl)],check=True,capture_output=True)
    command += ['-Wl,-reexport_library,'+str(sdl)]
    for lib in audit['libraries']:
        if '.framework/' in lib['mobile'] and lib['sdk_has_exports']:
            command += ['-Wl,-reexport_framework,'+Path(lib['mobile']).name]
    subprocess.run(command, check=True)
    rename_objc_classes(library, {'NSColor':'FPColor'})
    subprocess.run(['codesign','--force','--sign','-',str(library)], check=True)
    # Preserve each original ordinal with a distinct reexporting facade. Modern
    # dyld rejects duplicate LC_LOAD_DYLIB names even when their ordinals differ.
    empty = directory/'Facade.c'
    empty.write_text('/* Reexports only. */\n')
    replacements = {}
    for i, lib in enumerate(audit['libraries']):
        if not needs_facade(lib['original']):
            continue
        name = facade_name(i)
        target = frameworks/name
        install = '@executable_path/Frameworks/'+name
        subprocess.run(['xcrun','--sdk',sdk,'clang',
                        '-target',target_triple,'-isysroot',sdk_root,
                        '-dynamiclib',str(empty),'-o',str(target),'-install_name',install,
                        '-Wl,-reexport_library,'+str(library),'-L'+str(frameworks)], check=True)
        subprocess.run(['codesign','--force','--sign','-',str(target)],check=True, capture_output=True)
        replacements[lib['original']] = install
    return replacements

def build_launcher(app, sdk, sdl_major):
    """The single app's executable: probe/Launcher.c, which starts ProbeShim's
    launcher. The game itself is downloaded, patched and signed on the device."""
    target_triple = 'arm64-apple-ios26.0'+('-simulator' if sdk=='iphonesimulator' else '')
    subprocess.run(['xcrun','--sdk',sdk,'clang','-target',target_triple,'-isysroot',str(sdk_path(sdk)),
                    str(ROOT/'probe/Launcher.c'),str(app/'Frameworks/ProbeShim.dylib'),
                    '-o',str(app/'FactorioProbe')],check=True)


# The newest SDK the Duo needs to fill its inner display. The runner that builds
# the IPA may have an older Xcode (26.5 when this was written), so the build says
# its binaries were built with this one (tools/macho.py raise_sdk_version).
MINIMUM_SDK = '27.2'


def claim_minimum_sdk(app):
    """Raise the SDK version recorded in every Mach-O file of the app, then sign the
    changed ones again (ad hoc; SideStore or Xcode signs the app for real)."""
    for path in [app/'FactorioProbe', *sorted((app/'Frameworks').glob('*.dylib'))]:
        data = bytearray(path.read_bytes())
        if raise_sdk_version(data, MINIMUM_SDK):
            path.write_bytes(data)
            subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True, capture_output=True)
            print(f'{path.name}: SDK version raised to {MINIMUM_SDK}')


def rename_objc_classes(path, replacements):
    m = MachO(path)
    section = next(s for s in m.sections if s['name']=='__objc_classname')
    start,end = section['offset'],section['offset']+section['size']
    data = m.data
    for old,new in replacements.items():
        assert len(old)==len(new)
        needle = old.encode()+b'\0'
        at = data.find(needle,start,end)
        if at<0:
            raise ValueError('Missing Objective-C metadata name: '+old)
        data[at:at+len(old)] = new.encode()
    path.write_bytes(data)

def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--bundle-id', default=DEFAULT_BUNDLE_ID)
    parser.add_argument('--sdk', choices=['iphoneos', 'iphonesimulator'], default='iphonesimulator')
    parser.add_argument('--version', help='The Factorio version to build for (default: "factorio_version" '
                                          'in .local-config.json, or the newest profile)')
    args = parser.parse_args()
    profile = load_profile(args.version)
    sdl_major = profile['sdl_major']
    print(f'Building for Factorio {profile["version"]} ({profile["status"]})')
    generate_audit(profile, 'iphoneos')
    app = ROOT/('build/FactorioProbe.app' if args.sdk == 'iphonesimulator' else 'build/iphoneos/FactorioProbe.app')
    if app.exists():
        shutil.rmtree(app)
    app.mkdir(parents=True, exist_ok=True)
    build_shim(app, args.sdk, sdl_major)
    build_launcher(app, args.sdk, sdl_major)
    info = dict(CFBundleExecutable='FactorioProbe', CFBundleIdentifier=args.bundle_id,
                # The Factorio this app's ProbeShim was built for.
                FactoriduoGameSHA256=profile['sha256'], FactoriduoGameVersion=profile['version'],
                CFBundleName='Factorio', CFBundleDisplayName='Factorio',
                CFBundlePackageType='APPL',
                # CI numbers its builds (.github/workflows/sidestore.yml).
                CFBundleVersion=os.environ.get('FACTORIDUO_BUILD', '1'),
                CFBundleShortVersionString=os.environ.get('FACTORIDUO_VERSION', '0.1'),
                CFBundleSupportedPlatforms=['iPhoneSimulator' if args.sdk == 'iphonesimulator' else 'iPhoneOS'],
                MinimumOSVersion='26.0', UIDeviceFamily=[1, 2], LSRequiresIPhoneOS=True, UILaunchScreen={},
                UISupportedInterfaceOrientations=['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight',
                                                  'UIInterfaceOrientationPortrait'],
                UIApplicationSupportsIndirectInputEvents=True, UIStatusBarHidden=True,
                UIViewControllerBasedStatusBarAppearance=False, UIRequiresFullScreen=True,
                # Long-press the icon for these (probe/UIKitEntry.m).
                UIApplicationShortcutItems=[dict(UIApplicationShortcutItemType='safe-mode',
                                                 UIApplicationShortcutItemTitle='Safe mode',
                                                 UIApplicationShortcutItemSubtitle='Start without mods',
                                                 UIApplicationShortcutItemIconSymbolName='shield'),
                                            dict(UIApplicationShortcutItemType='steam-cloud',
                                                 UIApplicationShortcutItemTitle='Settings',
                                                 UIApplicationShortcutItemSubtitle='Steam, game files and display',
                                                 UIApplicationShortcutItemIconSymbolName='gearshape')])
    info.update(build_app_icon(app, args.sdk))
    (app/'Info.plist').write_bytes(plistlib.dumps(info))
    claim_minimum_sdk(app)
    # The app's entitlements (the larger memory limit), as Xcode applies them from
    # the project; a signature without them drops them, and SideStore signs again
    # with only what the IPA already carries.
    entitlements = Path(__file__).resolve().parent.parent / 'FactorioProbe.entitlements'
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True)
    print(app)


if __name__ == '__main__':
    main()

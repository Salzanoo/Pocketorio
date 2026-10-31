#!/usr/bin/env python3
"""Validate local prerequisites and prepare an isolated Python environment."""
import argparse
import json
import platform
import shutil
import subprocess
import sys
import venv
from pathlib import Path
from config import ROOT, CONFIG_PATH
from game_profile import available

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    args = parser.parse_args()
    if sys.version_info < (3, 12):
        parser.error('Python 3.12 or newer is required.')
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        parser.error('Run natively on an Apple Silicon Mac (not under Rosetta).')
    profiles = available()
    if not profiles:
        parser.error('No game profile in profiles/. Export one with tools/export_profile.py --app /path/to/factorio.app')
    print('Game profiles:', ', '.join(p['version'] for p in profiles), flush=True)
    cmake = shutil.which('cmake')
    if not cmake:
        parser.error('CMake is missing. Install it and ensure cmake is in PATH, then retry.')
    subprocess.run(['xcodebuild', '-version'], check=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
    if int(sdk.split('.')[0]) < 26:
        parser.error(f'iOS SDK 26 or newer is required; found {sdk}. Select the full Xcode installation.')
    for directory in ('build', 'reports'):
        (ROOT / directory).mkdir(exist_ok=True)
    python = ROOT / '.venv/bin/python'
    if not python.exists():
        venv.EnvBuilder(with_pip=True).create(ROOT / '.venv')
    subprocess.run([str(python), '-m', 'pip', 'install', '-r', str(ROOT / 'requirements.txt')], check=True)
    settings = json.loads(CONFIG_PATH.read_text()) if CONFIG_PATH.exists() else {}
    settings.pop('factorio_app', None)
    settings.update(cmake=cmake)
    CONFIG_PATH.write_text(json.dumps(settings, indent=2) + '\n')
    print('\nSetup complete. Local paths are saved in ignored .local-config.json.')
    print('Next: run "Install Factorio.command", or open FactorioProbe.xcodeproj, select your team and device, then Run.')

if __name__ == '__main__':
    main()

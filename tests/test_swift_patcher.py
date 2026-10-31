"""The on-device patcher (probe/patcher, Swift) against the Mac one (tools/macho.py +
tools/entrypoint.py) on a synthetic game: they must write the same bytes.

The Python checks always run. The Swift comparison runs when FACTORIDUO_PATCHER
names a built patcher (CI builds it on Linux):
    swiftc -O probe/patcher/*.swift tools/patcher/main.swift -o build/patcher
    FACTORIDUO_PATCHER=build/patcher python3 -m unittest tests.test_swift_patcher
"""
import contextlib
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from macho import MachO, library_replacements
from entrypoint import inject_entry
import synthetic_game

SDK = '26.2'
PATCHER = os.environ.get('FACTORIDUO_PATCHER')


def build_fixture(folder, tight):
    folder = Path(folder)
    game = folder / 'factorio'
    game.write_bytes(synthetic_game.universal(synthetic_game.game_slice(tight)))
    frameworks = folder / 'python' / 'Frameworks'
    frameworks.mkdir(parents=True)
    (frameworks / 'libSDL3.dylib').write_bytes(synthetic_game.sdl_library())
    (frameworks / 'ProbeShim.dylib').write_bytes(synthetic_game.shim_library())
    return game, frameworks


def python_patch(game, frameworks):
    """What build_probe.py does to the executable before codesign (device, SDL 3)."""
    macho = MachO(game)
    target = frameworks.parent / 'FactorioProbe'
    macho.retarget(target, 2, library_replacements(macho.libraries), SDK)
    with contextlib.redirect_stdout(io.StringIO()):   # its "Note: unrecognised ..." lines
        report = inject_entry(target, frameworks / 'libSDL3.dylib', False, 3)
    return target.read_bytes(), report


def entry_offset(data):
    count = struct.unpack_from('<I', data, 16)[0]
    pos = 32
    for _ in range(count):
        cmd, size = struct.unpack_from('<II', data, pos)
        if cmd == 0x80000028:
            return struct.unpack_from('<Q', data, pos + 8)[0]
        pos += size
    return None


class PythonPatchTests(unittest.TestCase):
    """The fixture exercises the patch as intended."""

    def test_roomy_layout_needs_no_growth(self):
        with tempfile.TemporaryDirectory() as folder:
            data, report = python_patch(*build_fixture(folder, tight=False))
            self.assertEqual(report['data_zero_fill_growth'], 0)
            self.assertEqual(len(report['sdl_redirects']), synthetic_game.SDL_FUNCTIONS)
            self.assertEqual(entry_offset(data), report['entry_stub_offset'])
            self.assertEqual(len([p for p in report['platform_patches'] if 'Steam Cloud' in p['name']]), 6)
            first = report['sdl_redirects'][0]
            self.assertEqual(struct.unpack_from('<I', data, first['offset'])[0] >> 26, 0b000101)   # b

    def test_tight_layout_grows_zero_fill(self):
        with tempfile.TemporaryDirectory() as folder:
            _, report = python_patch(*build_fixture(folder, tight=True))
            self.assertEqual(report['data_zero_fill_growth'], 0x4000)

    def test_library_replacements(self):
        replacements = library_replacements(synthetic_game.LIBRARIES)
        self.assertEqual(replacements[synthetic_game.LIBRARIES[0]], '@executable_path/Frameworks/P00.dylib')
        self.assertEqual(replacements[synthetic_game.LIBRARIES[1]], '/usr/lib/libc++.1.dylib')
        self.assertEqual(replacements[synthetic_game.LIBRARIES[2]], '@executable_path/Frameworks/P02.dylib')


@unittest.skipUnless(PATCHER, 'set FACTORIDUO_PATCHER to a built probe/patcher to compare')
class SwiftMatchesPythonTests(unittest.TestCase):
    def check(self, tight):
        with tempfile.TemporaryDirectory() as folder:
            game, frameworks = build_fixture(folder, tight)
            expected, report = python_patch(game, frameworks)
            output = Path(folder) / 'swift-FactorioProbe'
            run = subprocess.run([PATCHER, str(game), str(frameworks), SDK, str(output)],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            swift = json.loads(run.stdout)
            actual = output.read_bytes()
            if actual != expected:
                at = next((i for i in range(min(len(actual), len(expected))) if actual[i] != expected[i]), None)
                self.fail(f'Swift and Python differ: {len(actual)} vs {len(expected)} bytes, first at {at}')
            self.assertEqual(swift['entryStubOffset'], report['entry_stub_offset'])
            self.assertEqual(swift['pointerSlotOffset'], report['pointer_slot_offset'])
            self.assertEqual(swift['bindStreamOffset'], report['bind_stream_offset'])
            self.assertEqual(swift['dataZeroFillGrowth'], report['data_zero_fill_growth'])
            self.assertEqual(swift['originalEntryOffset'], report['original_entry_offset'])
            self.assertEqual(swift['sdlRedirects'], len(report['sdl_redirects']))
            self.assertEqual([p['name'] for p in swift['platformPatches']], [p['name'] for p in report['platform_patches']])
            self.assertEqual(swift['facades'], ['P00.dylib', 'P02.dylib'])

            # The app's check: the same patch, signed afterwards, still matches.
            signed = Path(folder) / 'signed-FactorioProbe'
            signed.write_bytes(synthetic_game.fake_sign(expected))
            run = subprocess.run([PATCHER, str(game), str(frameworks), SDK, str(output), '--compare', str(signed)],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn('Matches', run.stdout)
            # And a changed byte is caught.
            tampered = bytearray(synthetic_game.fake_sign(expected))
            tampered[report['entry_stub_offset']] ^= 1
            signed.write_bytes(tampered)
            run = subprocess.run([PATCHER, str(game), str(frameworks), SDK, str(output), '--compare', str(signed)],
                                 capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn(f'offset {report["entry_stub_offset"]}', run.stderr)

    def test_roomy_layout(self):
        self.check(tight=False)

    def test_tight_layout(self):
        self.check(tight=True)


if __name__ == '__main__':
    unittest.main()

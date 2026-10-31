import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from macho import packed_version, raise_sdk_version


def macho(sdk, magic=0xfeedfacf, extra_command=True):
    """A thin arm64 Mach-O header with one other command and LC_BUILD_VERSION."""
    other = struct.pack('<II8x', 0x1b, 16) if extra_command else b''   # LC_UUID-sized filler
    build = struct.pack('<IIIIIII', 0x32, 24, 2, packed_version('26.0'), packed_version(sdk), 0, 0)[:24]
    commands = other + build
    count = (1 if extra_command else 0) + 1
    return bytearray(struct.pack('<IIIIIIII', magic, 0x0100000c, 0, 2, count, len(commands), 0, 0) + commands)


class RaiseSdkVersionTests(unittest.TestCase):
    def sdk(self, data):
        offset = 32 + (16 if len(data) > 56 else 0)
        return struct.unpack_from('<I', data, offset + 16)[0]

    def test_raises_an_older_sdk(self):
        data = macho('26.5')
        self.assertTrue(raise_sdk_version(data, '27.2'))
        self.assertEqual(self.sdk(data), packed_version('27.2'))

    def test_leaves_a_newer_or_equal_sdk(self):
        for sdk in ('27.2', '27.4', '28.0'):
            data = macho(sdk)
            before = bytes(data)
            self.assertFalse(raise_sdk_version(data, '27.2'))
            self.assertEqual(bytes(data), before)

    def test_only_the_sdk_field_changes(self):
        data = macho('26.5')
        before = bytes(data)
        raise_sdk_version(data, '27.2')
        changed = [i for i in range(len(data)) if data[i] != before[i]]
        self.assertTrue(changed and all(64 <= i < 68 for i in changed), changed)

    def test_ignores_files_that_are_not_thin_64_bit(self):
        for data in (bytearray(b'not a mach-o file at all, really' * 2), macho('26.5', magic=0xcafebabe), bytearray(10)):
            before = bytes(data)
            self.assertFalse(raise_sdk_version(data, '27.2'))
            self.assertEqual(bytes(data), before)

    def test_no_build_version_command_changes_nothing(self):
        data = bytearray(struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0) + struct.pack('<II8x', 0x1b, 16))
        self.assertFalse(raise_sdk_version(data, '27.2'))


if __name__ == '__main__':
    unittest.main()

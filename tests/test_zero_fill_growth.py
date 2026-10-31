"""entrypoint.grow_zero_fill on synthetic load commands (no game files)."""
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from entrypoint import grow_zero_fill


def segment(name, vmaddr, vmsize):
    command = bytearray(72)
    struct.pack_into('<II16sQQ', command, 0, 0x19, 72, name, vmaddr, vmsize)
    return command


def image(*specs):
    data = bytearray(32)
    segments = []
    for name, vmaddr, vmsize in specs:
        segments.append((len(data), name))
        data += segment(name, vmaddr, vmsize)
    return data, segments


def vm(data, at):
    return struct.unpack_from('<QQ', data, at + 24)


class ZeroFillGrowthTests(unittest.TestCase):
    def test_adjacent_linkedit_moves_up_by_one_page(self):
        data, segments = image((b'__TEXT', 0x100000000, 0x4000), (b'__DATA', 0x100004000, 0x8000),
                               (b'__LINKEDIT', 0x10000c000, 0x4000))
        growth = grow_zero_fill(data, segments, segments[1][0], 38)   # 2.1.24's shortfall
        self.assertEqual(growth, 0x4000)
        self.assertEqual(vm(data, segments[1][0]), (0x100004000, 0xc000))
        self.assertEqual(vm(data, segments[2][0]), (0x100010000, 0x4000))
        self.assertEqual(vm(data, segments[0][0]), (0x100000000, 0x4000))

    def test_gap_before_linkedit_is_used_without_moving_it(self):
        data, segments = image((b'__DATA', 0x100004000, 0x8000), (b'__LINKEDIT', 0x100020000, 0x4000))
        grow_zero_fill(data, segments, segments[0][0], 1)
        self.assertEqual(vm(data, segments[1][0]), (0x100020000, 0x4000))

    def test_growth_covers_every_missing_slot(self):
        data, segments = image((b'__DATA', 0x100004000, 0x8000), (b'__LINKEDIT', 0x10000c000, 0x4000))
        self.assertEqual(grow_zero_fill(data, segments, segments[0][0], 2049), 0x8000)

    def test_refuses_when_another_segment_follows(self):
        data, segments = image((b'__DATA', 0x100004000, 0x8000), (b'__OTHER', 0x10000c000, 0x4000),
                               (b'__LINKEDIT', 0x100010000, 0x4000))
        with self.assertRaises(ValueError):
            grow_zero_fill(data, segments, segments[0][0], 1)


if __name__ == '__main__':
    unittest.main()

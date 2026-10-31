"""The on-device library conversion and code signer (probe/patcher/GameLibrary.swift,
CodeSigner.swift), checked without trusting the Swift:

- the synthetic game (tests/synthetic_game.py), patched as build_probe.py does,
  becomes a library: MH_DYLIB, LC_ID_DYLIB first, __PAGEZERO one page;
- every page hash of both CodeDirectories is recomputed here;
- openssl verifies the CMS signature and its message digest over the CodeDirectory,
  and the cdhashes attribute holds both CodeDirectories' hashes;
- on macOS, Apple's codesign reads the signature (CodeDirectory v20400, the team).

A throwaway self-signed certificate stands in for the developer's. Runs when
FACTORIDUO_PATCHER names a built patcher (see tests/test_swift_patcher.py).
"""
import hashlib
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_swift_patcher import build_fixture, python_patch   # noqa: E402

PATCHER = os.environ.get('FACTORIDUO_PATCHER')
TEAM = 'TEAMID1234'
PAGE = 4096


def commands(data):
    count = struct.unpack_from('<I', data, 16)[0]
    pos, result = 32, []
    for _ in range(count):
        cmd, size = struct.unpack_from('<II', data, pos)
        result.append((cmd, pos, size))
        pos += size
    return result


def code_directory(blob):
    (magic, length, version, flags, hash_offset, ident_offset, special, slots, code_limit) = struct.unpack_from('>9I', blob, 0)
    hash_size, hash_type, platform, page_shift = blob[36], blob[37], blob[38], blob[39]
    team_offset = struct.unpack_from('>I', blob, 48)[0]
    exec_limit = struct.unpack_from('>Q', blob, 72)[0]
    ident = blob[ident_offset:blob.index(b'\0', ident_offset)].decode()
    team = blob[team_offset:blob.index(b'\0', team_offset)].decode() if team_offset else None
    return dict(magic=magic, length=length, version=version, hash_offset=hash_offset, special=special, slots=slots,
                code_limit=code_limit, hash_size=hash_size, hash_type=hash_type, page_shift=page_shift,
                ident=ident, team=team, exec_limit=exec_limit, blob=blob[:length])


def cms_of(data):
    """The CMS blob of a signed Mach-O's code signature."""
    sig = next(p for c, p, s in commands(data) if c == 0x1d)
    dataoff, datasize = struct.unpack_from('<II', data, sig + 8)
    blob = data[dataoff:dataoff + datasize]
    count = struct.unpack_from('>I', blob, 8)[0]
    for i in range(count):
        kind, offset = struct.unpack_from('>II', blob, 12 + 8 * i)
        if kind == 0x10000:
            length = struct.unpack_from('>I', blob, offset + 4)[0]
            return blob[offset + 8:offset + length]
    return b''


@unittest.skipUnless(PATCHER and shutil.which('openssl'), 'needs FACTORIDUO_PATCHER and openssl')
class CodeSignerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        folder = Path(cls.folder.name)
        game, frameworks = build_fixture(folder, tight=True)
        patched, cls.report = python_patch(game, frameworks)
        cls.patched = folder / 'patched'
        cls.patched.write_bytes(patched)
        cls.key, cert = folder / 'key.pem', folder / 'cert.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(cls.key),
                        '-out', str(cert), '-days', '30',
                        '-subj', f'/CN=Apple Development: Test ({TEAM})/OU={TEAM}/O=Test/C=US',
                        # A leaf for code signing, as Apple's development certificates are.
                        '-addext', 'basicConstraints=critical,CA:FALSE',
                        '-addext', 'keyUsage=critical,digitalSignature',
                        '-addext', 'extendedKeyUsage=critical,codeSigning'],
                       check=True, capture_output=True)
        cls.cert_pem = cert
        cls.cert = folder / 'cert.der'
        subprocess.run(['openssl', 'x509', '-in', str(cert), '-outform', 'DER', '-out', str(cls.cert)], check=True)
        cls.output = folder / 'Factorio.dylib'
        run = subprocess.run([PATCHER, 'sign', str(cls.patched), str(cls.output), '--certificate', str(cls.cert),
                              '--key', str(cls.key), '--library', 'Factorio.dylib', '--identifier', 'com.factoriduo.game'],
                             capture_output=True, text=True)
        if run.returncode:
            raise AssertionError(run.stderr)
        cls.data = cls.output.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def signature(self):
        sig = next((p, s) for c, p, s in commands(self.data) if c == 0x1d)
        dataoff, datasize = struct.unpack_from('<II', self.data, sig[0] + 8)
        blob = self.data[dataoff:dataoff + datasize]
        magic, length, count = struct.unpack_from('>III', blob, 0)
        self.assertEqual(magic, 0xfade0cc0)
        slots = {}
        for i in range(count):
            kind, offset = struct.unpack_from('>II', blob, 12 + 8 * i)
            slots[kind] = blob[offset:]
        return dataoff, slots

    def test_is_a_library(self):
        data = self.data
        self.assertEqual(struct.unpack_from('<I', data, 12)[0], 6)              # MH_DYLIB
        flags = struct.unpack_from('<I', data, 24)[0]
        self.assertTrue(flags & 0x100000)
        self.assertFalse(flags & 0x200000)
        cmds = commands(data)
        cmd, pos, size = cmds[0]
        self.assertEqual(cmd, 0xd)                                              # LC_ID_DYLIB first
        name_at = struct.unpack_from('<I', data, pos + 8)[0]
        self.assertEqual(data[pos + name_at:data.index(b'\0', pos + name_at)], b'Factorio.dylib')
        zero = next(p for c, p, s in cmds if c == 0x19 and data[p + 8:p + 24].rstrip(b'\0') == b'__PAGEZERO')
        self.assertEqual(struct.unpack_from('<QQ', data, zero + 24), (0x100000000 - 0x4000, 0x4000))
        self.assertEqual(cmds[-1][0], 0x1d)                                     # LC_CODE_SIGNATURE last
        # Everything the patch wrote is still there, shifted only in the load commands.
        original = self.patched.read_bytes()
        end = 32 + struct.unpack_from('<I', data, 20)[0]
        stub = self.report['entry_stub_offset']
        self.assertGreaterEqual(stub, end)
        self.assertEqual(data[stub:len(original)], original[stub:])

    def test_linkedit_covers_the_signature(self):
        dataoff, _ = self.signature()
        sig = next(p for c, p, s in commands(self.data) if c == 0x1d)
        datasize = struct.unpack_from('<I', self.data, sig + 12)[0]
        linkedit = next(p for c, p, s in commands(self.data) if c == 0x19 and self.data[p + 8:p + 24].rstrip(b'\0') == b'__LINKEDIT')
        vmsize, fileoff, filesize = struct.unpack_from('<QQQ', self.data, linkedit + 32)
        self.assertEqual(fileoff + filesize, dataoff + datasize)
        self.assertEqual(len(self.data), dataoff + datasize)
        self.assertGreaterEqual(vmsize, filesize)

    def test_code_directories(self):
        dataoff, slots = self.signature()
        magic, length = struct.unpack_from('>II', slots[2], 0)
        self.assertEqual(magic, 0xfade0c01)
        requirements = slots[2][:length]
        # The designated requirement: identifier, the leaf's CN, Apple's WWDR marker OID.
        self.assertIn(b'com.factoriduo.game', requirements)
        self.assertIn(f'Apple Development: Test ({TEAM})'.encode(), requirements)
        self.assertIn(bytes.fromhex('2a864886f76364060201'), requirements)
        self.assertNotIn(0x1000, slots)   # one CodeDirectory, SHA-256, as codesign makes for iOS
        for kind, hasher, size, hash_type in ((0, hashlib.sha256, 32, 2),):
            cd = code_directory(slots[kind])
            self.assertEqual((cd['magic'], cd['version'], cd['hash_size'], cd['hash_type'], cd['page_shift']),
                             (0xfade0c02, 0x20400, size, hash_type, 12))
            self.assertEqual(cd['ident'], 'com.factoriduo.game')
            self.assertEqual(cd['team'], TEAM)
            self.assertEqual(cd['code_limit'], dataoff)
            self.assertEqual(cd['slots'], (dataoff + PAGE - 1) // PAGE)
            blob = cd['blob']
            for i in range(cd['slots']):
                page = self.data[i * PAGE:min((i + 1) * PAGE, dataoff)]
                at = cd['hash_offset'] + i * size
                self.assertEqual(blob[at:at + size], hasher(page).digest(), f'page {i}')
            self.assertEqual(cd['special'], 2)
            at = cd['hash_offset'] - 2 * size
            self.assertEqual(blob[at:at + size], hasher(requirements).digest())
            self.assertEqual(blob[at + size:at + 2 * size], bytes(size))

    def test_cms(self):
        _, slots = self.signature()
        cd = code_directory(slots[0])['blob']
        magic, length = struct.unpack_from('>II', slots[0x10000], 0)
        self.assertEqual(magic, 0xfade0b01)
        cms = slots[0x10000][8:length]
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / 'cms.der').write_bytes(cms)
            (folder / 'cd.bin').write_bytes(cd)
            run = subprocess.run(['openssl', 'cms', '-verify', '-inform', 'DER', '-in', str(folder / 'cms.der'),
                                  '-content', str(folder / 'cd.bin'), '-binary', '-noverify', '-out', os.devnull],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            # The signature fails for any other content.
            (folder / 'cd.bin').write_bytes(cd[:-1] + bytes([cd[-1] ^ 1]))
            run = subprocess.run(['openssl', 'cms', '-verify', '-inform', 'DER', '-in', str(folder / 'cms.der'),
                                  '-content', str(folder / 'cd.bin'), '-binary', '-noverify', '-out', os.devnull],
                                 capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
        start = cms.index(b'<?xml')
        end = cms.index(b'</plist>') + len(b'</plist>')
        hashes = plistlib.loads(cms[start:end])['cdhashes']
        self.assertEqual(hashes, [hashlib.sha256(cd).digest()[:20]])
        self.assertIn(hashlib.sha256(cd).digest(), cms)   # 100.9.2, in full
        # The developer certificate and Apple's WWDR and root CAs travel with it.
        self.assertIn(self.cert.read_bytes(), cms)
        self.assertIn(b'Apple Worldwide Developer Relations Certification Authority', cms)

    @unittest.skipUnless(shutil.which('codesign'), 'codesign runs on macOS only')
    def test_codesign_reads_it(self):
        run = subprocess.run(['codesign', '-d', '--verbose=4', str(self.output)], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        details = run.stdout + run.stderr
        self.assertIn('v=20400', details)
        self.assertIn(f'TeamIdentifier={TEAM}', details)
        self.assertIn('Identifier=com.factoriduo.game', details)
        designated = subprocess.run(['codesign', '-d', '-r-', str(self.output)], capture_output=True, text=True)
        self.assertIn('identifier "com.factoriduo.game" and anchor apple generic', designated.stdout + designated.stderr)
        self.assertIn(f'certificate leaf[subject.CN] = "Apple Development: Test ({TEAM})"', designated.stdout + designated.stderr)
        # Not trusted (a self-signed stand-in), but the hashes must hold.
        verify = subprocess.run(['codesign', '--verify', '--verbose=4', str(self.output)], capture_output=True, text=True)
        if 'modified' in verify.stdout + verify.stderr:
            detail = subprocess.run(['codesign', '-d', '--verbose=6', str(self.output)], capture_output=True, text=True)
            print('codesign detail:\n' + detail.stdout + detail.stderr)
            _, slots = self.signature()
            length = struct.unpack_from('>I', slots[0x10000], 4)[0]
            with tempfile.NamedTemporaryFile(suffix='.der') as cms:
                cms.write(slots[0x10000][8:length])
                cms.flush()
                dump = subprocess.run(['openssl', 'cms', '-cmsout', '-print', '-inform', 'DER', '-in', cms.name, '-noout'],
                                      capture_output=True, text=True)
                print('Signature: ' + '\nSignature: '.join(dump.stdout.splitlines()[:120]))
        self.assertNotIn('modified', verify.stdout + verify.stderr, verify.stderr)


    @unittest.skipUnless(shutil.which('codesign') and shutil.which('security'), 'codesign runs on macOS only')
    def test_zz_compare_with_apple(self):
        """Not a check: signs the same library with Apple's codesign and the same
        certificate, and writes both CMS structures to FACTORIDUO_DIAGNOSTICS."""
        folder = Path(self.folder.name)
        out = Path(os.environ.get('FACTORIDUO_DIAGNOSTICS', folder / 'diagnostics.txt'))
        lines = []
        def run(*command, **kwargs):
            result = subprocess.run([str(c) for c in command], capture_output=True, text=True, **kwargs)
            if result.returncode:
                lines.append(f'$ {" ".join(map(str, command))} -> {result.returncode}: {result.stderr.strip()[:300]}')
            return result
        unsigned = folder / 'unsigned.dylib'
        run(PATCHER, 'sign', self.patched, unsigned, '--library', 'Factorio.dylib', '--unsigned', '1')
        p12 = folder / 'id.p12'
        if run('openssl', 'pkcs12', '-export', '-legacy', '-inkey', self.key, '-in', self.cert_pem, '-out', p12,
               '-passout', 'pass:pw', '-name', 'test').returncode:
            run('openssl', 'pkcs12', '-export', '-inkey', self.key, '-in', self.cert_pem, '-out', p12, '-passout', 'pass:pw')
        keychain = folder / 'test.keychain-db'
        run('security', 'create-keychain', '-p', 'pw', keychain)
        run('security', 'unlock-keychain', '-p', 'pw', keychain)
        run('security', 'import', p12, '-k', keychain, '-P', 'pw', '-T', '/usr/bin/codesign')
        run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', 'pw', keychain)
        existing = run('security', 'list-keychains', '-d', 'user').stdout.split()
        run('security', 'list-keychains', '-d', 'user', '-s', keychain, *[e.strip('"') for e in existing])
        apple = folder / 'apple.dylib'
        shutil.copyfile(unsigned, apple)
        fingerprint = hashlib.sha1(self.cert.read_bytes()).hexdigest().upper()
        lines.append('identities: ' + run('security', 'find-identity', '-p', 'codesigning', keychain).stdout.strip().replace('\n', ' | '))
        run('codesign', '-f', '-s', fingerprint, '--keychain', keychain,
            '-i', 'com.factoriduo.game', '--timestamp=none', apple)
        lines.append('apple verify: ' + run('codesign', '--verify', '--verbose=4', apple).stderr.strip())
        lines.append('ours verify: ' + run('codesign', '--verify', '--verbose=4', self.output).stderr.strip())
        for name, path in (('apple', apple), ('ours', self.output)):
            detail = run('codesign', '-d', '--verbose=4', path)
            lines += [f'{name} -d: {l}' for l in (detail.stdout + detail.stderr).splitlines() if '=' in l][:14]
        parsed = {}
        for name, path in (('apple', apple), ('ours', self.output)):
            data = path.read_bytes() if path.exists() else b''
            cms = cms_of(data) if data[:4] == b'\xcf\xfa\xed\xfe' and any(c == 0x1d for c, _, _ in commands(data)) else b''
            (folder / f'{name}.cms').write_bytes(cms)
            dump = run('openssl', 'asn1parse', '-inform', 'DER', '-in', folder / f'{name}.cms', '-i')
            parsed[name] = [l.split(':', 1)[1].strip() if ':' in l else l for l in dump.stdout.splitlines()]
        # Structure only (lengths and offsets differ): tag lines side by side where they differ.
        import difflib, re
        strip = lambda l: re.sub(r'(d=\s*\d+\s+)?hl=\s*\d+\s+l=\s*\d+', '', l)
        a, b = [strip(l) for l in parsed['apple']], [strip(l) for l in parsed['ours']]
        lines.append(f'apple CMS {len(a)} lines, ours {len(b)}')
        lines += list(difflib.unified_diff(a, b, 'apple', 'ours', n=1, lineterm=''))[:150]
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    unittest.main()

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import make_source


class SourceTests(unittest.TestCase):
    def test_source_lists_one_app_with_release_urls(self):
        doc = make_source.source('user/source', 'v0.1.7', '0.1.7', 7, 1234, '2026-10-31')
        app = doc['apps'][0]
        # The source address never changes; the IPA is under its own release.
        self.assertEqual(doc['sourceURL'], 'https://github.com/user/source/releases/latest/download/apps.json')
        self.assertEqual(app['bundleIdentifier'], 'com.factoriduo.factorio')
        version = app['versions'][0]
        self.assertEqual((version['version'], version['buildVersion'], version['size']), ('0.1.7', '7', 1234))
        self.assertEqual(version['downloadURL'], 'https://github.com/user/source/releases/download/v0.1.7/Factoriduo.ipa')
        self.assertEqual(app['iconURL'], 'https://github.com/user/source/releases/latest/download/icon.png')
        # The older fields agree with the newest version.
        self.assertEqual((app['version'], app['downloadURL'], app['size']),
                         (version['version'], version['downloadURL'], version['size']))

    def test_command_line_takes_the_size_from_the_ipa(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / 'a.ipa'
            ipa.write_bytes(b'x' * 99)
            out = Path(directory) / 'site/apps.json'
            subprocess.run([sys.executable, str(ROOT / 'tools/make_source.py'), '--ipa', str(ipa),
                            '--repo', 'h/p', '--tag', 'v1.0.0', '--version', '1.0.0', '--build', '3',
                            '--output', str(out), '--date', '2026-01-02'], check=True, capture_output=True)
            doc = json.loads(out.read_text())
            self.assertEqual(doc['apps'][0]['versions'][0]['size'], 99)
            self.assertEqual(doc['apps'][0]['versions'][0]['date'], '2026-01-02')


if __name__ == '__main__':
    unittest.main()

import importlib.util
import pathlib
import plistlib
import struct
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('inspect_ipa', pathlib.Path(__file__).with_name('inspect_ipa.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class InspectionTests(unittest.TestCase):
    def test_macho_encryption_flag_is_reported_not_assumed(self):
        for flag in (0, 1):
            header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0)
            command = struct.pack('<6I', 0x2c, 24, 0, 0, flag, 0)
            self.assertEqual(audit.macho_inventory(header + command)['encryption_commands'][0]['cryptid'], flag)

    def test_invalid_command_bounds_are_rejected(self):
        header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 8, 0, 0)
        with self.assertRaises(ValueError):
            audit.macho_inventory(header + struct.pack('<2I', 0x2c, 24))

    def test_bundle_identity_comes_from_plist_not_archive_filename(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / 'misleading.ipa'
            header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0)
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps(
                    {'CFBundleIdentifier': 'org.example.actual', 'CFBundleExecutable': 'Test'}))
                archive.writestr('Payload/Test.app/Test', header)
            result = audit.inspect(path)
            self.assertEqual(result['apps'][0]['CFBundleIdentifier'], 'org.example.actual')
            with self.assertRaises(ValueError):
                audit.inspect(path, '0' * 64)


if __name__ == '__main__':
    unittest.main()

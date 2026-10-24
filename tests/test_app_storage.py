"""Exercise the real Swift data migration against isolated temporary directories."""
import pathlib
import subprocess
import tempfile
import unittest


SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'native/Sources/AppStorage.swift'


class AppStorageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler_directory = tempfile.TemporaryDirectory(prefix='deskloom-storage-compiler-')
        root = pathlib.Path(cls.compiler_directory.name)
        cls.binary = root / 'storage-test'
        main = root / 'main.swift'
        main.write_text('''import Foundation
do {
    let directory = try AppStorage.prepare(supportDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
    print(directory.path)
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
''')
        subprocess.run(['/usr/bin/xcrun', 'swiftc', str(SOURCE), str(main), '-o', str(cls.binary)],
                       check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.compiler_directory.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='deskloom-storage-test-')
        self.addCleanup(self.temporary.cleanup)
        self.support = pathlib.Path(self.temporary.name).resolve()
        self.current = self.support / 'DeskLoom'
        self.legacy = self.support / 'ComputerUsePrototype'

    def prepare(self):
        return subprocess.run([str(self.binary), str(self.support)], capture_output=True, text=True, timeout=5)

    def test_existing_data_moves_without_copying_and_legacy_clients_keep_access(self):
        (self.legacy / 'xtdb').mkdir(parents=True)
        fixture = self.legacy / 'xtdb' / 'data.bin'
        fixture.write_bytes(b'unchanged database bytes\x00\xff')
        inode = fixture.stat().st_ino
        (self.legacy / 'appearance.json').write_text('{"selectedIcon":"D"}')
        self.assertEqual(0, self.prepare().returncode)
        self.assertTrue(self.legacy.is_symlink())
        self.assertEqual(self.current, self.legacy.resolve())
        self.assertEqual(inode, (self.current / 'xtdb/data.bin').stat().st_ino)
        self.assertEqual(b'unchanged database bytes\x00\xff', fixture.read_bytes())
        self.assertEqual('{"selectedIcon":"D"}', (self.current / 'appearance.json').read_text())
        self.assertEqual(0, self.prepare().returncode)
        self.assertEqual(inode, fixture.stat().st_ino)

    def test_existing_current_directory_and_old_data_are_never_merged_or_overwritten(self):
        self.current.mkdir()
        self.legacy.mkdir()
        (self.current / 'marker').write_text('new')
        (self.legacy / 'marker').write_text('old')
        result = self.prepare()
        self.assertEqual(1, result.returncode)
        self.assertIn('同时存在', result.stderr)
        self.assertEqual('new', (self.current / 'marker').read_text())
        self.assertEqual('old', (self.legacy / 'marker').read_text())

    def test_unrelated_legacy_symlink_is_preserved(self):
        other = self.support / 'other'
        other.mkdir()
        self.legacy.symlink_to(other)
        result = self.prepare()
        self.assertEqual(1, result.returncode)
        self.assertIn('其他位置', result.stderr)
        self.assertEqual(other, self.legacy.resolve())
        self.assertFalse(self.current.exists())

    def test_new_install_creates_private_data_directory(self):
        self.assertEqual(0, self.prepare().returncode)
        self.assertEqual(0o700, self.current.stat().st_mode & 0o777)


if __name__ == '__main__':
    unittest.main(verbosity=2)

from __future__ import annotations

import io
import tempfile
import unittest
import zipfile
from pathlib import Path

from package_layout import PACKAGE_FILES, PACKAGE_NAME, build_archive, validate_package_files


class PackageLayoutTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='GraphitePearl-PackageTests-')
        self.addCleanup(self.folder.cleanup)
        self.package = Path(self.folder.name)/PACKAGE_NAME
        for name in PACKAGE_FILES:
            path = self.package/name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(name.encode('utf-8'))

    def test_exact_file_list_and_payloads(self):
        self.assertEqual(set(validate_package_files(self.package)),PACKAGE_FILES)
        with zipfile.ZipFile(io.BytesIO(build_archive(self.package))) as archive:
            self.assertEqual(set(archive.namelist()),{PACKAGE_NAME+'/'+name for name in PACKAGE_FILES})
            self.assertEqual(len(archive.namelist()),len(PACKAGE_FILES))
            for name in PACKAGE_FILES:
                self.assertEqual(archive.read(PACKAGE_NAME+'/'+name),(self.package/name).read_bytes())

    def test_missing_cursor_rejected(self):
        (self.package/'cursors/arrow.cur').unlink()
        with self.assertRaisesRegex(ValueError,'缺少文件.*cursors/arrow.cur'):
            build_archive(self.package)

    def test_incomplete_directory_only_allowed_before_build(self):
        (self.package/'manifest.json').unlink()
        self.assertNotIn('manifest.json',validate_package_files(self.package,require_complete=False))
        with self.assertRaisesRegex(ValueError,'缺少文件.*manifest.json'):
            build_archive(self.package)

    def test_ignored_environment_file_rejected(self):
        (self.package/'.env').write_text('AUDIT_FIXTURE=example\n',encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'多余文件.*[.]env'):
            validate_package_files(self.package,require_complete=False)
        with self.assertRaisesRegex(ValueError,'多余文件.*[.]env'):
            build_archive(self.package)

    def test_logs_rejected(self):
        (self.package/'debug.log').write_text('fixture\n',encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'多余文件.*debug.log'):
            build_archive(self.package)

    def test_registry_export_rejected(self):
        path = self.package/'system-backup/registry.clixml'
        path.parent.mkdir()
        path.write_text('fixture\n',encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'多余文件.*registry.clixml'):
            build_archive(self.package)

    def test_local_backups_excluded(self):
        path = self.package/'_备份/Apply_20000101_000000.ps1'
        path.parent.mkdir()
        path.write_text('fixture\n',encoding='utf-8')
        self.assertEqual(set(validate_package_files(self.package)),PACKAGE_FILES)
        with zipfile.ZipFile(io.BytesIO(build_archive(self.package))) as archive:
            self.assertFalse(any('_备份' in name for name in archive.namelist()))


if __name__ == '__main__':
    unittest.main()

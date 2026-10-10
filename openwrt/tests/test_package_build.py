#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package_build', Path(__file__).resolve().parents[1] / 'scripts/package_build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
COMMIT = 'a' * 40


class PackageBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bjut-package-test-')
        self.root = Path(self.temp.name)
        self.source = self.root / 'bin'
        self.output = self.root / 'artifacts'
        self.row = build.build_matrix('ipk', 'x86/64')['include'][0]

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, row=None):
        row = row or self.row
        source = self.source / row['id']
        source.mkdir(parents=True)
        for package in build.PACKAGES:
            version = build.package_version()
            if row['format'] == 'ipk':
                arch = row['arch'] if package == 'bjut-autologin' else 'all'
                name = f'{package}_{version}-1_{arch}.ipk'
            else:
                name = f'{package}-{version}-r1.apk'
            (source / name).write_bytes(b'fixture package contents')
        return source

    def test_matrix_matches_format_to_firmware_and_filters_platform(self):
        matrix = build.build_matrix()['include']
        self.assertEqual(len(matrix), 18)
        self.assertEqual({r['version'] for r in matrix if r['format'] == 'ipk'}, {'24.10.8'})
        self.assertEqual({r['version'] for r in matrix if r['format'] == 'apk'}, {'25.12.5'})
        selected = build.build_matrix('apk', 'ramips/mt7621')['include']
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]['sdk'], 'ramips-mt7621-25.12.5')
        for args in [('zip', 'all'), ('all', '../unknown')]:
            with self.assertRaises(ValueError):
                build.build_matrix(*args)

    def test_workflow_outputs_and_tag_version_guard(self):
        output = self.root / 'github-output'
        env = {**os.environ, 'GITHUB_OUTPUT': str(output)}
        command = [sys.executable, spec.origin, 'plan', '--format', 'apk', '--platform', 'x86/64', '--tag']
        result = subprocess.run(command + ['openwrt-v' + build.package_version()], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        content = output.read_text()
        values = dict(line.split('=', 1) for line in content.splitlines())
        self.assertEqual(len(json.loads(values['matrix'])['include']), 1)
        result = subprocess.run(command + ['openwrt-vwrong-version'], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Release tag must match', result.stderr)
        self.assertEqual(output.read_text(), content)

    def test_collect_preserves_both_package_contents_and_checksums(self):
        source = self.fixture()
        (source / 'unrelated_1.0_x86_64.ipk').write_bytes(b'not published')
        metadata = build.collect_packages(source, self.output, self.row, COMMIT)
        self.assertEqual({f['package'] for f in metadata['files']}, set(build.PACKAGES))
        for entry in metadata['files']:
            self.assertEqual((self.output / entry['name']).read_bytes(), b'fixture package contents')
            self.assertEqual(build.digest(self.output / entry['name']), entry['sha256'])
        self.assertEqual(len(list(self.output.glob('*.ipk'))), 2)

    def test_missing_luci_and_wrong_format_cannot_report_success(self):
        source = self.fixture()
        next(source.glob('luci-*.ipk')).unlink()
        with self.assertRaisesRegex(ValueError, 'luci-app-bjut-autologin'):
            build.collect_packages(source, self.output, self.row, COMMIT)
        apk = build.build_matrix('apk', 'x86/64')['include'][0]
        with self.assertRaisesRegex(ValueError, 'Expected one nonempty apk'):
            build.collect_packages(source, self.output, apk, COMMIT)

    def test_empty_duplicate_and_wrong_architecture_fail(self):
        source = self.fixture()
        core = next(source.glob('bjut-autologin_*.ipk'))
        core.write_bytes(b'')
        with self.assertRaises(ValueError):
            build.collect_packages(source, self.output, self.row, COMMIT)
        core.write_bytes(b'package')
        wrong = core.with_name(core.name.replace('x86_64', 'mips_24kc'))
        core.rename(wrong)
        with self.assertRaisesRegex(ValueError, 'architecture'):
            build.collect_packages(source, self.output, self.row, COMMIT)
        core.write_bytes(b'package')
        with self.assertRaisesRegex(ValueError, 'got 2'):
            build.collect_packages(source, self.output, self.row, COMMIT)

    def test_apk_assets_from_two_architectures_do_not_collide(self):
        matrix = build.build_matrix('apk')['include'][:2]
        for row in matrix:
            build.collect_packages(self.fixture(row), self.output, row, COMMIT)
        build.prepare_release(self.output, {'include': matrix}, COMMIT)
        self.assertEqual(len(list(self.output.glob('*.apk'))), 4)
        checksums = (self.output / 'SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(checksums), 5)
        self.assertEqual(len(json.loads((self.output / 'builds.json').read_text())), 2)

    def test_incomplete_matrix_cannot_publish(self):
        build.collect_packages(self.fixture(), self.output, self.row, COMMIT)
        with self.assertRaisesRegex(ValueError, 'incomplete build matrix'):
            build.prepare_release(self.output, build.build_matrix(), COMMIT)

    def test_tampered_package_cannot_publish(self):
        metadata = build.collect_packages(self.fixture(), self.output, self.row, COMMIT)
        (self.output / metadata['files'][0]['name']).write_bytes(b'changed after upload')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            build.prepare_release(self.output, {'include': [self.row]}, COMMIT)

    def test_mixed_source_revisions_cannot_publish(self):
        build.collect_packages(self.fixture(), self.output, self.row, COMMIT)
        with self.assertRaisesRegex(ValueError, 'Mixed source revisions'):
            build.prepare_release(self.output, {'include': [self.row]}, 'b' * 40)

    def test_core_and_luci_versions_must_match(self):
        for package, version in zip(build.PACKAGES, ['0.3.0', '0.4.0']):
            directory = self.root / 'openwrt' / package
            directory.mkdir(parents=True)
            (directory / 'Makefile').write_text('PKG_VERSION:=' + version + '\n')
        with self.assertRaisesRegex(ValueError, 'versions must match'):
            build.package_version(self.root)

    def test_sdk_prepare_and_compile_use_supported_build_macros(self):
        sdk = self.root / 'sdk'
        (sdk / 'include').mkdir(parents=True)
        (sdk / 'rules.mk').write_text(
            'INCLUDE_DIR=$(TOPDIR)/include\n'
            'PKG_BUILD_DIR=$(TOPDIR)/build/$(PKG_NAME)\n'
            'RM:=rm -f\nCP:=cp -fpR\nINSTALL_DIR:=install -d -m0755\nTARGET_CC:=cc\n'
        )
        (sdk / 'include/package.mk').write_text('')
        core = build.ROOT / 'openwrt/bjut-autologin'
        driver = self.root / 'driver.mk'
        driver.write_text(
            f'include {core}/Makefile\n'
            '.PHONY: check\ncheck:\n\t$(Build/Prepare)\n\t$(Build/Compile)\n'
        )
        result = subprocess.run(['make', '-f', str(driver), 'TOPDIR=' + str(sdk), 'check'],
                                cwd=core, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        directory = sdk / 'build/bjut-autologin'
        self.assertEqual((directory / 'LICENSE').read_bytes(), (core / 'LICENSE').read_bytes())
        self.assertEqual((directory / 'bjut-codec.c').read_bytes(), (core / 'src/bjut-codec.c').read_bytes())
        result = subprocess.run([str(directory / 'bjut-codec'), 'base64'], input=b'test', capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), b'dGVzdA==')
        result = subprocess.run([str(directory / 'bjut-html'), 'captcha'], input=b'<div id="randomDiv" class="hide"></div>', capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'0')


if __name__ == '__main__':
    unittest.main()

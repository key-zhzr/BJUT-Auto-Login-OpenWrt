#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

spec = importlib.util.spec_from_file_location('sync_upstream', Path(__file__).resolve().parents[1] / 'scripts/sync_upstream.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bjut-sync-test-')
        self.repo = Path(self.temp.name)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        (self.repo / 'openwrt').mkdir()
        self.write('README.md', 'upstream original\n')
        self.write('src-tauri/src/portal.rs', 'original\n')
        self.commit('base')
        self.git('branch', 'upstream-main')
        self.write('README.md', 'router introduction\n')
        self.write('openwrt/README.md', 'router manual\n')
        self.commit('port')
        self.main = self.git('rev-parse', 'HEAD')

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self, message):
        self.git('add', '.')
        self.git('commit', '-m', message)

    def upstream(self, file, content):
        self.git('switch', 'upstream-main')
        self.write(file, content)
        self.commit('upstream update')
        self.git('switch', 'main')

    def test_clean_merge_keeps_both_histories_and_router_readme(self):
        self.upstream('README.md', 'new upstream introduction\n')
        result = sync.synchronize(self.repo, 'upstream-main', run_checks=False)
        self.assertEqual(result['state'], 'ready')
        self.assertEqual((self.repo / 'README.md').read_text(), 'router introduction\n')
        self.assertIn('new upstream', (self.repo / 'openwrt/upstream-README.md').read_text())
        self.assertEqual(len(self.git('rev-list', '--parents', '-n', '1', 'HEAD').split()), 3)
        self.assertEqual(self.git('rev-parse', 'main'), self.main)

    def test_protocol_changes_require_review(self):
        self.upstream('src-tauri/src/portal.rs', 'new protocol\n')
        self.assertEqual(sync.synchronize(self.repo, 'upstream-main', False)['state'], 'review')

    def test_conflict_retains_main_and_does_not_claim_upstream_merged(self):
        self.write('src-tauri/src/portal.rs', 'router local\n')
        self.commit('local protocol'); self.main = self.git('rev-parse', 'HEAD')
        self.upstream('src-tauri/src/portal.rs', 'upstream conflicting\n')
        result = sync.synchronize(self.repo, 'upstream-main', False)
        self.assertEqual(result['state'], 'conflict')
        self.assertEqual((self.repo / 'src-tauri/src/portal.rs').read_text(), 'router local\n')
        self.assertEqual(self.git('rev-parse', 'main'), self.main)
        self.assertIn('src-tauri/src/portal.rs', (self.repo / 'openwrt/UPSTREAM-REVIEW.md').read_text())
        self.assertEqual(len(self.git('rev-list', '--parents', '-n', '1', 'HEAD').split()), 2)

    def test_dirty_work_is_never_discarded(self):
        self.upstream('site.txt', 'new\n')
        self.write('README.md', 'unsaved user change\n')
        with self.assertRaisesRegex(RuntimeError, 'not clean'):
            sync.synchronize(self.repo, 'upstream-main', False)
        self.assertEqual((self.repo / 'README.md').read_text(), 'unsaved user change\n')

    def test_failed_validation_aborts_merge(self):
        self.write('openwrt/tests/run_all.py', 'raise SystemExit(1)\n')
        self.commit('validation fixture'); self.main = self.git('rev-parse', 'HEAD')
        self.upstream('website.txt', 'new site\n')
        with self.assertRaisesRegex(RuntimeError, 'validation failed'):
            sync.synchronize(self.repo, 'upstream-main', True)
        self.assertEqual(self.git('rev-parse', 'main'), self.main)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.main)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertFalse((self.repo / 'openwrt/UPSTREAM.lock.json').exists())

    def test_no_changes_is_noop(self):
        self.assertEqual(sync.synchronize(self.repo, 'upstream-main', False)['state'], 'unchanged')


class ReviewPublicationTests(unittest.TestCase):
    def publication(self, pr_exit, state):
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/openwrt-upstream.yml').read_text()
        step = workflow.split('      - name: Preserve review branch and publish review link\n', 1)[1]
        shell = textwrap.dedent(step.split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory(prefix='bjut-review-publication-') as directory:
            root = Path(directory)
            for command, body in {
                'git': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$PUBLISHED"\n',
                'gh': '#!/bin/sh\nexit "$PR_EXIT"\n',
            }.items():
                path = root / command
                path.write_text(body)
                path.chmod(0o755)
            env = os.environ.copy()
            env.update({
                'PATH': str(root) + os.pathsep + env['PATH'],
                'RUNNER_TEMP': str(root), 'PR_EXIT': str(pr_exit),
                'PUBLISHED': str(root / 'published'),
                'SYNC_BRANCH': 'codex/upstream-fixture', 'SYNC_STATE': state,
                'UPSTREAM_SHA': 'a' * 40,
                'GITHUB_SERVER_URL': 'https://github.com',
                'GITHUB_REPOSITORY': 'fixture/router',
                'GITHUB_STEP_SUMMARY': str(root / 'summary.md'),
            })
            result = subprocess.run(['bash', '-c', shell], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            published = (root / 'published').read_text()
            self.assertIn('HEAD:refs/heads/codex/upstream-fixture', published)
            self.assertNotIn('refs/heads/main', published)
            summary = (root / 'summary.md').read_text()
            self.assertIn('compare/main...codex/upstream-fixture?expand=1', summary)
            return summary

    def test_denied_pr_keeps_the_review_branch_and_compare_link(self):
        summary = self.publication(1, 'conflict')
        self.assertIn('存在合并冲突', summary)
        self.assertIn('PR 创建未完成', summary)

    def test_allowed_pr_reports_success_without_publishing_main(self):
        summary = self.publication(0, 'review')
        self.assertIn('已创建待审查 PR', summary)

    def test_failed_main_publication_reports_the_repository_rule_failure(self):
        summary = self.publication(1, 'ready')
        self.assertIn('主分支发布未完成', summary)
        self.assertNotIn('认证或安全相关实现有变化', summary)


if __name__ == '__main__':
    unittest.main()

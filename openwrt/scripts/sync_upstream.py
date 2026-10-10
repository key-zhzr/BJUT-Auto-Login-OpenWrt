#!/usr/bin/env python3
"""Merge a fetched upstream ref on a new branch; never push or discard local work.

The workflow publishes the resulting branch, and advances main only for a
review-free, tested merge. Core changes and conflicts remain on review branches.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

SENSITIVE = ('src-tauri/src/', 'src-tauri/Cargo.', 'src/network-trust', 'openwrt/', '.github/')


def git(repo, *args, check=True):
    return subprocess.run(['git', '-C', str(repo), *args], text=True, capture_output=True, check=check)


def sensitive(paths):
    return [path for path in paths if path.startswith(SENSITIVE)]


def synchronize(repo, ref, run_checks=True):
    repo = Path(repo).resolve()
    if git(repo, 'status', '--porcelain').stdout.strip():
        raise RuntimeError('Working tree is not clean. Commit your work before syncing.')
    upstream = git(repo, 'rev-parse', '--verify', ref + '^{commit}').stdout.strip()
    if git(repo, 'merge-base', '--is-ancestor', upstream, 'HEAD', check=False).returncode == 0:
        return {'state': 'unchanged', 'upstream': upstream, 'branch': ''}
    base = git(repo, 'merge-base', 'HEAD', upstream).stdout.strip()
    changes = git(repo, 'diff', '--name-only', base, upstream).stdout.splitlines()
    review = sensitive(changes)
    branch = 'codex/upstream-' + upstream[:12]
    git(repo, 'switch', '-c', branch)
    merge = git(repo, 'merge', '--no-commit', '--no-ff', upstream, check=False)
    conflicts = git(repo, 'diff', '--name-only', '--diff-filter=U').stdout.splitlines()
    # The independent port owns the root introduction. Keep the upstream copy
    # separately instead of making every upstream README edit a false conflict.
    if 'README.md' in conflicts:
        git(repo, 'checkout', '--ours', '--', 'README.md')
        git(repo, 'add', 'README.md')
        conflicts.remove('README.md')
    merge_started = git(repo, 'rev-parse', '-q', '--verify', 'MERGE_HEAD', check=False).returncode == 0
    if merge.returncode and not conflicts and not merge_started:
        raise RuntimeError('Upstream merge could not start: ' + merge.stderr.strip())
    if conflicts:
        git(repo, 'merge', '--abort', check=False)
        note = '# Upstream merge requires review\n\nUpstream: `' + upstream + '`\n\nConflicting files:\n\n' + '\n'.join('- `' + path + '`' for path in conflicts)
        note += '\n\nNo conflict resolution was applied. Merge this upstream commit locally, resolve the files, port relevant changes and run the OpenWrt tests before merging this review branch.\n'
        (repo / 'openwrt/UPSTREAM-REVIEW.md').write_text(note)
        git(repo, 'add', 'openwrt/UPSTREAM-REVIEW.md')
        git(repo, 'commit', '-m', 'docs(openwrt): record upstream merge conflicts')
        return {'state': 'conflict', 'upstream': upstream, 'branch': branch, 'conflicts': conflicts}
    if run_checks:
        try:
            subprocess.run([sys.executable, str(repo / 'openwrt/tests/run_all.py')], cwd=repo, check=True)
            subprocess.run([sys.executable, str(repo / 'openwrt/tests/test_sync_upstream.py')], cwd=repo, check=True)
        except subprocess.CalledProcessError:
            git(repo, 'merge', '--abort', check=False)
            # Keep diagnostics in the CI log; never commit a failed merge.
            raise RuntimeError('OpenWrt validation failed; main was not changed.') from None
    (repo / 'openwrt/upstream-README.md').write_text(git(repo, 'show', upstream + ':README.md').stdout)
    (repo / 'openwrt/UPSTREAM.lock.json').write_text(json.dumps({'upstream': upstream, 'reviewRequired': review}, indent=2) + '\n')
    git(repo, 'add', 'openwrt/upstream-README.md', 'openwrt/UPSTREAM.lock.json')
    git(repo, 'commit', '-m', 'chore(openwrt): merge upstream ' + upstream[:12])
    return {'state': 'review' if review else 'ready', 'upstream': upstream, 'branch': branch, 'reviewFiles': review}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='.')
    parser.add_argument('--ref', default='upstream/main')
    args = parser.parse_args()
    result = synchronize(args.repo, args.ref)
    print(json.dumps(result, indent=2))
    if output := os.environ.get('GITHUB_OUTPUT'):
        with open(output, 'a') as file:
            for key in ('state', 'upstream', 'branch'):
                file.write(f'{key}={result[key]}\n')


if __name__ == '__main__':
    main()

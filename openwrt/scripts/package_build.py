#!/usr/bin/env python3
"""Plan SDK jobs and refuse incomplete or mixed-source package publications."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ('bjut-autologin', 'luci-app-bjut-autologin')


def package_version(root=ROOT):
    versions = []
    for package in PACKAGES:
        source = (root / 'openwrt' / package / 'Makefile').read_text()
        match = re.search(r'^PKG_VERSION:=(\d+\.\d+\.\d+)$', source, re.MULTILINE)
        if not match:
            raise ValueError(f'Missing explicit package version: {package}')
        versions.append(match[1])
    if len(set(versions)) != 1:
        raise ValueError('Core and LuCI package versions must match')
    return versions[0]


def build_matrix(package_format='all', platform='all'):
    config = json.loads((ROOT / 'openwrt/build-targets.json').read_text())
    if package_format not in ('all', 'ipk', 'apk'):
        raise ValueError('Unknown package format')
    if platform != 'all' and platform not in {p['target'] for p in config['platforms']}:
        raise ValueError('Unknown platform')
    rows = []
    for release in config['releases']:
        if package_format != 'all' and release['format'] != package_format:
            continue
        for target in config['platforms']:
            if platform != 'all' and target['target'] != platform:
                continue
            sdk = target['target'].replace('/', '-') + '-' + release['version']
            rows.append({**release, **target, 'sdk': sdk,
                         'id': 'openwrt-' + sdk + '-' + release['format']})
    if not rows or len({r['id'] for r in rows}) != len(rows):
        raise ValueError('Empty or duplicate build matrix')
    return {'include': rows}


def validate_row(row):
    if row not in build_matrix()['include']:
        raise ValueError('Build metadata does not match a configured SDK')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect_packages(source, output, row, commit):
    validate_row(row)
    version = package_version()
    output.mkdir(parents=True, exist_ok=True)
    selected = {}
    extension = row['format']
    delimiter = '_' if extension == 'ipk' else '-'
    for package in PACKAGES:
        matches = [p for p in source.rglob(f'*.{extension}')
                   if p.name.startswith(package + delimiter + version + '-')
                   or p.name.startswith(package + delimiter + version + '_')]
        if len(matches) != 1 or matches[0].stat().st_size == 0:
            raise ValueError(f'Expected one nonempty {extension} for {package}, got {len(matches)}')
        path = matches[0]
        if extension == 'ipk':
            expected_arch = row['arch'] if package == 'bjut-autologin' else 'all'
            if not path.name.endswith('_' + expected_arch + '.ipk'):
                raise ValueError(f'Unexpected package architecture: {path.name}')
        selected[package] = path
    files = []
    for package, path in selected.items():
        # APK filenames omit the architecture; LuCI IPKs also use 'all'. Prefix
        # assets so different SDK builds cannot overwrite each other on release.
        destination = output / (row['id'] + '__' + path.name)
        shutil.copy2(path, destination)
        files.append({'package': package, 'name': destination.name,
                      'sha256': digest(destination), 'size': destination.stat().st_size})
    metadata = {**row, 'source_commit': commit, 'package_version': version,
                'sdk_container': 'ghcr.io/openwrt/sdk:' + row['sdk'], 'files': files}
    (output / (row['id'] + '.build.json')).write_text(json.dumps(metadata, indent=2) + '\n')
    return metadata


def prepare_release(directory, matrix, commit):
    expected = {row['id']: row for row in matrix['include']}
    manifests = sorted(directory.glob('*.build.json'))
    builds = []
    names = set()
    seen = set()
    for path in manifests:
        data = json.loads(path.read_text())
        row = expected.get(data['id'])
        if row is None or data['id'] in seen or any(data.get(k) != v for k, v in row.items()):
            raise ValueError('Unexpected, duplicate or mismatched SDK build')
        if data['source_commit'] != commit or data['package_version'] != package_version():
            raise ValueError('Mixed source revisions or package versions')
        if {f['package'] for f in data['files']} != set(PACKAGES) or len(data['files']) != len(PACKAGES):
            raise ValueError('Missing core or LuCI package')
        for entry in data['files']:
            name = entry['name']
            if Path(name).name != name or name in names or not name.startswith(row['id'] + '__'):
                raise ValueError('Invalid or colliding release filename')
            package = directory / name
            if package.suffix != '.' + row['format'] or not package.is_file():
                raise ValueError('Missing or incorrect package format')
            if digest(package) != entry['sha256'] or package.stat().st_size != entry['size']:
                raise ValueError('Package checksum mismatch')
            names.add(name)
        seen.add(data['id'])
        builds.append(data)
    if seen != set(expected):
        raise ValueError('Cannot publish an incomplete build matrix')
    actual_packages = {p.name for p in directory.iterdir() if p.suffix in ('.ipk', '.apk')}
    if actual_packages != names:
        raise ValueError('Unexpected packages in release directory')
    (directory / 'builds.json').write_text(json.dumps(builds, indent=2) + '\n')
    checksum_files = [directory / n for n in sorted(names)] + [directory / 'builds.json']
    (directory / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in checksum_files))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    plan = sub.add_parser('plan')
    plan.add_argument('--format', default='all')
    plan.add_argument('--platform', default='all')
    plan.add_argument('--tag', default='')
    collect = sub.add_parser('collect')
    collect.add_argument('--input', type=Path, required=True)
    collect.add_argument('--output', type=Path, required=True)
    collect.add_argument('--row', required=True)
    collect.add_argument('--commit', required=True)
    release = sub.add_parser('release')
    release.add_argument('--directory', type=Path, required=True)
    release.add_argument('--matrix', required=True)
    release.add_argument('--commit', required=True)
    args = parser.parse_args()
    if args.command == 'plan':
        version = package_version()
        if args.tag and args.tag != 'openwrt-v' + version:
            raise ValueError('Release tag must match core and LuCI package versions')
        matrix = build_matrix(args.format, args.platform)
        encoded = json.dumps(matrix, separators=(',', ':'))
        if destination := os.environ.get('GITHUB_OUTPUT'):
            with open(destination, 'a') as output:
                output.write(f'matrix={encoded}\nversion={version}\n')
        print(encoded)
    elif args.command == 'collect':
        data = collect_packages(args.input, args.output, json.loads(args.row), args.commit)
        print(json.dumps(data, indent=2))
        if destination := os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(destination, 'a') as output:
                output.write(f"## {data['target']} · OpenWrt {data['version']} · {data['format']}\n\n")
                for entry in data['files']:
                    output.write(f"- `{entry['name']}`：{entry['size']} 字节\n")
    else:
        prepare_release(args.directory, json.loads(args.matrix), args.commit)


if __name__ == '__main__':
    main()

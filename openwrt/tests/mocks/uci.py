#!/usr/bin/env python3
"""Only a host test fixture. Real packages use OpenWrt's native UCI binary."""
import json
import os
from pathlib import Path
import shlex
import sys

args = sys.argv[1:]
config_dir = Path(os.environ.get('BJUT_CONFIG_DIR', '/nonexistent'))
while args and args[0] in ('-q', '-c'):
    arg = args.pop(0)
    if arg == '-c':
        config_dir = Path(args.pop(0))
command = args.pop(0)
if trace := os.environ.get('MOCK_UCI_TRACE'):
    with open(trace, 'a') as f:
        f.write(' '.join(sys.argv[1:]) + '\n')


def file_for(package):
    return config_dir / package


def load(package):
    path = file_for(package)
    return json.loads(path.read_text()) if path.exists() else {}


def operation(command, arg):
    name, _, value = arg.partition('=')
    parts = name.split('.')
    package = parts.pop(0)
    data = load(package)
    if command == 'get':
        current = data
        for key in parts:
            current = current[key]
        if isinstance(current, dict):
            current = current['.type']
        print(current)
    elif command == 'set':
        section = data.setdefault(parts[0], {})
        if len(parts) == 1:
            section['.type'] = value
        else:
            section[parts[1]] = value
        file_for(package).write_text(json.dumps(data))
    elif command == 'delete':
        data.pop(parts[0], None)
        file_for(package).write_text(json.dumps(data))


try:
    if command == 'batch':
        for line in sys.stdin:
            parts = shlex.split(line)
            if parts and parts[0] == 'set':
                operation('set', parts[1])
    elif command == 'show':
        package=args[0]
        for k,v in load(package).items(): print(package+'.'+k+'='+v.get('.type',''))
    elif command == 'export':
        print(json.dumps(load(args[0])))
    elif command in ('get', 'set', 'delete'):
        operation(command, args[0])
except (KeyError, IndexError, ValueError):
    sys.exit(1)

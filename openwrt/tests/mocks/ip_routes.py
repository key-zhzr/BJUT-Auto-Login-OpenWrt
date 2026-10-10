#!/usr/bin/env python3
"""Simulate only project policy routes; never invoke the host ip utility."""
import fcntl
import json
import os
from pathlib import Path
import sys

trace = Path(os.environ['MOCK_ROUTE_TRACE'])
lock=trace.with_suffix('.lock').open('a')
fcntl.flock(lock,fcntl.LOCK_EX)
with trace.open('a') as f:
    f.write(' '.join(sys.argv[1:]) + '\n')
path = trace.with_suffix('.json')
data = json.loads(path.read_text()) if path.exists() else {'routes': {}, 'rules': []}
args = sys.argv[1:]
family, kind, action = args[:3]
args = args[3:]


def value(option, default=''):
    return args[args.index(option) + 1] if option in args else default


table = value('table', value('lookup'))
key = family + ':' + table
if kind == 'route':
    if action == 'show':
        if table == 'all':
            routes = [r for k, values in data['routes'].items() if k.startswith(family + ':') for r in values.values()]
            routes += [{'text': text} for text in json.loads(os.environ.get('MOCK_CONNECTED_ROUTES', '{}')).get(family, [])]
        else:
            routes = list(data['routes'].get(key, {}).values())
        for route in routes:
            tokens = route['text'].split()
            if 'dev' in args and ('dev' not in tokens or tokens[tokens.index('dev') + 1] != value('dev')):
                continue
            if 'scope' in args and ('scope' not in tokens or tokens[tokens.index('scope') + 1] != value('scope')):
                continue
            print(route['text'])
    elif action == 'get':
        sys.exit(1)
    elif action == 'replace':
        data['routes'].setdefault(key, {})[args[0]] = {'text': ' '.join(args), 'proto': value('proto')}
    elif action == 'flush':
        data['routes'][key] = {k:v for k,v in data['routes'].get(key,{}).items() if v['proto'] != value('proto')}
elif kind == 'rule':
    record = {'family': family, 'source': value('from'), 'oif': value('oif'), 'table': value('lookup'), 'protocol': value('protocol')}
    if action == 'show':
        for rule in data['rules']:
            if rule['family'] == family:
                print('900: from %(source)s oif %(oif)s lookup %(table)s protocol %(protocol)s' % rule)
    elif action == 'add':
        if record not in data['rules']:
            data['rules'].append(record)
    elif action == 'del':
        data['rules'] = [r for r in data['rules'] if r != record]
path.write_text(json.dumps(data))

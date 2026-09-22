#!/usr/bin/env python3
import json
import re
import sys


def parse_args(argv):
    source = None
    expression = None
    index = 0
    while index < len(argv):
        if argv[index] == "-i":
            index += 1
            with open(argv[index], "r", encoding="utf-8") as handle:
                source = handle.read()
        elif argv[index] == "-s":
            index += 1
            source = argv[index]
        elif argv[index] == "-e":
            index += 1
            expression = argv[index]
        index += 1
    if source is None:
        source = sys.stdin.read()
    return source, expression


def lookup(value, expression):
    path = expression.removeprefix("@")
    tokens = []
    while path:
        if path.startswith("."):
            match = re.match(r"\.([A-Za-z0-9_-]+)", path)
            if not match:
                raise KeyError(path)
            tokens.append(match.group(1))
            path = path[match.end():]
        elif path.startswith('["'):
            end = path.index('"]')
            tokens.append(path[2:end])
            path = path[end + 2:]
        elif path.startswith("["):
            end = path.index("]")
            tokens.append(int(path[1:end]))
            path = path[end + 1:]
        else:
            raise KeyError(path)
    for token in tokens:
        value = value[token]
    return value


def main():
    source, expression = parse_args(sys.argv[1:])
    try:
        value = lookup(json.loads(source), expression)
    except (ValueError, KeyError, IndexError, TypeError):
        return 1
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    elif value is not None:
        print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

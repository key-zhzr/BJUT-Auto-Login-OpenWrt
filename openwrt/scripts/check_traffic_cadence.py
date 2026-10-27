#!/usr/bin/env python3
"""Read-only real-router acceptance; never renders history or changes settings."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


TIMESTAMPS = "awk 'FNR==1{print FILENAME,$0}' /var/run/bjut-autologin/traffic/*-at /var/run/bjut-autologin/traffic/*-error 2>/dev/null"


def parse_timestamps(text, expected):
    times, errors = {}, []
    for line in text.splitlines():
        file, separator, value = line.partition(" ")
        key, _, suffix = file.rsplit("/", 1)[-1].rpartition("-")
        if not separator or key not in expected:
            continue
        if suffix == "at" and value.isdigit():
            times[key] = int(value)
        elif suffix == "error" and value.strip():
            errors.append(key)
    return times, sorted(errors)


def summarize(rounds, minimum_rounds=5, maximum_skew=5, tolerance=1):
    spans = [max(row.values()) - min(row.values()) for row in rounds]
    intervals = [current[key] - previous[key]
                 for previous, current in zip(rounds, rounds[1:])
                 for key in current]
    passed = (len(rounds) >= minimum_rounds
              and all(span <= maximum_skew for span in spans)
              and all(60 - tolerance <= value <= 60 + tolerance for value in intervals))
    return {"passed": passed, "roundCount": len(rounds), "spans": spans,
            "minInterval": min(intervals, default=None),
            "maxInterval": max(intervals, default=None),
            "intervals": intervals}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", help="SSH destination, for example root@192.168.1.1")
    parser.add_argument("--ssh-option", action="append", default=[], help="Repeat an ssh -o option; use an existing key/control socket")
    parser.add_argument("--seconds", type=int, default=380)
    parser.add_argument("--poll-seconds", type=float, default=5)
    parser.add_argument("--minimum-rounds", type=int, default=5)
    parser.add_argument("--output", required=True, type=Path, help="New local evidence JSON file (account names are omitted)")
    args = parser.parse_args()
    if args.seconds < 60 or args.poll_seconds < 2 or args.minimum_rounds < 2:
        parser.error("Use at least 60 seconds, two-second polling, and two rounds")
    # Refuse to overwrite an earlier acceptance record.
    output = args.output.open("x", encoding="utf-8")
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
    for option in args.ssh_option:
        ssh += ["-o", option]
    ssh.append(args.host)

    def read(command):
        result = subprocess.run(ssh + [command], capture_output=True, text=True, timeout=15)
        # awk can return nonzero solely because no *-error file exists.
        if result.returncode and (command != TIMESTAMPS or not result.stdout.strip()):
            raise RuntimeError(result.stderr.strip() or "Router read did not complete")
        return result.stdout

    try:
        accounts = json.loads(read("ubus call bjut-autologin accounts '{}'"))["accounts"]
        expected = {hashlib.sha256(row["user"].encode()).hexdigest()
                    for row in accounts if row.get("hasPassword")}
        if not expected:
            raise RuntimeError("No saved accounts with credentials are available")
        started, monotonic_start = int(time.time()), time.monotonic()
        snapshots, rounds = [], []
        previous_signature = None
        read_errors = []
        while time.monotonic() - monotonic_start < args.seconds:
            try:
                times, errors = parse_timestamps(read(TIMESTAMPS), expected)
                signature = (tuple(sorted(times.items())), tuple(errors))
                if signature != previous_signature:
                    snapshots.append({"observedAt": int(time.time()), "times": times, "errors": errors})
                    previous_signature = signature
                if (set(times) == expected and not errors and min(times.values()) >= started
                        and (not rounds or min(times.values()) > max(rounds[-1].values()))):
                    rounds.append(times)
                    progress = summarize(rounds, args.minimum_rounds)
                    print(json.dumps({key: value for key, value in progress.items() if key != "intervals"}), flush=True)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                read_errors.append({"at": int(time.time()), "error": str(error)})
            time.sleep(args.poll_seconds)
        summary = summarize(rounds, args.minimum_rounds)
        summary["passed"] = summary["passed"] and not read_errors
        json.dump({"startedAt": started, "accountCount": len(expected), "summary": summary,
                   "rounds": rounds, "snapshots": snapshots, "readErrors": read_errors}, output, indent=2)
        output.write("\n")
        print(json.dumps(summary), flush=True)
        return 0 if summary["passed"] else 1
    except (RuntimeError, KeyError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        json.dump({"error": str(error)}, output)
        print(str(error), flush=True)
        return 2
    finally:
        output.close()


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Fail if an installed/bundled desktop executable cannot stay running.

This loader/startup check complements the native integration journeys. It does
not claim that network or interactive UI behavior was tested by process liveness.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--seconds', type=float, default=12)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([str(executable)], cwd=executable.parent,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=args.seconds)
            log.seek(0)
            print(log.read().decode('utf-8', errors='replace'))
            print(f'Application exited during startup (status {code}).', file=sys.stderr)
            return 1
        except subprocess.TimeoutExpired:
            print(f'Application remained running for {args.seconds:g} seconds.')
            return 0
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == '__main__':
    sys.exit(main())

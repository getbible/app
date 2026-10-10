#!/usr/bin/env python3
"""Select a real installed simulator by family, record identity and run journeys."""
import json
import os
import re
from pathlib import Path
import subprocess
import sys


def main():
    family = os.environ['SIMULATOR_FAMILY']
    if family not in ('iPhone', 'iPad'):
        raise ValueError('Unsupported simulator family')
    listing = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], text=True))
    available = [(runtime, device) for runtime, devices in listing['devices'].items()
                 for device in devices if '.iOS-' in runtime
                 and device['name'].startswith(family) and device['isAvailable']]
    if not available:
        raise RuntimeError(f'No available {family} simulator installed by this Xcode')
    runtime, device = sorted(available, key=lambda item: (tuple(map(int, re.findall(r'\d+', item[0]))), item[1]['name']))[-1]
    output = Path('build/runtime-evidence')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'device.json').write_text(json.dumps({'runtime': runtime, **device}, indent=2))
    identifier = device['udid']
    if device['state'] != 'Booted':
        subprocess.run(['xcrun', 'simctl', 'boot', identifier], check=True)
    try:
        subprocess.run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], check=True)
        with (output / 'driver.log').open('w') as log:
            process = subprocess.Popen([
                'flutter', 'drive', '--driver=test_driver/platform_acceptance.dart',
                '--target=integration_test/platform_acceptance_test.dart', '-d', identifier,
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in process.stdout:
                print(line, end='', flush=True)
                log.write(line)
            return process.wait()
    finally:
        subprocess.run(['xcrun', 'simctl', 'io', identifier, 'screenshot', str(output / 'simulator.png')], check=False)
        subprocess.run(['xcrun', 'simctl', 'shutdown', identifier], check=False)


if __name__ == '__main__':
    sys.exit(main())

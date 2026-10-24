#!/usr/bin/env python3
"""Exercise the packaged CLI without USB or network device access."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=Path)
parser.add_argument('--original', type=Path)
args = parser.parse_args()
binary = args.binary.resolve()
checks = 0


def invoke(arguments, status=0):
    global checks
    result = subprocess.run([str(binary), '--cli', *arguments], capture_output=True, text=True, timeout=180)
    assert result.returncode == status, (arguments, result.returncode, result.stdout, result.stderr)
    payload = json.loads(result.stdout)
    assert payload['schemaVersion'] == 1
    assert payload['ok'] == (status == 0)
    for line in result.stderr.splitlines():
        event = json.loads(line)
        assert event['schemaVersion'] == 1 and event['type'] == 'progress'
        assert event['command'] == arguments[0]
    checks += 1
    return payload, result.stderr


help_result = subprocess.run([str(binary), '--cli', '--help'], capture_output=True, text=True, check=True)
assert 'confirm-write' in help_result.stdout and 'reboot-verify' in help_result.stdout
with tempfile.TemporaryDirectory(prefix='xiaoai cli tests ') as temporary:
    root = Path(temporary)
    data = root / 'data with spaces'
    payload, _ = invoke(['paths', '--data-dir', str(data)])
    assert payload['data']['dataDirectory'] == str(data) and not data.exists()
    for invalid in [[], ['unknown'], ['detect', '--timeout', 'NaN'],
                    ['flash', '--firmware', '/missing', '--backup', '/missing'],
                    ['restore', '--backup', '/missing'], ['reboot-verify', '--host', '192.168.1.2'],
                    ['verify-ssh', '--host', '1.2.3.4 -oProxyCommand=evil']]:
        payload, _ = invoke(invalid, 64)
        assert payload['error']['code'] == 'invalid_arguments'
    assert not data.exists()
    invoke(['import-original', '--file', str(root / 'missing'), '--data-dir', str(data)], 1)
    assert not data.exists()
    payload, _ = invoke(['ssh-command', '--host', '192.168.1.2', '--data-dir', str(data)])
    assert '192.168.1.2' in payload['data']['sshCommand'] and not data.exists()

    # Synthetic local backup passes the format checks, but cannot be mistaken for stock.
    backup = root / 'backup'
    backup.mkdir()
    image = bytearray(40 * 1024 * 1024)
    image[:4] = b'hsqs'
    struct.pack_into('<I', image, 12, 131072)
    image[20] = 4
    image[28] = 4
    struct.pack_into('<Q', image, 40, 96)
    (backup / 'system0.bin').write_bytes(image)
    manifest = {'format': 1, 'createdAt': '2026-10-24T00:00:00Z',
                'systemHash': hashlib.sha256(image).hexdigest(),
                'logicalHash': hashlib.sha256(image[:96]).hexdigest(),
                'environment': {'bootPart': 'boot1', 'boardID': '1',
                                'text': 'board_id=1\nboot_part=boot1\nprivate=DO_NOT_LOG\n'}}
    (backup / 'backup.json').write_text(json.dumps(manifest))
    payload, _ = invoke(['check-backup', '--backup', str(backup)])
    assert payload['data']['isStock'] is False and payload['data']['sha256'] == manifest['systemHash']
    assert 'bootDelay' not in payload['data'] and 'DO_NOT_LOG' not in json.dumps(payload)
    (backup / 'system0.bin').write_bytes(b'corrupted')
    invoke(['check-backup', '--backup', str(backup)], 1)

    if args.original:
        payload, progress = invoke(['build', '--original', str(args.original.resolve()), '--data-dir', str(data)])
        artifact = payload['data']
        assert progress, 'Build must emit observable progress'
        firmware = Path(artifact['file'])
        assert hashlib.sha256(firmware.read_bytes()).hexdigest() == artifact['sha256']
        assert json.loads(Path(artifact['manifest']).read_text())['hash'] == artifact['sha256']
        assert len(json.loads(Path(artifact['manifest']).read_text())['changedFiles']) == 7
        unpack = binary.parent.parent / 'Resources/Tools/unsquashfs'
        rc = subprocess.check_output([str(unpack), '-cat', str(firmware), 'etc/rc.local'], text=True)
        assert 'rfcomm -r -A -E watch rfcomm0 23' in rc
        subprocess.run(['/bin/sh', '-n'], input=rc, text=True, check=True)
        cached, _ = invoke(['prepare-original', '--data-dir', str(data)])
        assert cached['data']['sha256'] == hashlib.sha256(args.original.read_bytes()).hexdigest()
print(f'PASS: {checks} packaged CLI cases; JSON stdout, JSONL stderr, exit codes, local artifacts; no device access')

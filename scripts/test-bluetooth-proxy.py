#!/usr/bin/env python3
"""Exercise actual proxy code with a delayed RFCOMM peer, without hardware."""
import pathlib, subprocess, tempfile, sys
root = pathlib.Path(__file__).resolve().parents[1]
source = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'Sources/XiaoaiBluetoothProxy/main.m'
with tempfile.TemporaryDirectory(prefix='xiaoai bluetooth ') as temp:
    binary = pathlib.Path(temp) / 'proxy'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    '-I', str(root / 'Tests/BluetoothProxyReadiness'), str(source),
                    str(root / 'Tests/BluetoothProxyReadiness/mock.m'), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), 'EC:41:18:6E:AF:06'], input=b'client-handshake',
                            capture_output=True, timeout=5)
    assert result.returncode == 0, (result.returncode, result.stderr)
    assert result.stdout == b'SSH-2.0-fixture\r\nclient-handshake', result.stdout
    print('PASS: delayed peer readiness and exact client bytes across 4-byte MTU chunks')

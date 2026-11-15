#!/usr/bin/env python3
"""Create a tiny developer-signed CRX3 using OpenSSL, with no publisher proof."""
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile


def varint(value):
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    return bytes(out) + bytes([value])


def field(number, value):
    return varint(number << 3 | 2) + varint(len(value)) + value


def make(destination):
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        key, public, message, signature = [root / name for name in ['key.pem', 'key.der', 'message', 'signature']]
        subprocess.run(['openssl', 'genrsa', '-out', str(key), '2048'], check=True, capture_output=True)
        subprocess.run(['openssl', 'rsa', '-in', str(key), '-pubout', '-outform', 'DER', '-out', str(public)], check=True, capture_output=True)
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
            for name, data in {
                'manifest.json': json.dumps({'manifest_version': 3, 'name': 'Local CRX fixture', 'version': '1.0',
                                             'permissions': ['storage'], 'action': {'default_popup': 'popup.html'}}),
                'popup.html': '<!doctype html><title>Local CRX</title>Local package works',
            }.items():
                package.writestr(zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0)), data)
        identity = hashlib.sha256(public.read_bytes()).digest()[:16]
        signed = field(1, identity)
        message.write_bytes(b'CRX3 SignedData\0' + struct.pack('<I', len(signed)) + signed + archive.getvalue())
        subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key), '-out', str(signature), str(message)], check=True)
        header = field(2, field(1, public.read_bytes()) + field(2, signature.read_bytes())) + field(10000, signed)
        destination.write_bytes(b'Cr24' + struct.pack('<II', 3, len(header)) + header + archive.getvalue())
        print(''.join(chr(97 + int(n, 16)) for n in identity.hex()))


if __name__ == '__main__':
    make(Path(__file__).with_name('local.crx'))

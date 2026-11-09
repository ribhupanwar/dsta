#!/usr/bin/env python3
"""Read-only IPA identity/Mach-O inventory. Never executes code or extracts app assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile
import plistlib

MAX_EXECUTABLE = 512 * 1024 * 1024


def macho_inventory(binary):
    if len(binary) < 32 or binary[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin little-endian 64-bit Mach-O executable')
    count, size = struct.unpack_from('<II', binary, 16)
    if size > len(binary) - 32 or count > size // 8:
        raise ValueError('Invalid Mach-O command table')
    offset = 32
    encryption = []
    symbols = 0
    for _ in range(count):
        command, length = struct.unpack_from('<II', binary, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError('Invalid Mach-O load command size')
        if command in (0x21, 0x2c):
            if length < 20:
                raise ValueError('Truncated encryption command')
            cryptoff, cryptsize, cryptid = struct.unpack_from('<III', binary, offset + 8)
            encryption.append(dict(cryptoff=cryptoff, cryptsize=cryptsize, cryptid=cryptid))
        if command == 2:
            if length < 24:
                raise ValueError('Truncated symbol-table command')
            symbols = struct.unpack_from('<I', binary, offset + 12)[0]
        offset += length
    terms = ('healthspan', 'vo2max', 'repcount', 'strengthtrainer', 'autodetect')
    counts = dict.fromkeys(terms, 0)
    for match in re.finditer(rb'[ -~]{8,}', binary):
        text = match.group().lower()
        for word in terms:
            if word.encode() in text:
                counts[word] += 1
    hosts = {}
    for match in re.finditer(rb'https?://([A-Za-z0-9][A-Za-z0-9.-]+)', binary):
        host = match.group(1).decode().lower().rstrip('.')
        if host == 'whoop.com' or host.endswith('.whoop.com'):
            hosts[host] = hosts.get(host, 0) + 1
    return dict(encryption_commands=encryption, symbol_count=symbols,
                feature_string_counts=counts, whoop_url_host_literals=dict(sorted(hosts.items())))


def inspect(path, expected_sha256=None):
    path = Path(path)
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    sha = digest.hexdigest()
    if expected_sha256 and sha != expected_sha256.lower():
        raise ValueError('Archive SHA-256 does not match expected asset')
    result = dict(file=path.name, bytes=path.stat().st_size, sha256=sha, apps=[])
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        for name in names:
            if not re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name):
                continue
            if archive.getinfo(name).file_size > 2 * 1024 * 1024:
                raise ValueError('Oversized app plist')
            info = plistlib.loads(archive.read(name))
            executable = info.get('CFBundleExecutable', '')
            if not executable or '/' in executable or executable in ('.', '..'):
                raise ValueError('Invalid executable name')
            member = name[:-len('Info.plist')] + executable
            if archive.getinfo(member).file_size > MAX_EXECUTABLE:
                raise ValueError('Executable exceeds audit size limit')
            binary = archive.read(member)
            keys = ('CFBundleIdentifier', 'CFBundleDisplayName', 'CFBundleName',
                    'CFBundleShortVersionString', 'CFBundleVersion', 'MinimumOSVersion')
            app = {key: info.get(key) for key in keys}
            app.update(macho_inventory(binary))
            result['apps'].append(app)
    if not result['apps']:
        raise ValueError('No top-level IPA application found')
    result['limits'] = ('Metadata is not authenticity verification. String/symbol presence does not prove '
                        'an algorithm, device protocol mapping or feature works. No assets or code executed.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa')
    parser.add_argument('--expected-sha256')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = json.dumps(inspect(args.ipa, args.expected_sha256), indent=2)
    if args.output:
        args.output.write_text(report + '\n')
    else:
        print(report)


if __name__ == '__main__':
    main()

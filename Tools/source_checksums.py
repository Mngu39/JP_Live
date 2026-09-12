"""Generate exact-byte SHA-256 manifests, or normalize manifest record endings.

No source file is rewritten. normalize() changes CRLF record delimiters only;
shasum still verifies the original digest against the actual source bytes.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import re

IGNORED_DIRECTORIES = {'.git', '.build', 'BuildOutputs', 'work', '__pycache__', 'xcuserdata'}
IGNORED_FILES = {'SHA256SUMS.txt', '.DS_Store'}


def normalize(data):
    normalized = data.replace(b'\r\n', b'\n')
    text = normalized.decode('utf-8')
    lines = text.split('\n')
    seen = set()
    for number, line in enumerate(lines, 1):
        if not line and number == len(lines):
            continue
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        if not match:
            raise ValueError(f'Invalid checksum record on line {number}')
        name = match.group(2)
        path = PurePosixPath(name)
        if (any(c in name for c in '\r\x00\\') or path.is_absolute()
                or '..' in path.parts or name != path.as_posix() or name in seen):
            raise ValueError(f'Invalid or duplicate checksum path on line {number}')
        seen.add(name)
    if not seen:
        raise ValueError('Empty checksum manifest')
    return normalized


def generate(root):
    root = Path(root)
    paths = sorted(p for p in root.rglob('*') if p.is_file()
                   and not any(part in IGNORED_DIRECTORIES for part in p.relative_to(root).parts)
                   and p.name not in IGNORED_FILES)
    records = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root).as_posix()}\n'
                      for p in paths).encode('utf-8')
    # Binary write deliberately bypasses Windows newline translation.
    (root / 'SHA256SUMS.txt').write_bytes(normalize(records))
    return len(paths)


def verify(root, data):
    root = Path(root)
    lines = normalize(data).decode('utf-8').splitlines()
    for line in lines:
        expected, name = line.split('  ', 1)
        actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f'SHA-256 mismatch: {name}')
    return len(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    write = sub.add_parser('generate')
    write.add_argument('root', type=Path)
    check = sub.add_parser('verify')
    check.add_argument('root', type=Path)
    check.add_argument('manifest', type=Path)
    norm = sub.add_parser('normalize')
    norm.add_argument('source', type=Path)
    norm.add_argument('destination', type=Path)
    args = parser.parse_args()
    if args.command == 'generate':
        print(f'Generated LF manifest: {generate(args.root)} files')
    elif args.command == 'verify':
        print(f'Exact source checksums passed: {verify(args.root, args.manifest.read_bytes())} files')
    else:
        if args.source.resolve() == args.destination.resolve():
            raise ValueError('Normalization must write a separate manifest copy')
        args.destination.write_bytes(normalize(args.source.read_bytes()))


if __name__ == '__main__':
    main()

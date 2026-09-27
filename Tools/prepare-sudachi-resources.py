"""Stage pinned installed Sudachi resources plus package license evidence; no network calls or production writes."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil

VERSIONS = {'SudachiPy': '0.6.11', 'SudachiDict-full': '20260723'}
EXPECTED_LICENSES = {'SudachiPy': 'Apache-2.0', 'SudachiDict-full': 'Apache-2.0'}
LICENSE_NAME_MARKERS = ('LICENSE', 'COPYING', 'NOTICE', 'LEGAL')

def _declared_license(dist):
    metadata = getattr(dist, 'metadata', None)
    if metadata is None or not hasattr(metadata, 'get'):
        return None
    for key in ('License-Expression', 'License'):
        value = metadata.get(key)
        if value and value.strip():
            return value.strip()
    return None

def _copy_license_evidence(name, dist, destination):
    target_root = destination/'licenses'/name
    copied = 0
    for entry in dist.files or []:
        if not any(word in entry.name.upper() for word in LICENSE_NAME_MARKERS):
            continue
        original = Path(dist.locate_file(entry))
        if original.is_file():
            target = target_root/Path(str(entry))
            base = target_root.resolve()
            if not target.resolve().is_relative_to(base):
                raise ValueError(f'Unsafe license path: {entry}')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
            copied += 1
    if copied:
        return copied

    expected = EXPECTED_LICENSES[name]
    declared = _declared_license(dist)
    if declared != expected:
        raise ValueError(
            f'{name} has no packaged license file and declares {declared!r}; expected {expected!r}'
        )
    target_root.mkdir(parents=True, exist_ok=True)
    (target_root/'PACKAGE-LICENSE-METADATA.txt').write_text(
        f'Package: {name}\n'
        f'Version: {dist.version}\n'
        f'Declared-License: {declared}\n'
        'Packaged-License-File: absent\n'
        'Status: build-time license evidence only; review the upstream license before redistribution.\n',
        encoding='utf-8', newline='\n')
    return 1

def prepare(destination):
    destination = Path(destination)
    if destination.exists():
        raise ValueError('Use a fresh staging directory; existing assets are never overwritten')
    packages = {}
    for name, version in VERSIONS.items():
        dist = importlib.metadata.distribution(name)
        if dist.version != version:
            raise ValueError(f'{name}: expected {version}, installed {dist.version}')
        packages[name] = dist
    source = Path(packages['SudachiPy'].locate_file('sudachipy/resources'))
    dictionary = Path(packages['SudachiDict-full'].locate_file('sudachidict_full/resources/system.dic'))
    if not (source/'sudachi.json').is_file() or not dictionary.is_file():
        raise ValueError('Installed packages do not contain the expected resources/dictionary')
    shutil.copytree(source, destination)
    shutil.copy2(dictionary, destination/'system.dic')
    config = json.loads((destination/'sudachi.json').read_text(encoding='utf-8'))
    config['systemDict'] = 'system.dic'
    config['userDict'] = []
    (destination/'sudachi.json').write_text(json.dumps(config, ensure_ascii=False, indent=2)+'\n', encoding='utf-8', newline='\n')
    for name, dist in packages.items():
        _copy_license_evidence(name, dist, destination)
    hashes = {p.relative_to(destination).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(destination.rglob('*')) if p.is_file()}
    (destination/'asset-manifest.json').write_text(
        json.dumps({'packages': VERSIONS, 'sha256': hashes}, ensure_ascii=False, indent=2)+'\n', encoding='utf-8', newline='\n')
    return len(hashes)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(f'Staged {prepare(args.destination)} resource/license-evidence files')

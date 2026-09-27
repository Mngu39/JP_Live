"""Stage pinned installed Sudachi resources; no network calls or production writes."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil

VERSIONS = {'SudachiPy': '0.7.0', 'SudachiDict-full': '20260723.1'}

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
        copied = 0
        for entry in dist.files or []:
            if not any(word in entry.name.upper() for word in ('LICENSE', 'COPYING', 'NOTICE')):
                continue
            original = Path(dist.locate_file(entry))
            if original.is_file():
                target = destination/'licenses'/name/Path(str(entry))
                base = (destination/'licenses'/name).resolve()
                if not target.resolve().is_relative_to(base):
                    raise ValueError(f'Unsafe license path: {entry}')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, target)
                copied += 1
        if not copied:
            raise ValueError(f'{name} has no packaged license file; inspect before redistribution')
    hashes = {p.relative_to(destination).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(destination.rglob('*')) if p.is_file()}
    (destination/'asset-manifest.json').write_text(
        json.dumps({'packages': VERSIONS, 'sha256': hashes}, ensure_ascii=False, indent=2)+'\n', encoding='utf-8', newline='\n')
    return len(hashes)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(f'Staged {prepare(args.destination)} resource/license files')

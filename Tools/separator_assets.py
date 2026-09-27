"""Dependency-free separator provenance and exact generated-asset verification."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import math
import re

MODEL = 'speechbrain/sepformer-whamr16k'
REVISION = '21a5b500c6f52fddc387c5d9e5fb13ffd6f039c5'
SOURCE_FILES = ('hyperparams.yaml', 'encoder.ckpt', 'decoder.ckpt', 'masknet.ckpt',
                'README.md', 'test_mixture16k.wav')
PARITY_CASES = {'noise', 'silence', 'impulse', 'upstream-English-mixture'}


def verify_report(report):
    if (not isinstance(report, dict) or report.get('source') != MODEL
            or report.get('revision') != REVISION or report.get('license') != 'Apache-2.0'
            or report.get('shape') != [1, 64000, 2] or report.get('parityPassed') is not True):
        raise ValueError('Conversion report provenance or parity result mismatch')
    sources = report.get('sourceSHA256')
    if (not isinstance(sources, dict) or set(sources) != set(SOURCE_FILES)
            or any(not isinstance(v, str) or re.fullmatch('[0-9a-f]{64}', v) is None for v in sources.values())):
        raise ValueError('Conversion report lacks pinned source hashes')
    checks = report.get('checks')
    if (not isinstance(checks, list) or len(checks) != len(PARITY_CASES)
            or any(not isinstance(c, dict) or not isinstance(c.get('case'), str) for c in checks)
            or {c['case'] for c in checks} != PARITY_CASES):
        raise ValueError('Conversion report lacks the required parity cases')
    for check in checks:
        if check.get('passed') is not True:
            raise ValueError('Conversion parity case did not pass')
        for field in ('maxAbsoluteError', 'hostSeconds'):
            value = check.get(field)
            if type(value) not in (float, int) or not math.isfinite(value) or value < 0:
                raise ValueError('Invalid conversion parity measurement')


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def asset_hashes(directory):
    directory = Path(directory)
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise ValueError('Generated assets must not contain symbolic links')
        if path.is_file() and path != directory/'asset-manifest.json':
            result[path.relative_to(directory).as_posix()] = file_hash(path)
    return result


def verify(directory):
    directory = Path(directory)
    if not directory.exists() or (directory.is_dir() and not any(directory.iterdir())):
        return {'status': 'MODEL_NOT_PREPARED', 'liveSeparation': False}
    manifest = json.loads((directory/'asset-manifest.json').read_text(encoding='utf-8'))
    if (manifest.get('schemaVersion') != 1 or manifest.get('source') != MODEL
            or manifest.get('revision') != REVISION or manifest.get('license') != 'Apache-2.0'
            or manifest.get('sampleRate') != 16000 or manifest.get('input') != [1, 64000]
            or manifest.get('output') != [1, 64000, 2]
            or manifest.get('validation') != 'conversion-parity-passed; Japanese/device NOT VERIFIED'):
        raise ValueError('Separator provenance/shape/validation contract mismatch')
    records = manifest.get('sha256')
    if not isinstance(records, dict) or not records:
        raise ValueError('Missing separator asset hashes')
    for name, digest in records.items():
        path = PurePosixPath(name)
        if (path.is_absolute() or '..' in path.parts or name != path.as_posix()
                or any(c in name for c in '\\\r\n\x00:') or re.search(r'#U[0-9a-fA-F]+', name)
                or not isinstance(digest, str) or re.fullmatch('[0-9a-f]{64}', digest) is None):
            raise ValueError('Invalid separator manifest entry')
    if not any(name.startswith('Separator.mlmodelc/') for name in records):
        raise ValueError('Compiled separator missing')
    for required in ('licenses/Apache-2.0.txt', 'licenses/model-card.md', 'conversion-report.json'):
        if required not in records:
            raise ValueError('Separator license/provenance evidence missing: ' + required)
    if asset_hashes(directory) != records:
        raise ValueError('Separator file contents/list differ from the export manifest')
    verify_report(json.loads((directory/'conversion-report.json').read_text(encoding='utf-8')))
    return {'status': 'CONVERSION_ASSETS_VERIFIED', 'files': len(records),
            'revision': REVISION, 'JapaneseQuality': 'NOT VERIFIED', 'iPadPerformance': 'NOT VERIFIED'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.directory), indent=2))

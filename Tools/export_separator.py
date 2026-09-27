"""Explicit macOS model preparation. Does not run as part of normal app CI."""
from pathlib import Path
import argparse
import importlib.metadata
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from separator_assets import MODEL, REVISION, SOURCE_FILES, asset_hashes, file_hash, verify


def preflight(output, app_resources):
    if platform.system() != 'Darwin':
        raise ValueError('Model prediction/parity and Core ML compilation require macOS; use --help elsewhere')
    if sys.version_info[:2] != (3, 11):
        raise ValueError('Use the specified Python 3.11 export environment')
    if not shutil.which('xcrun'):
        raise ValueError('Xcode command-line tools (xcrun) are required')
    if output.suffix != '.mlpackage' or output.exists() or output.with_suffix('.validation.json').exists():
        raise ValueError('Choose a fresh .mlpackage output; existing artifacts are not overwritten')
    if app_resources and app_resources.exists() and (not app_resources.is_dir() or any(app_resources.iterdir())):
        raise ValueError('App resource destination must be absent or empty; existing models are not overwritten')
    requirements = Path(__file__).with_name('separator-requirements.txt').read_text().splitlines()
    versions = {}
    for line in requirements:
        if not line or line.startswith('#'):
            continue
        name, expected = line.split('==')
        actual = importlib.metadata.version(name)
        if actual != expected:
            raise ValueError(f'{name}: expected {expected}, installed {actual}')
        versions[name] = actual
    return versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path, default=Path('BuildOutputs/separator-source'))
    parser.add_argument('--app-resources', type=Path,
                        help='Absent or empty BuildOutputs/Separation folder; populated only after all checks pass')
    args = parser.parse_args()
    try:
        versions = preflight(args.output, args.app_resources)
    except (ValueError, importlib.metadata.PackageNotFoundError) as error:
        parser.error(str(error))
    # Lazy imports keep --help and dependency-free preflight tests usable here.
    import numpy as np
    import torch
    import soundfile as sf
    import coremltools as ct
    from huggingface_hub import snapshot_download
    from speechbrain.inference.separation import SepformerSeparation

    # Pin the WHOLE snapshot before loading locally. Passing revision only to
    # older SpeechBrain.from_hparams does not pin every pretrainer weight fetch.
    snapshot = Path(snapshot_download(repo_id=MODEL, revision=REVISION,
                    allow_patterns=list(SOURCE_FILES), cache_dir=str(args.cache.resolve())))
    source_hashes = {name: file_hash(snapshot/name) for name in SOURCE_FILES}
    card = (snapshot/'README.md').read_text(encoding='utf-8')
    if 'license: apache-2.0' not in card.lower():
        raise ValueError('Pinned model card no longer declares the reviewed Apache-2.0 license')
    with urllib.request.urlopen('https://www.apache.org/licenses/LICENSE-2.0.txt', timeout=30) as response:
        license_text = response.read().decode('utf-8')
    if 'Apache License' not in license_text or 'Version 2.0' not in license_text:
        raise ValueError('Could not retrieve the Apache-2.0 license text')
    torch.manual_seed(7)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='separator-export-', dir=args.output.parent) as temporary:
        temporary = Path(temporary)
        separator = SepformerSeparation.from_hparams(source=str(snapshot),
            savedir=str(temporary/'weights'), run_opts={'device': 'cpu'})
        if int(separator.hparams.sample_rate) != 16000 or int(separator.hparams.num_spks) != 2:
            raise ValueError('Pinned model does not match the 16 kHz/two-stem contract')

        class FixedSeparator(torch.nn.Module):
            def __init__(self, wrapped):
                super().__init__()
                self.encoder = wrapped.mods.encoder
                self.masknet = wrapped.mods.masknet
                self.decoder = wrapped.mods.decoder
            def forward(self, mixture):
                encoded = self.encoder(mixture)
                stems = encoded.unsqueeze(0).repeat(2, 1, 1, 1) * self.masknet(encoded)
                return torch.stack([self.decoder(stems[0]), self.decoder(stems[1])], dim=-1)

        wrapper = FixedSeparator(separator).eval()
        speech, rate = sf.read(snapshot/'test_mixture16k.wav', dtype='float32')
        if rate != 16000 or speech.ndim != 1 or speech.size < 64000 or not np.isfinite(speech).all():
            raise ValueError('Upstream real-audio parity fixture is not valid 16 kHz mono')
        impulse = torch.zeros(1, 64000); impulse[0, 16000] = 0.25
        cases = [('noise', torch.randn(1, 64000)*0.03), ('silence', torch.zeros(1, 64000)),
                 ('impulse', impulse), ('upstream-English-mixture', torch.from_numpy(speech[:64000].copy()).unsqueeze(0))]
        with torch.no_grad():
            traced = torch.jit.trace(wrapper, cases[0][1], check_trace=True)
        model = ct.convert(traced,
            inputs=[ct.TensorType(name='mixture', shape=(1, 64000), dtype=np.float32)],
            outputs=[ct.TensorType(name='stems', dtype=np.float32)], convert_to='mlprogram',
            minimum_deployment_target=ct.target.iOS18, compute_precision=ct.precision.FLOAT32,
            compute_units=ct.ComputeUnit.CPU_ONLY)
        checks = []
        for label, example in cases:
            started = time.perf_counter()
            with torch.no_grad():
                reference = separator.separate_batch(example).cpu().numpy()
                wrapped = wrapper(example).cpu().numpy()
                traced_result = traced(example).cpu().numpy()
            actual = model.predict({'mixture': example.numpy()})['stems']
            for stage, value in [('wrapper', wrapped), ('trace', traced_result), ('coreml', actual)]:
                if (value.shape != (1, 64000, 2) or not np.isfinite(value).all()
                        or not np.isfinite(reference).all()
                        or not np.allclose(reference, value, rtol=1e-3, atol=1e-3)):
                    raise ValueError(f'{label}: {stage} disagrees with official separate_batch')
            checks.append({'case': label, 'passed': True, 'maxAbsoluteError': float(np.max(np.abs(reference-actual))),
                           'hostSeconds': time.perf_counter()-started})
        report = {'source': MODEL, 'revision': REVISION, 'sourceSHA256': source_hashes, 'parityPassed': True,
                  'license': 'Apache-2.0', 'shape': [1, 64000, 2], 'checks': checks,
                  'python': platform.python_version(), 'platform': platform.platform(),
                  'versions': versions,
                  'installedPackages': sorted(f'{d.metadata["Name"]}=={d.version}' for d in importlib.metadata.distributions()),
                  'scope': 'Conversion parity including upstream English speech; NOT Japanese quality or iPad latency'}
        package = temporary/args.output.name
        model.save(str(package))
        ready = None
        if args.app_resources:
            (temporary/'compiled').mkdir()
            subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), str(temporary/'compiled')], check=True)
            compiled = temporary/'compiled'/(args.output.stem+'.mlmodelc')
            if not compiled.is_dir():
                raise RuntimeError('Core ML compilation did not produce the expected directory')
            # Stage on the destination filesystem so the final rename is atomic.
            args.app_resources.parent.mkdir(parents=True, exist_ok=True)
            ready = Path(tempfile.mkdtemp(prefix='separator-ready-', dir=args.app_resources.parent))
            shutil.copytree(compiled, ready/'Separator.mlmodelc')
            (ready/'licenses').mkdir()
            (ready/'licenses/Apache-2.0.txt').write_text(license_text, encoding='utf-8', newline='\n')
            (ready/'licenses/model-card.md').write_text(card, encoding='utf-8', newline='\n')
            (ready/'conversion-report.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8', newline='\n')
            manifest = {'schemaVersion': 1, 'source': MODEL, 'revision': REVISION, 'license': 'Apache-2.0',
                        'sampleRate': 16000, 'input': [1, 64000], 'output': [1, 64000, 2],
                        'sha256': asset_hashes(ready),
                        'validation': 'conversion-parity-passed; Japanese/device NOT VERIFIED'}
            (ready/'asset-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8', newline='\n')
            verify(ready)
        # No app-visible compiled model is published on a failed parity/compile.
        if args.output.exists():
            raise ValueError('Output appeared during conversion; refusing to overwrite it')
        package.rename(args.output)
        args.output.with_suffix('.validation.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8', newline='\n')
        if ready:
            if args.app_resources.exists():
                args.app_resources.rmdir()  # only an empty directory; never recursive
            ready.rename(args.app_resources)
    print('Conversion artifacts prepared; Japanese overlap quality and iPad performance remain unverified.')


if __name__ == '__main__':
    main()

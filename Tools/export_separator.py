"""Pinned macOS separator preparation used by the required Phase 2 CI gate and local builds."""
from pathlib import Path
import argparse
import importlib.metadata
import json
import platform
import re
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



def assert_pinned_apache_license(card):
    """Check the license field in pinned Hugging Face YAML front matter.

    HF model cards can use either `license: apache-2.0` or
    `license: "apache-2.0"`.  Keep this strict: a free-text mention of the
    license outside front matter must not authorize model redistribution.
    """
    lines = card.splitlines()
    if not lines or lines[0].strip() != '---':
        raise ValueError('Pinned model card lacks YAML front matter')
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == '---')
    except StopIteration as error:
        raise ValueError('Pinned model card has unterminated YAML front matter') from error
    declarations = []
    for line in lines[1:end]:
        match = re.fullmatch(r'license:[ \t]*(.*?)[ \t]*', line)
        if match is not None:
            declarations.append(match.group(1).strip())
    if len(declarations) != 1:
        raise ValueError('Pinned model card must have exactly one top-level license declaration')
    raw = declarations[0]
    if len(raw) >= 2 and raw[0] in ('"', "'") and raw[-1] == raw[0]:
        raw = raw[1:-1]
    if raw.lower() != 'apache-2.0':
        raise ValueError('Pinned model card does not declare Apache-2.0')


def prepare_upstream_parity_audio(samples, sample_rate, size=64000):
    """Make a fixed 16kHz mono input for numerical parity, not a quality score.

    The pinned upstream WAV is an external sample, not a promise that it lasts
    four seconds. It can be safely padded for a 4s fixed-shape conversion test.
    Preserve the original metadata so normalization cannot masquerade as a
    native 4s source recording.
    """
    import math
    import numpy as np
    from scipy.signal import resample_poly

    samples = np.asarray(samples)
    original_shape = list(samples.shape)
    if (samples.ndim not in (1, 2) or samples.size == 0 or
            (samples.ndim == 2 and (samples.shape[1] < 1 or samples.shape[1] > 8)) or
            not isinstance(sample_rate, (int, np.integer)) or sample_rate <= 0 or
            not np.issubdtype(samples.dtype, np.number) or
            not np.isfinite(samples).all()):
        raise ValueError(f'Invalid upstream parity WAV: rate={sample_rate}, shape={original_shape}')
    original_rate = int(sample_rate)
    channels = samples.shape[1] if samples.ndim == 2 else 1
    samples = samples.astype(np.float32)
    if samples.ndim == 2:
        samples = samples.mean(axis=1, dtype=np.float32)
    if sample_rate != 16000:
        divisor = math.gcd(original_rate, 16000)
        samples = resample_poly(samples, 16000//divisor, original_rate//divisor).astype(np.float32)
    if samples.size == 0 or not np.isfinite(samples).all() or np.max(np.abs(samples)) == 0:
        raise ValueError('Upstream parity WAV has no usable audio after conversion')
    normalized_count = int(samples.size)
    if normalized_count < size:
        samples = np.pad(samples, (0, size-normalized_count))
    else:
        samples = samples[:size]
    return samples.astype(np.float32), {
        'originalRate': original_rate, 'originalShape': original_shape,
        'originalChannels': int(channels), 'resampledTo': 16000,
        'availableSamplesAt16k': normalized_count, 'testInputSamples': size,
        'adaptation': ('zero-padded' if normalized_count < size else
                       'truncated' if normalized_count > size else 'unaltered'),
    }


def register_coreml_alias_converter(registrar, get_inputs, builder):
    """Lower TorchScript aten::alias as a value-preserving MIL identity.

    coremltools 8.3 does not register this operator. aten::alias creates an
    alias/view of its input; in this evaluation-only separator the converted
    graph does not need a separate mutable storage alias. All numerical
    predictions are still checked against the upstream SpeechBrain model
    before a .mlpackage can be published.
    """
    @registrar
    def alias(context, node):
        value = get_inputs(context, node, expected=1)[0]
        context.add(builder.identity(x=value, name=node.name))

    return alias



def compare_coreml_audio(reference, actual):
    """Check a separated waveform using signal-relative error, without ignoring artifacts.

    Pointwise np.allclose with fixed 1e-3 absolute error can reject a long
    speech waveform due to a handful of harmless numerical outliers. Require
    each speaker channel to have >= 45 dB signal-to-error ratio (or a strict
    absolute noise floor for near-silent stems), and cap the largest sample
    difference to 2% of the reference peak plus a 0.001 numeric floor.
    This is conversion fidelity only, never a speech-quality evaluation.
    """
    import numpy as np
    if (reference.shape != (1, 64000, 2) or actual.shape != reference.shape or
            not np.isfinite(reference).all() or not np.isfinite(actual).all()):
        return False, {'error': 'shape or nonfinite values',
                       'referenceShape': list(reference.shape), 'actualShape': list(actual.shape)}
    details = []
    valid = True
    for channel in range(2):
        ref = reference[0, :, channel].astype(np.float64)
        converted = actual[0, :, channel].astype(np.float64)
        difference = converted - ref
        ref_rms = float(np.sqrt(np.mean(ref * ref)))
        err_rms = float(np.sqrt(np.mean(difference * difference)))
        ref_peak = float(np.max(np.abs(ref)))
        err_peak = float(np.max(np.abs(difference)))
        near_silent = ref_rms < 1e-4
        # Quiet channels still must stay quiet, not merely match a loud partner.
        if near_silent:
            rms_limit = 1e-4
            peak_limit = 1e-3
        else:
            rms_limit = ref_rms * (10 ** (-45 / 20))
            peak_limit = max(1e-3, ref_peak * 0.02)
        passed = err_rms <= rms_limit and err_peak <= peak_limit
        valid = valid and passed
        details.append({
            'channel': channel, 'passed': bool(passed),
            'referenceRMS': ref_rms, 'errorRMS': err_rms,
            'rmsLimit': rms_limit, 'referencePeak': ref_peak,
            'maxAbsoluteError': err_peak, 'peakLimit': peak_limit,
            'signalToErrorDb': (None if err_rms == 0 or ref_rms == 0 else
                                20 * float(np.log10(ref_rms / err_rms))),
        })
    return bool(valid), {'channels': details, 'criterion': 'per-stem >=45dB SER and peak <=2% +1e-3; near-silence absolute bound'}


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
    assert_pinned_apache_license(card)
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
                decoded = torch.stack([self.decoder(stems[0]), self.decoder(stems[1])], dim=-1)
                # Match SpeechBrain SepformerSeparation.separate_batch: Conv1d
                # may change T, so restore the requested input time dimension.
                requested = mixture.size(1)
                actual = decoded.size(1)
                if requested > actual:
                    return torch.nn.functional.pad(decoded, (0, 0, 0, requested-actual))
                return decoded[:, :requested, :]

        wrapper = FixedSeparator(separator).eval()
        speech, rate = sf.read(snapshot/'test_mixture16k.wav', dtype='float32')
        speech, fixture_info = prepare_upstream_parity_audio(speech, rate)
        impulse = torch.zeros(1, 64000); impulse[0, 16000] = 0.25
        cases = [('noise', torch.randn(1, 64000)*0.03), ('silence', torch.zeros(1, 64000)),
                 ('impulse', impulse), ('upstream-English-mixture', torch.from_numpy(speech[:64000].copy()).unsqueeze(0))]
        with torch.no_grad():
            traced = torch.jit.trace(wrapper, cases[0][1], check_trace=True)
        # Do every PyTorch forward pass BEFORE entering coremltools conversion.
        # On the xcode-27 runner, calling SpeechBrain separate_batch() after
        # ct.convert() crashed CPython 3.11 in native code (PyEval_SaveThread).
        # Retain independent numerical comparisons against the real upstream
        # separator, but never invoke the Torch module again after ct.convert().
        baselines = []
        for label, example in cases:
            print(f'PyTorch upstream/wrapper/trace parity: {label}', flush=True)
            started = time.perf_counter()
            with torch.no_grad():
                reference = separator.separate_batch(example).cpu().numpy().copy()
                wrapped = wrapper(example).cpu().numpy().copy()
                traced_result = traced(example).cpu().numpy().copy()
            for stage, value in [('wrapper', wrapped), ('trace', traced_result)]:
                if (value.shape != (1, 64000, 2) or not np.isfinite(value).all()
                        or not np.isfinite(reference).all()
                        or not np.allclose(reference, value, rtol=1e-3, atol=1e-3)):
                    raise ValueError(f'{label}: {stage} disagrees with official separate_batch')
            # A NumPy copy avoids touching PyTorch Tensor objects after conversion.
            baselines.append((label, example.numpy().copy(), reference,
                              time.perf_counter() - started))
        print('PyTorch parity passed; beginning Core ML conversion', flush=True)
        # coremltools 8.3's TorchScript frontend lacks aten::alias support.
        # Register exactly that value-preserving operator, not a generic
        # unsupported-op bypass. Keep full upstream-vs-CoreML parity checks.
        from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
        from coremltools.converters.mil.frontend.torch.ops import _get_inputs
        from coremltools.converters.mil import Builder as mb
        register_coreml_alias_converter(register_torch_op, _get_inputs, mb)
        model = ct.convert(traced,
            inputs=[ct.TensorType(name='mixture', shape=(1, 64000), dtype=np.float32)],
            outputs=[ct.TensorType(name='stems', dtype=np.float32)], convert_to='mlprogram',
            minimum_deployment_target=ct.target.iOS18, compute_precision=ct.precision.FLOAT32,
            compute_units=ct.ComputeUnit.CPU_ONLY, debug=True)
        print('Core ML conversion returned; checking converted-model parity', flush=True)
        checks = []
        for label, mixture_numpy, reference, preconversion_seconds in baselines:
            started = time.perf_counter()
            actual = model.predict({'mixture': mixture_numpy})['stems']
            passed, metrics = compare_coreml_audio(reference, actual)
            print(f'Core ML waveform metrics {label}: {json.dumps(metrics, sort_keys=True)}', flush=True)
            if not passed:
                raise ValueError(f'{label}: Core ML output fails per-channel waveform fidelity; metrics above')
            checks.append({'case': label, 'passed': True,
                           'maxAbsoluteError': float(np.max(np.abs(reference-actual))),
                           'waveformParity': metrics,
                           'hostSeconds': preconversion_seconds + time.perf_counter()-started})
            print(f'Core ML parity passed: {label}', flush=True)
        report = {'source': MODEL, 'revision': REVISION, 'sourceSHA256': source_hashes, 'parityPassed': True,
                  'license': 'Apache-2.0', 'shape': [1, 64000, 2], 'checks': checks,
                  'fixturePreparation': fixture_info,
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

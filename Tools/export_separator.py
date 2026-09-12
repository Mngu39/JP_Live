"""Experimental conversion, not a prevalidated bundled separator.
Run on the macOS build host with torch, speechbrain, coremltools and soundfile installed.
Export success is only the first gate; compare stems and Japanese ASR before live integration.
"""
from pathlib import Path
import argparse
import json
import numpy as np
import torch
import coremltools as ct
from speechbrain.inference.separation import SepformerSeparation

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--cache', type=Path, default=Path('work/separator-source'))
args = parser.parse_args()
torch.manual_seed(7)
separator = SepformerSeparation.from_hparams(
    source='speechbrain/sepformer-whamr16k', savedir=str(args.cache), run_opts={'device': 'cpu'})
assert int(separator.hparams.sample_rate) == 16000, 'Model sample rate must be verified, not resampled by assumption'

class FixedSeparator(torch.nn.Module):
    def __init__(self, wrapped):
        super().__init__()
        self.encoder = wrapped.mods.encoder
        self.masknet = wrapped.mods.masknet
        self.decoder = wrapped.mods.decoder
    def forward(self, mixture):
        encoded = self.encoder(mixture)
        mask = self.masknet(encoded)
        stems = encoded.unsqueeze(0).repeat(2, 1, 1, 1) * mask
        return torch.stack([self.decoder(stems[0]), self.decoder(stems[1])], dim=-1)

wrapper = FixedSeparator(separator).eval()
example = torch.randn(1, 64000) * 0.03
with torch.no_grad():
    traced = torch.jit.trace(wrapper, example, check_trace=True)
    reference = wrapper(example).numpy()
assert reference.shape == (1, 64000, 2), reference.shape
model = ct.convert(traced, inputs=[ct.TensorType(name='mixture', shape=(1, 64000))],
    outputs=[ct.TensorType(name='stems')], convert_to='mlprogram',
    minimum_deployment_target=ct.target.iOS18, compute_precision=ct.precision.FLOAT32)
args.output.parent.mkdir(parents=True, exist_ok=True)
actual = model.predict({'mixture': example.numpy()})['stems']
max_error = float(np.max(np.abs(reference-actual)))
assert np.allclose(reference, actual, rtol=1e-3, atol=1e-3), max_error
model.save(str(args.output))
args.output.with_suffix('.validation.json').write_text(json.dumps({
    'shape': list(actual.shape), 'max_error': max_error,
    'scope': 'synthetic conversion parity only; not Japanese quality or device latency'}, indent=2))

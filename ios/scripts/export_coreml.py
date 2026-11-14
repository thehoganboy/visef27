"""Export the pinned MiDaS small weights with exact RGB ImageNet normalization.

Run on macOS after the workflow prepares pinned source repositories and weights.
Real-frame PyTorch/ONNX/Core ML comparison is mandatory; build failure is explicit.
"""
from pathlib import Path
import hashlib
import json
import sys
import numpy as np
import torch
import coremltools as ct
from PIL import Image
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[2]
WEIGHT_SHA = '70d6b9c891758c67f974a6097fb0c608c7ee67fb81ac3e5588847d5596d56fca'


def main():
    folder = Path(__file__).resolve().parent
    weights = folder / 'midas_v21_small_256.pt'
    if hashlib.sha256(weights.read_bytes()).hexdigest() != WEIGHT_SHA:
        raise RuntimeError('Weight integrity mismatch')
    original_load = torch.hub.load
    def local_load(repo, model, *args, **kwargs):
        if repo == 'rwightman/gen-efficientnet-pytorch':
            return original_load(str(folder / 'efficientnet'), model, *args, source='local', **kwargs)
        raise RuntimeError(f'Unexpected network architecture dependency: {repo}')
    torch.hub.load = local_load
    sys.path.insert(0, str(folder / 'MiDaS'))
    from midas.midas_net_custom import MidasNet_small
    model = MidasNet_small(None, features=64, backbone='efficientnet_lite3', exportable=True,
                          non_negative=True, blocks={'expand': True})
    model.load_state_dict(torch.load(weights, map_location='cpu', weights_only=True), strict=True)
    model.eval()
    class ImageNormalized(torch.nn.Module):
        def __init__(self, network):
            super().__init__()
            self.network = network
            self.register_buffer('mean', torch.tensor([.485,.456,.406]).view(1,3,1,1))
            self.register_buffer('std', torch.tensor([.229,.224,.225]).view(1,3,1,1))
        def forward(self, rgb):
            return self.network((rgb-self.mean)/self.std)
    wrapped = ImageNormalized(model).eval()
    # EfficientNet caches fixed-shape padding during its first invocation. Graph
    # text can change on retrace; validate numeric behavior explicitly instead.
    with torch.no_grad():
        wrapped(torch.rand(1,3,256,192))
    traced = torch.jit.trace(wrapped, torch.rand(1,3,256,192), check_trace=False)
    for _ in range(3):
        sample = torch.rand(1,3,256,192)
        with torch.no_grad():
            torch.testing.assert_close(traced(sample), wrapped(sample), rtol=1e-4, atol=1e-4)
    converted = ct.convert(traced,
        inputs=[ct.ImageType(name='x',shape=(1,3,256,192),color_layout=ct.colorlayout.RGB,scale=1/255.0)],
        outputs=[ct.TensorType(name='depth')], minimum_deployment_target=ct.target.iOS16,
        compute_units=ct.ComputeUnit.CPU_ONLY, convert_to='mlprogram', compute_precision=ct.precision.FLOAT32)
    session = ort.InferenceSession(str(ROOT/'android/app/src/main/assets/midas_small.onnx'), providers=['CPUExecutionProvider'])
    fixtures = sorted((ROOT/'tests/fixtures/demo').glob('*.png'))
    if len(fixtures) < 3:
        raise RuntimeError('Real-frame parity fixtures are required')
    evidence = []
    for path in fixtures:
        image = Image.open(path).convert('RGB').resize((192,256), Image.Resampling.BILINEAR)
        rgb = np.asarray(image,dtype=np.float32).transpose(2,0,1)[None]/255
        with torch.no_grad():
            reference = wrapped(torch.from_numpy(rgb)).numpy()
        norm = (rgb-np.array([.485,.456,.406],np.float32)[None,:,None,None])/np.array([.229,.224,.225],np.float32)[None,:,None,None]
        android = session.run(None,{session.get_inputs()[0].name: norm})[0]
        ios = np.asarray(converted.predict({'x':image})['depth'])
        error_android = float(np.max(np.abs(android-reference))/max(float(np.max(np.abs(reference))),1e-6))
        error_ios = float(np.max(np.abs(ios-reference))/max(float(np.max(np.abs(reference))),1e-6))
        evidence.append({'image':path.name,'onnx_max_relative_error':error_android,'coreml_max_relative_error':error_ios})
        if not np.isfinite(ios).all() or error_android > .001 or error_ios > .01:
            raise RuntimeError(f'Model parity failed: {evidence[-1]}')
    converted.user_defined_metadata['weights_sha256'] = WEIGHT_SHA
    converted.user_defined_metadata['input_contract'] = 'RGB 192x256, exact per-channel ImageNet normalization in graph'
    converted.save(str(ROOT/'ios/HorusEyes/DepthModel.mlpackage'))
    (ROOT/'ios/model_parity.json').write_text(json.dumps(evidence,indent=2))
    print(json.dumps(evidence,indent=2))

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
SegFormer B3 → CoreML 変換スクリプト

Usage:
    python convert_segformer.py

入力: DIstance_rearCAM/models/segformer_b3_amodal_blur_best.pth
出力: DIstance_rearCAM/models/EyelidSegFormer.mlpackage

必要パッケージ:
    pip install torch transformers coremltools
"""

import torch
import torch.nn.functional as F
import coremltools as ct
from transformers import SegformerForSemanticSegmentation

# 1. モデル読込（B3, 3クラス）
print("Loading SegFormer B3 model...")
model = SegformerForSemanticSegmentation.from_pretrained(
    "nvidia/segformer-b3-finetuned-ade-512-512",
    num_labels=3,
    ignore_mismatched_sizes=True,
)

print("Loading checkpoint...")
ckpt = torch.load(
    "DIstance_rearCAM/models/segformer_b3_amodal_blur_best.pth",
    map_location="cpu",
)

# state_dict キーの確認と読込
if "model" in ckpt:
    state_dict = ckpt["model"]
elif "state_dict" in ckpt:
    state_dict = ckpt["state_dict"]
else:
    state_dict = ckpt

model.load_state_dict(state_dict, strict=False)
model.eval()
print("Model loaded successfully")


# 2. upsample + sigmoid をモデルに内包するラッパー
class SegFormerWrapper(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        logits = self.m(pixel_values=x).logits  # (1,3,128,128)
        up = F.interpolate(
            logits, size=(512, 512), mode="bilinear", align_corners=False
        )
        return torch.sigmoid(up)  # (1,3,512,512)


wrapper = SegFormerWrapper(model)

# 3. TorchScript トレース
print("Tracing model...")
dummy_input = torch.randn(1, 3, 512, 512)
try:
    traced = torch.jit.trace(wrapper, dummy_input)
    print("TorchScript trace successful")
    use_onnx = False
except Exception as e:
    print(f"TorchScript trace failed: {e}")
    print("Trying ONNX export...")
    onnx_path = "segformer_temp.onnx"
    torch.onnx.export(
        wrapper,
        dummy_input,
        onnx_path,
        input_names=["input"],
        output_names=["probabilities"],
        opset_version=14,
    )
    use_onnx = True

# 4. CoreML 変換
print("Converting to CoreML...")
if use_onnx:
    import onnx

    mlmodel = ct.converters.onnx.convert(
        model=onnx_path,
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )
else:
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 3, 512, 512))],
        outputs=[ct.TensorType(name="probabilities")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )

# 5. 保存
output_path = "DIstance_rearCAM/models/EyelidSegFormer.mlpackage"
mlmodel.save(output_path)
print(f"CoreML model saved to {output_path}")

# 6. 検証
print("Verifying...")
import numpy as np

test_input = np.random.randn(1, 3, 512, 512).astype(np.float32)

with torch.no_grad():
    torch_out = wrapper(torch.tensor(test_input)).numpy()

coreml_out = mlmodel.predict({"input": test_input})["probabilities"]
diff = np.abs(torch_out - coreml_out).mean()
print(f"Mean absolute difference: {diff:.6f}")
if diff < 0.01:
    print("Conversion complete!")
else:
    print("WARNING: Large difference detected!")

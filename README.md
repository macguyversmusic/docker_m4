# docker_m4

A RunPod Serverless worker: ComfyUI with Qwen-Image-Edit-2511 and the tools for targeted fixes, all baked into the image. A worker never downloads anything at start-up. The image is about 50 GB.

## What's inside

| Model | Used for | Licence |
|---|---|---|
| Qwen-Image-Edit-2511, fp8 mixed | the edit model | Apache-2.0 |
| Qwen2.5-VL 7B, fp8 | its text encoder | Apache-2.0 |
| Qwen-Image VAE | decoding | Apache-2.0 |
| Wan2.1 2x VAE (spacepxl) | decoding straight to twice the size | Apache-2.0 |
| Qwen-Image-Edit-2511 Lightning, 8-step LoRA | quick test passes | Apache-2.0 |
| GroundingDINO SwinT + SAM-HQ ViT-H | text-to-mask, e.g. "left ear" | Apache-2.0 |
| BiRefNet general | background cut-out | MIT |

| Node pack | Used for | Licence |
|---|---|---|
| ComfyUI-RMBG | text-to-mask and cut-out | GPL-3.0 |
| ComfyUI-Inpaint-CropAndStitch | redraws only a masked area | GPL-3.0 |
| ComfyUI-KJNodes | Color Match, among others | GPL-3.0 |
| ComfyUI-VAE-Utils | loads the 2x VAE | MIT |

Base image: `runpod/worker-comfyui:5.10.0-base-cuda12.8.1` (AGPL-3.0).

## Deploying on RunPod Serverless

1. New endpoint → GitHub repo → this repo, branch `main`, Dockerfile at the root.
2. GPU: 48 GB class (L40S, A6000). CUDA 12.8 or newer.
3. Max workers 5, active workers 0, so it costs nothing while idle.

The model downloads run in parallel to fit RunPod's 30-minute build limit. If a build still runs out of time, build the image with GitHub Actions to GHCR and point the endpoint at that image instead.

## Requests

The standard worker-comfyui input: a workflow in ComfyUI's API format, plus images by name.

```json
{"input": {"workflow": {"...": "..."}, "images": [{"name": "rabbit.png", "image": "<base64>"}]}}
```

`workflows/generate.json` is the starting workflow: Qwen-Image-Edit-2511 at its full settings (40 steps, CFG 4), output 864×1536, with the source image and a close-up crop of its top centre as the two references. Replace `{{PROMPT}}` before sending.

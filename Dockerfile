# syntax=docker/dockerfile:1
#
# RunPod Serverless worker: ComfyUI with Qwen-Image-Edit-2511 plus the tools for
# targeted fixes (text-to-mask, crop-and-stitch inpainting, colour matching,
# background cut-out and a 2x upscaling decode). Everything is baked in, so a
# worker never downloads anything at start-up.
#
# The workflow travels with each request (worker-comfyui's input.workflow), so
# tuning it needs no rebuild.
#
# The -cuda12.8.1 base pins PyTorch to CUDA 12.8; the plain base can fail on
# 12.8 hosts with "no kernel image is available".
FROM runpod/worker-comfyui:5.10.0-base-cuda12.8.1 AS base

# Each download is its own stage, so BuildKit fetches them in parallel
# (RunPod's GitHub builds stop after 30 minutes).

# The edit model, fp8 mixed (the bf16 one is 54 GB and needs an 80 GB GPU).
FROM base AS diffusion
RUN mkdir -p /m/diffusion_models \
 && wget -q --tries=3 -O /m/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors \
      https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors

# Its text encoder (Qwen2.5-VL 7B).
FROM base AS text-encoder
RUN mkdir -p /m/text_encoders \
 && wget -q --tries=3 -O /m/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors \
      https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors

# The Qwen VAE, and the Wan2.1 2x VAE: Qwen-Image kept the Wan 2.1 encoder, so
# this one decodes the same latent straight to twice the size.
FROM base AS vae
RUN mkdir -p /m/vae \
 && wget -q --tries=3 -O /m/vae/qwen_image_vae.safetensors \
      https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors \
 && wget -q --tries=3 -O /m/vae/Wan2.1_VAE_upscale2x_imageonly_real_v1.safetensors \
      https://huggingface.co/spacepxl/Wan2.1-VAE-upscale2x/resolve/main/Wan2.1_VAE_upscale2x_imageonly_real_v1.safetensors

# The 8-step Lightning LoRA, for quick test passes; final renders use the full 40 steps.
FROM base AS lora
RUN mkdir -p /m/loras \
 && wget -q --tries=3 -O /m/loras/Qwen-Image-Edit-2511-Lightning-8steps-V1.0-bf16.safetensors \
      https://huggingface.co/lightx2v/Qwen-Image-Edit-2511-Lightning/resolve/main/Qwen-Image-Edit-2511-Lightning-8steps-V1.0-bf16.safetensors

# Text-to-mask (GroundingDINO + SAM-HQ) and the background cut-out (BiRefNet),
# in the folders ComfyUI-RMBG reads from.
FROM base AS segment
RUN mkdir -p /m/grounding-dino /m/SAM /m/RMBG/BiRefNet \
 && wget -q --tries=3 -O /m/grounding-dino/GroundingDINO_SwinT_OGC.cfg.py \
      https://huggingface.co/1038lab/GroundingDINO/resolve/main/GroundingDINO_SwinT_OGC.cfg.py \
 && wget -q --tries=3 -O /m/grounding-dino/groundingdino_swint_ogc.pth \
      https://huggingface.co/1038lab/GroundingDINO/resolve/main/groundingdino_swint_ogc.pth \
 && wget -q --tries=3 -O /m/SAM/sam_hq_vit_h.pth \
      https://huggingface.co/1038lab/sam/resolve/main/sam_hq_vit_h.pth \
 && for f in BiRefNet-general.safetensors birefnet.py BiRefNet_config.py config.json; do \
      wget -q --tries=3 -O /m/RMBG/BiRefNet/$f https://huggingface.co/1038lab/BiRefNet/resolve/main/$f; \
    done

FROM base

# opencv (pulled in by ComfyUI-RMBG) needs these at import time.
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

# Models first, one layer each, so a change to the node packs below leaves them cached.
COPY --from=diffusion /m/diffusion_models/ /comfyui/models/diffusion_models/
COPY --from=text-encoder /m/text_encoders/ /comfyui/models/text_encoders/
COPY --from=vae /m/vae/ /comfyui/models/vae/
COPY --from=lora /m/loras/ /comfyui/models/loras/
COPY --from=segment /m/ /comfyui/models/

# Node packs. comfy-node-install puts each pack's requirements in /comfyui/.venv,
# but the worker starts ComfyUI from /opt/venv (worker-comfyui issue #237), so
# install them there too. VAE-Utils (for the 2x VAE) is pinned to a known-good commit.
RUN comfy-node-install comfyui-rmbg comfyui-inpaint-cropandstitch comfyui-kjnodes \
 && git clone https://github.com/spacepxl/ComfyUI-VAE-Utils /comfyui/custom_nodes/ComfyUI-VAE-Utils \
 && git -C /comfyui/custom_nodes/ComfyUI-VAE-Utils checkout 4c62ea005897fafbc593d69bedb8308ec9f932fd \
 && for r in /comfyui/custom_nodes/*/requirements.txt; do \
      [ -f "$r" ] && uv pip install --python /opt/venv/bin/python -r "$r" || true; \
    done

ENV COMFY_LOG_LEVEL=INFO

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
FROM runpod/worker-comfyui:5.10.0-base-cuda12.8.1

# opencv (pulled in by ComfyUI-RMBG) needs these at import time.
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

# Models, downloaded straight into ComfyUI's folders. Each RUN fetches its files
# in parallel to stay inside RunPod's 30-minute build limit, and fails if any
# download fails.
ARG HF=https://huggingface.co

# The edit model (fp8 mixed; the bf16 one is 54 GB and needs an 80 GB GPU), the
# Qwen VAE, the Wan2.1 2x VAE (decodes the same latent straight to twice the
# size) and the 8-step Lightning LoRA for quick test passes.
RUN mkdir -p /comfyui/models/diffusion_models /comfyui/models/vae /comfyui/models/loras \
 && cd /comfyui/models || exit 1; \
    wget -q --tries=3 -O diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors \
      $HF/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors & p1=$!; \
    wget -q --tries=3 -O vae/qwen_image_vae.safetensors \
      $HF/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors & p2=$!; \
    wget -q --tries=3 -O vae/Wan2.1_VAE_upscale2x_imageonly_real_v1.safetensors \
      $HF/spacepxl/Wan2.1-VAE-upscale2x/resolve/main/Wan2.1_VAE_upscale2x_imageonly_real_v1.safetensors & p3=$!; \
    wget -q --tries=3 -O loras/Qwen-Image-Edit-2511-Lightning-8steps-V1.0-bf16.safetensors \
      $HF/lightx2v/Qwen-Image-Edit-2511-Lightning/resolve/main/Qwen-Image-Edit-2511-Lightning-8steps-V1.0-bf16.safetensors & p4=$!; \
    wait $p1 && wait $p2 && wait $p3 && wait $p4

# The text encoder (Qwen2.5-VL 7B), plus text-to-mask (GroundingDINO + SAM-HQ)
# and the background cut-out (BiRefNet) in the folders ComfyUI-RMBG reads from.
RUN mkdir -p /comfyui/models/text_encoders /comfyui/models/grounding-dino /comfyui/models/SAM /comfyui/models/RMBG/BiRefNet \
 && cd /comfyui/models || exit 1; \
    wget -q --tries=3 -O text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors \
      $HF/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors & p1=$!; \
    wget -q --tries=3 -O grounding-dino/GroundingDINO_SwinT_OGC.cfg.py \
      $HF/1038lab/GroundingDINO/resolve/main/GroundingDINO_SwinT_OGC.cfg.py & p2=$!; \
    wget -q --tries=3 -O grounding-dino/groundingdino_swint_ogc.pth \
      $HF/1038lab/GroundingDINO/resolve/main/groundingdino_swint_ogc.pth & p3=$!; \
    wget -q --tries=3 -O SAM/sam_hq_vit_h.pth \
      $HF/1038lab/sam/resolve/main/sam_hq_vit_h.pth & p4=$!; \
    for f in BiRefNet-general.safetensors birefnet.py BiRefNet_config.py config.json; do \
      wget -q --tries=3 -O RMBG/BiRefNet/$f $HF/1038lab/BiRefNet/resolve/main/$f || exit 1; \
    done; \
    wait $p1 && wait $p2 && wait $p3 && wait $p4

# Node packs. comfy-node-install puts each pack's requirements in /comfyui/.venv,
# but the worker starts ComfyUI from /opt/venv (worker-comfyui issue #237), so
# install them there too. VAE-Utils (for the 2x VAE) is pinned to a known-good commit.
RUN comfy-node-install comfyui-rmbg comfyui-inpaint-cropandstitch comfyui-kjnodes \
 && git clone https://github.com/spacepxl/ComfyUI-VAE-Utils /comfyui/custom_nodes/ComfyUI-VAE-Utils \
 && git -C /comfyui/custom_nodes/ComfyUI-VAE-Utils checkout 4c62ea005897fafbc593d69bedb8308ec9f932fd \
 && for r in /comfyui/custom_nodes/*/requirements.txt; do \
      [ -f "$r" ] && uv pip install --python /opt/venv/bin/python -r "$r" || true; \
    done

# RunPod's GitHub builds need the handler in the repo. This is the official
# worker-comfyui 5.10.0 handler, identical to the one already in the base image.
COPY handler.py /handler.py

ENV COMFY_LOG_LEVEL=INFO

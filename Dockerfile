# Minimal build test: the base image and the handler only. The full Dockerfile is in commit 2611209.
FROM runpod/worker-comfyui:5.10.0-base-cuda12.8.1
COPY handler.py /handler.py

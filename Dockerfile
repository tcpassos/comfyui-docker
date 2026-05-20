# =============================================================================
#  Docker image pre-configured for ComfyUI on RunPod / Vast.ai
#  - PyTorch 2.12 + CUDA 13.0 (Blackwell / NVFP4 compatible)
#  - ComfyUI cloned into /opt/ComfyUI (volume only stores models/nodes/user)
#  - Sage Attention compiled per-GPU-arch at runtime (see entrypoint.sh)
# =============================================================================

# Official PyTorch image: torch 2.12 + CUDA 13.0 toolkit + cuDNN9 + nvcc.
# ~7.6 GB base vs ~14 GB for the previous runpod/pytorch base, and removes the
# need to reinstall torch on top (saves another ~5 GB of layer overhead).
# Tags at https://hub.docker.com/r/pytorch/pytorch/tags
ARG BASE_IMAGE=pytorch/pytorch:2.12.0-cuda13.0-cudnn9-devel
FROM ${BASE_IMAGE}

# ----- Build args (editable at build time without rewriting Dockerfile) ------
ARG COMFYUI_VERSION=v0.21.1
ARG INSTALL_SAGE=true
ENV COMFYUI_VERSION=${COMFYUI_VERSION} \
    COMFYUI_HOME=/opt/ComfyUI \
    WORKSPACE=/workspace \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    DEBIAN_FRONTEND=noninteractive \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH}

# ----- System ----------------------------------------------------------------
# openssh-server is included for Vast.ai compatibility (RunPod injects SSH via
# its own template wrapper; Vast.ai expects the image itself to run sshd).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg git curl ca-certificates jq nginx aria2 openssh-server \
    && mkdir -p /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*

# ----- ComfyUI in /opt -------------------------------------------------------
RUN git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_HOME}" \
    && cd "${COMFYUI_HOME}" \
    && git checkout "${COMFYUI_VERSION}"

# Verify the base image actually provides the expected torch/CUDA stack.
ENV INSTALL_SAGE=${INSTALL_SAGE}
RUN python3 -c "import torch, torchvision, torchaudio; print('torch', torch.__version__, 'cuda', torch.version.cuda); assert torch.version.cuda.startswith('13.'), torch.version.cuda"

# ----- ComfyUI requirements + custom-node dependencies -----------------------
RUN pip install --upgrade-strategy only-if-needed -r "${COMFYUI_HOME}/requirements.txt" \
    && pip install gitpython toml \
    # kornia 0.8+ removed `pad` from geometry.transform.pyramid, which breaks
    # ComfyUI-LTXVideo's pyramid_blending module. Pin to a working version.
    && pip install "kornia==0.7.3"

# ----- Entrypoint + example config + nginx -----------------------------------
COPY entrypoint.sh /usr/local/bin/comfy-entrypoint
COPY config.example.json /opt/config.example.json
COPY nginx.conf /etc/nginx/conf.d/comfyui.conf
RUN chmod +x /usr/local/bin/comfy-entrypoint \
    && rm -f /etc/nginx/sites-enabled/default \
    && rm -f /etc/nginx/conf.d/default.conf \
    # RunPod base image's nginx.conf does NOT include conf.d/*.conf — inject it
    && if ! grep -q "include /etc/nginx/conf.d/\*\.conf" /etc/nginx/nginx.conf; then \
         sed -i '/^http\s*{/a\    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf; \
       fi \
    && nginx -t

EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8188/ >/dev/null || exit 1

WORKDIR ${COMFYUI_HOME}
ENTRYPOINT ["/usr/local/bin/comfy-entrypoint"]

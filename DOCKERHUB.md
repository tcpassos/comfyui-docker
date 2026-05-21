# tcpassos/comfyui-cloud

Pre-baked **ComfyUI** image for **RunPod** and **Vast.ai** with fast cold start.
Custom nodes and models are declared in a `config.json` and downloaded on first boot — the workflow lives in the volume, not the image.

- **Base**: `pytorch/pytorch:2.12.0-cuda13.0-cudnn9-runtime`
- **Image size**: ~7.2 GB
- **ComfyUI**: latest (overridable via `--build-arg COMFYUI_VERSION=`)
- **Boot stack**: [`uv`](https://github.com/astral-sh/uv) for pip, `hf_transfer` + `aria2c` for parallel downloads, shallow clones
- **Pre-flight GPU check**: aborts in <1s if the host's NVIDIA driver is too old for the image's CUDA runtime (no more 40-min boots ending in `torch.cuda` errors)
- **SageAttention 2.x**: resolved at boot — prebuilt wheel matching your GPU's SM is pulled from [`tcpassos/sage-wheels-linux`](https://github.com/tcpassos/sage-wheels-linux), cached on the volume

---

## Quick start

Generate a `config.json` at **[comfyforge.app](https://comfyforge.app)** (import a workflow → publish → copy the URL), then point the container at it via `CONFIG_URL`. `CONFIG_URL` is optional: without it, the image boots with a minimal example (ComfyUI-Manager + Lora Manager, no models).

### RunPod

| Field | Value |
|---|---|
| Container Image | `tcpassos/comfyui-cloud:latest` |
| Container Disk | **20–25 GB** (image + pip caches) |
| Volume Disk | **40–100 GB** (models live here) |
| Volume Mount Path | `/workspace` |
| Expose HTTP Ports | `8188` |

### Vast.ai

| Field | Value |
|---|---|
| Image Path:Tag | `tcpassos/comfyui-cloud:latest` |
| Launch Mode | Docker ENTRYPOINT |
| Docker Options | `-p 8188:8188 -p 22:22 -e OPEN_BUTTON_PORT=8188` |
| Disk Space | **25 GB** minimum (no container/volume split — attach a separate volume for models) |

> Filter offers by **CUDA Version ≥ 13.0** — the image ships CUDA 13 (torch 2.12 + cu130). On RTX 3090/4090/5090 the host needs NVIDIA driver **≥ R580**, otherwise boot fails with `error 804: forward compatibility was attempted on non supported HW`.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CONFIG_URL` | *(unset)* | Public URL of a `config.json`. If unset and `/workspace/config.json` doesn't exist, the bundled example is used. |
| `HF_TOKEN` | — | Hugging Face token. Required for gated models (FLUX.1, etc.). |
| `CIVITAI_TOKEN` | — | Civitai API token. Required for Civitai models. |
| `INSTALL_SAGE` | `true` | Install SageAttention 2.x at boot. |
| `SAGE_PREBUILT` | `true` | Try a prebuilt wheel matching your GPU's SM before any source build. |
| `SAGE_PREBUILT_REPO` | `tcpassos/sage-wheels-linux` | GitHub repo for prebuilt Sage wheels. |
| `SAGE_BUILD_JOBS` | `4` | `MAX_JOBS` for the fallback source build (lower it on small instances). |
| `UPDATE_NODES` | `false` | `git pull` unpinned custom nodes on every boot. |
| `PORT` | `8188` | ComfyUI / nginx port. |
| `OPEN_BUTTON_PORT` | — | *(Vast.ai)* Sets the blue **Open** button target. |
| `OPEN_BUTTON_TOKEN` | — | *(Vast.ai)* Bearer token appended to the Open URL. |
| `FILEBROWSER_PASSWORD` | random | Admin password for File Browser at `/files/`. Printed in the boot log if random. |
| `GH_TOKEN` | — | Optional — raises GitHub API rate limit when querying Sage releases. |

---

## Layout

| Item | Location | Persistent? |
|---|---|---|
| ComfyUI, Python, torch, uv, aria2 | `/opt/ComfyUI` (image) | No |
| Custom nodes | `/workspace/custom_nodes` | Yes (volume) |
| Models | `/workspace/models/<category>` | Yes |
| Outputs, ComfyUI user configs | `/workspace/output`, `/workspace/user` | Yes |
| SageAttention wheel cache | `/workspace/cache/sage_wheels` | Yes |
| `config.json` (nodes + models) | `/workspace/config.json` | Yes |

---

## First boot (5–15 min)

1. Resolve `config.json` (from `CONFIG_URL` or the bundled example).
2. Clone custom nodes declared in `nodes[]`.
3. `uv pip install -r` all node requirements in a single resolver pass.
4. Download models in `models[]` with `aria2c` (up to 16 connections/file, falls back to `curl`).
5. Install SageAttention (prebuilt → cache → source → PyPI fallback).
6. Start ComfyUI behind nginx on port `8188`.

Subsequent boots are ~30 s: nodes and models are already on the volume.

---

## Smoke test

```bash
docker run --rm --entrypoint python3 tcpassos/comfyui-cloud:latest \
  -c "import torch, torchvision, torchaudio; print(torch.__version__, torch.version.cuda)"
# 2.12.0+cu130 13.0
```

---

## Links

- **Config generator**: [comfyforge.app](https://comfyforge.app)
- **Prebuilt Sage wheels**: [github.com/tcpassos/sage-wheels-linux](https://github.com/tcpassos/sage-wheels-linux)
- **Source / full docs**: [github.com/tcpassos/comfyui-docker](https://github.com/tcpassos/comfyui-docker)

# ComfyUI cloud Docker image

Pre-baked Docker image to run ComfyUI on **RunPod** and **Vast.ai** with fast cold start.
Everything heavy ships in the image; what changes per workflow lives in `/workspace/config.json`.

## Layout

| Item | Location | Persistent? |
|---|---|---|
| ComfyUI, Python, torch, uv, aria2, ffmpeg | `/opt/ComfyUI` (in the image) | No (ships with the image) |
| Custom nodes | `/workspace/custom_nodes` | Yes (volume) |
| Models | `/workspace/models/<category>` | Yes (volume) |
| Workflows, outputs, ComfyUI configs | `/workspace/user`, `/workspace/output` | Yes (volume) |
| SageAttention wheel cache | `/workspace/cache/sage_wheels` | Yes (volume) |
| List of nodes + models to download | `/workspace/config.json` | Yes (volume) |

## Build

```powershell
docker build -t tcpassos/comfyui-cloud:latest C:\dev\comfyui-docker
docker push tcpassos/comfyui-cloud:latest
```

> Final size: ~7.2 GB (using the `pytorch/pytorch:*-runtime` base; the previous `-devel` base produced an image of ~16 GB). Build takes ~5–10 min on a good connection.

(Optional) Change ComfyUI version at build time:
```powershell
docker build --build-arg COMFYUI_VERSION=v0.22.0 -t tcpassos/comfyui-cloud:v0.22 C:\dev\comfyui-docker
```

### Validate the image locally (smoke test)

```powershell
docker run --rm --entrypoint python3 tcpassos/comfyui-cloud:latest -c "import torch, torchvision, torchaudio; print('torch', torch.__version__, 'cuda', torch.version.cuda, 'tv', torchvision.__version__, 'ta', torchaudio.__version__)"
```

Expected output:
```
torch 2.12.0+cu130 cuda 13.0 tv 0.27.0+cu130 ta 2.11.0+cu130
```

> The `--entrypoint python3` flag is required; otherwise the image's ENTRYPOINT runs the full node/model provisioning before your command.
>
> `sageattention` is NOT in the image — it is installed at boot (prebuilt wheel from `$SAGE_PREBUILT_REPO` matching your GPU's SM). See *About SageAttention install order* below.

### About SageAttention install order

Sage 2.x has to match the GPU's compute capability (SM 75/80/86/89/90/120),
so it can't ship in the image. The entrypoint resolves it at boot in this
order — first one that succeeds wins:

1. **Volume cache**: `/workspace/cache/sage_wheels/sageattention-<ver>-<SM>-cp<py>-cp<py>-linux_x86_64.whl`
   left from a previous boot of the same instance type.
2. **Prebuilt release**: GitHub release on `$SAGE_PREBUILT_REPO`
   (default [`tcpassos/sage-wheels-linux`](https://github.com/tcpassos/sage-wheels-linux))
   whose tag matches the running `torch-X-cuY-pyZ` combo and that ships a
   wheel for the GPU's SM. Downloaded into the volume cache, so step 1
   handles future boots.
3. **Local source build** for the detected SM — **only if the image was
   built FROM a `pytorch/pytorch:*-devel` base** (the default `-runtime`
   base ships no nvcc). ~5 min, ~6 GB RAM when available. Also cached.
4. **PyPI `sageattention`** (Sage 1.x) as last resort — works but lacks
   `per_warp_int8_cuda` used by some custom nodes.

Set `SAGE_PREBUILT=false` to skip step 2, or `INSTALL_SAGE=false` to skip
the whole Sage setup.

### Boot-time speed optimizations

The image trades the heavy `-devel` base + `pip` for a leaner stack:

- **`pytorch/pytorch:*-runtime` base** (~3 GB vs ~7.6 GB for `-devel`).
  Removes nvcc; Sage now comes from prebuilt wheels (see above).
- **[uv](https://github.com/astral-sh/uv)** replaces `pip` for the boot-time
  install of custom-node dependencies — typically 10–30× faster, with a
  single resolver pass across all `requirements.txt` files instead of one
  pass per node.
- **`aria2c`** replaces `curl` for model downloads, using up to 16 parallel
  connections per file — typically 4–16× faster for multi-GB models from
  HuggingFace / Civitai CDNs. Falls back to `curl` automatically on error.
- **`git clone --depth 1`** for ComfyUI — drops history, ~50 MB smaller and
  marginally faster build.

## RunPod setup

### 1. Create the template

RunPod Console → **Templates** → **+ New Template**:

| Field | Value |
|---|---|
| Template Name | `comfyui-cloud` (any name) |
| Container Image | `tcpassos/comfyui-cloud:latest` |
| Container Disk | `25 GB` |
| Volume Disk | `100 GB` (size for your models) |
| Volume Mount Path | `/workspace` |
| Expose HTTP Ports | `8188` (RunPod gives an HTTPS URL via `proxy.runpod.net`) |
| Expose TCP Ports | `22` (SSH, optional) |
| Container Start Command | *(empty — uses the image's ENTRYPOINT)* |

**Environment Variables:**

| Name | Value |
|---|---|
| `HF_TOKEN` | your HuggingFace token (read) |
| `CIVITAI_TOKEN` | your Civitai token |
| `CONFIG_URL` | **optional**. Public URL (Gist / raw GitHub) of a `config.json`. If unset *and* `/workspace/config.json` does not yet exist in the volume, the entrypoint seeds `/workspace/config.json` from the bundled `/opt/config.example.json` (a minimal two-node setup with ComfyUI-Manager and ComfyUI-Lora-Manager). |
| `UPDATE_NODES` | `false` (default) — does not update existing custom nodes on boot, keeping deploys reproducible. `true` runs `git pull --ff-only` on every node without a pinned `ref`. |
| `PORT` | `8188` (optional, default is 8188) |
| `INSTALL_SAGE` | `true` (default) — install SageAttention 2.x at boot if not already present. Set to `false` to skip entirely. |
| `SAGE_PREBUILT` | `true` (default) — before building from source, try to download a prebuilt wheel from `$SAGE_PREBUILT_REPO` matching the running torch / CUDA / Python / GPU SM. Set to `false` to force a local build. |
| `SAGE_PREBUILT_REPO` | `tcpassos/sage-wheels-linux` (default) — GitHub `owner/name` to look up prebuilt Sage wheels from. |
| `SAGE_BUILD_JOBS` | `4` (default) — `MAX_JOBS` passed to the source build when the prebuilt path is skipped/unavailable. Lower it on small instances (1 for 4–8 GB RAM, 2 for 8–16 GB). |
| `GH_TOKEN` | optional — GitHub token used only to raise the public REST API rate limit (60 → 5000 req/h) when querying releases. Not required for public repos. |

### 2. Deploy the pod

Templates → your template → **Deploy**:

- **GPU**: RTX PRO 4500 Blackwell (or any GPU whose driver supports CUDA 12.x+; the image ships CUDA 13).
- **Volume**: ✅ enable to persist `/workspace` across stops.
- **Region**: any; prefer the same region where you already have a volume if reusing it.

Deploy → wait for "Running".

### 3. First boot

**Takes 5–15 min** because the entrypoint will:
1. Resolve `config.json`: download from `CONFIG_URL` if set, else fall back to the bundled `/opt/config.example.json` (minimal two-node example).
2. Clone the custom nodes listed in `nodes[]`.
3. `pip install` the requirements of each node.
4. Download the models listed in `models[]` (HF / Civitai using the tokens from the env vars).

Follow along in **Connect → Logs**. When you see `Starting ComfyUI on port 8188`, you're ready.

> Without `CONFIG_URL` set and without a pre-populated volume: the entrypoint seeds `/workspace/config.json` from `/opt/config.example.json` (ComfyUI-Manager + ComfyUI-Lora-Manager, no models). Edit the file on the volume and restart the pod to customize.

### 4. Connect

**Connect → HTTP Service Port 8188** → opens ComfyUI at `https://<pod-id>-8188.proxy.runpod.net`.

### 5. Subsequent boots

Stop + Start of the same pod (with volume) → boot in **~30s**:
- Nodes and models are already on the volume → entrypoint skips clones and downloads.
- By default it does **not** `git pull` existing nodes (env `UPDATE_NODES=false`) — keeps boots reproducible. Set `UPDATE_NODES=true` on the template if you want unpinned nodes to be updated on Stop+Start.
- Pip reinstalls nothing (`pip install` is a no-op if already satisfied).

## Vast.ai setup

The same image runs on Vast.ai. The differences vs RunPod are all on the **template / docker-options** side — no separate image is needed.

### 1. Create the template

Vast.ai Console → **Templates** → **New Template**:

| Field | Value |
|---|---|
| Image Path:Tag | `tcpassos/comfyui-cloud:latest` |
| Docker Options | `-p 8188:8188 -p 22:22 -e OPEN_BUTTON_PORT=8188` |
| Launch Mode | **Docker ENTRYPOINT** (use the image's entrypoint — do **not** pick "SSH" or "Jupyter") |
| Disk Space | `30 GB` minimum (Vast does not separate container disk and volume — the whole instance disk holds models + nodes + container layers) |

> Vast does not have a "container disk vs volume" split like RunPod. `/workspace` is just a folder on the single instance disk. Size it like `RunPod container disk + volume`.

**Environment Variables** (`-e` on Docker Options, or the template's env field):

| Name | Value |
|---|---|
| `HF_TOKEN` | your HuggingFace token (read) |
| `CIVITAI_TOKEN` | your Civitai token |
| `CONFIG_URL` | **optional** — same as RunPod (public URL of a `config.json`). If unset, the entrypoint seeds from the bundled example. |
| `PUBLIC_KEY` (or `SSH_PUBLIC_KEY`) | your SSH public key (one line) — the entrypoint writes it to `/root/.ssh/authorized_keys` and starts `sshd` |
| `UPDATE_NODES` | `false` (default) / `true` |
| `OPEN_BUTTON_PORT` | `8188` — makes Vast's "Open" button point to ComfyUI |
| `OPEN_BUTTON_TOKEN` | *(optional)* a random string; if set, Vast appends `?token=...` to the URL and rejects requests without it (cheap auth) |
| `PORTAL_CONFIG` | *(optional)* shortcut buttons on Vast's Instance Portal. Recommended value: `localhost:8188:18188:/:ComfyUI\|localhost:8090:18090:/files/:File Browser` |

### 2. Rent an instance

- Pick a GPU whose driver supports CUDA 12.x+ (this image ships CUDA 13). RTX 4090 / 5090 / Blackwell-class is ideal.
- Use the template above.
- Rent → wait for status to flip to "Running".

### 3. First boot

Same as RunPod (~5–15 min): clone nodes, pip install, download models from `config.json`. Watch progress under **Logs** in the instance page.

### 4. Connect

- **ComfyUI**: click the blue **"Open"** button on the instance card — it opens `https://<host>:<external_port>` (Vast handles TLS via its proxy).
- **SSH**: `ssh -p <ssh_port> root@<host>` using the key whose public half you put in `PUBLIC_KEY`. Vast shows the exact command under the **SSH** tab.
- **File browser**: same as RunPod, on `/files/` of the ComfyUI URL (admin password is printed in the logs on first boot, unless you set `FILEBROWSER_PASSWORD`).

> **No `proxy.runpod.net` equivalent for arbitrary ports** — only the port flagged by `OPEN_BUTTON_PORT` gets the blue button. Other ports (filebrowser etc.) are reached through the nginx reverse proxy on `8188` (same as RunPod), so they "just work" via the Open button URL.

### Subsequent boots

Identical to RunPod: nodes and models are on the instance disk; entrypoint skips clones and downloads. Vast **destroys** the instance if you "Stop" without paying the storage fee — keep "Idle Storage" enabled if you want the disk to persist while the GPU is detached.

## Edit what gets downloaded

SSH into the pod and edit `/workspace/config.json`. Schema:

```json
{
  "nodes": [
    "https://github.com/user/repo",
    { "url": "https://github.com/kijai/ComfyUI-KJNodes", "ref": "v1.0.0" }
  ],
  "models": [
    { "category": "checkpoints", "url": "...", "filename": "model.safetensors" },
    { "path": "models/loras/character", "url": "...", "filename": "char.safetensors" },
    { "path": "custom_nodes/MyNode/models", "url": "...", "filename": "weights.pt" }
  ],
  "workflows": [
    { "url": "https://gist.../wan_i2v.json", "filename": "wan_i2v.json" }
  ]
}
```

**Fields:**
- `nodes[]` — Each item is a **string** (git URL, always HEAD) or an **object** `{url, ref?}` where `ref` is a sha / tag / branch (version pin for reproducibility). Clone + pip install requirements.
- `models[]` — Each item needs `url`. Destination:
  - `path` (relative to `/workspace`, or absolute) → takes precedence.
  - `category` → fallback, equivalent to `path: "models/<category>"`.
  - `filename` optional (derived from the URL if missing).
- `workflows[]` — Each item: `url` + optional `filename`. Downloaded to `/workspace/user/default/workflows/`.

> Invalid JSON is detected on boot (`jq empty`) and aborts with a clear message.

Valid categories (any subfolder under `models/`): `diffusion_models`, `checkpoints`, `loras`, `vae`, `text_encoders`, `clip_vision`, `controlnet`, `upscale_models`, `frame_interpolation`, `embeddings`, etc.

After editing, restart the pod (Stop + Start). The entrypoint will sync:
- Clones missing nodes / updates existing ones (`git pull`, only if `UPDATE_NODES=true`)
- Downloads missing models (skips existing ones, resumes via `--continue-at -`)

## Multiple templates with different configs (no rebuild)

Host each config in a public Gist (or raw GitHub) and create one template per workflow (on RunPod or Vast.ai), all using the same image `tcpassos/comfyui-cloud:latest`. Differentiate via the `CONFIG_URL` env var:

| Template | CONFIG_URL |
|---|---|
| `comfyui-wan` | `https://gist.githubusercontent.com/USER/HASH/raw/wan.json` |
| `comfyui-flux` | `https://gist.githubusercontent.com/USER/HASH/raw/flux.json` |
| `comfyui-sdxl` | `https://gist.githubusercontent.com/USER/HASH/raw/sdxl.json` |

On the first boot of each pod, if `/workspace/config.json` doesn't exist yet, the entrypoint fetches it from `CONFIG_URL`. Updated a config in the Gist? **Stop + Start the pod** and the entrypoint will pick up new nodes / models and sync.

## Add a new custom node without restarting the pod

```bash
cd /workspace/custom_nodes
git clone https://github.com/user/repo
[ -f repo/requirements.txt ] && pip install -r repo/requirements.txt
# restart just ComfyUI:
pkill -f "python3 main.py" ; cd /opt/ComfyUI && python3 main.py --listen 0.0.0.0 --port 8188 --base-directory /workspace
```

## Troubleshooting

- **Entrypoint logs** appear under **Connect → Logs** (container stdout).
- **Healthcheck**: the image has a `HEALTHCHECK` that GETs `127.0.0.1:8188` every 30s (with `start-period=600s` to cover the first boot). It shows up as `healthy` in `docker ps` once ComfyUI is up. RunPod does not use this to restart the pod — it's informational.
- **Broken DNS** (rare on RunPod): the entrypoint already forces 8.8.8.8 / 1.1.1.1 if it detects resolution failure.
- **Model not skipped even though it's already downloaded**: make sure the `filename` in the JSON matches exactly the file in `/workspace/models/<category>/`.
- **Civitai returns HTML instead of a `.safetensors`**: invalid / expired token, or the model requires additional login (early access). Check `CIVITAI_TOKEN`.
- **HF 401**: token without read permission on the gated repo. Accept the model's terms on HuggingFace first.
- **`xformers` warning in logs**: expected (see Build section above). It does not affect generation if you use sageattention in your nodes.
- **Out of memory / CUDA errors**: the base image is PyTorch 2.9 + CUDA 13, but this image overrides to torch 2.12 + cu130. The host driver must support CUDA 13 (RunPod handles that on Blackwell / Hopper pods).
- **Pod boots very fast without downloading anything**: the volume probably has an old `config.json` mounted. Edit `/workspace/config.json` via the Web Terminal and restart.

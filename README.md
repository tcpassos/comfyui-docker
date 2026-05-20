# ComfyUI cloud Docker image

Pre-baked Docker image to run ComfyUI on **RunPod** and **Vast.ai** with fast cold start.
Everything heavy ships in the image; what changes per workflow lives in `/workspace/config.json`.

## Layout

| Item | Location | Persistent? |
|---|---|---|
| ComfyUI, Python, torch, sage attention, ffmpeg | `/opt/ComfyUI` (in the image) | No (ships with the image) |
| Custom nodes | `/workspace/custom_nodes` | Yes (volume) |
| Models | `/workspace/models/<category>` | Yes (volume) |
| Workflows, outputs, ComfyUI configs | `/workspace/user`, `/workspace/output` | Yes (volume) |
| List of nodes + models to download | `/workspace/config.json` | Yes (volume) |

## Build

```powershell
docker build -t tcpassos/comfyui-cloud:latest C:\dev\comfyui-docker
docker push tcpassos/comfyui-cloud:latest
```

> Final size: ~16 GB. Build takes ~10–15 min on a good connection (the RunPod base image is already ~9 GB).

(Optional) Change ComfyUI version at build time:
```powershell
docker build --build-arg COMFYUI_VERSION=v0.22.0 -t tcpassos/comfyui-cloud:v0.22 C:\dev\comfyui-docker
```

### Validate the image locally (smoke test)

```powershell
docker run --rm --entrypoint python3 tcpassos/comfyui-cloud:latest -c "import torch, torchvision, torchaudio, xformers, sageattention; print('torch', torch.__version__, 'cuda', torch.version.cuda, 'tv', torchvision.__version__, 'ta', torchaudio.__version__, 'xf', xformers.__version__)"
```

Expected output:
```
torch 2.12.0+cu130 cuda 13.0 tv 0.27.0+cu130 ta 2.11.0+cu130 xf 0.0.35
```

> The `--entrypoint python3` flag is required; otherwise the image's ENTRYPOINT runs the full node/model provisioning before your command.

### About xformers

The image installs `xformers==0.0.35` but its official wheel was built against **torch 2.10/cu128/py3.10** while this image uses **torch 2.12/cu130/py3.12** — the module imports, but its CUDA extensions (memory-efficient attention, SwiGLU) stay disabled with a warning. Use **sageattention** as your main optimization path (installed and functional — pure Triton, no compiled extension).

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
| `CONFIG_URL` | **required** if `/workspace/config.json` does not yet exist in the volume. Public URL (Gist / raw GitHub) of a `config.json`. If missing and no config exists in the volume, the entrypoint aborts with a clear error (prevents accidental download of an unintended default set). |
| `UPDATE_NODES` | `false` (default) — does not update existing custom nodes on boot, keeping deploys reproducible. `true` runs `git pull --ff-only` on every node without a pinned `ref`. |
| `PORT` | `8188` (optional, default is 8188) |

### 2. Deploy the pod

Templates → your template → **Deploy**:

- **GPU**: RTX PRO 4500 Blackwell (or any GPU whose driver supports CUDA 12.x+; the image ships CUDA 13).
- **Volume**: ✅ enable to persist `/workspace` across stops.
- **Region**: any; prefer the same region where you already have a volume if reusing it.

Deploy → wait for "Running".

### 3. First boot

**Takes 5–15 min** because the entrypoint will:
1. Download `config.json` from `CONFIG_URL` to `/workspace/config.json` (if not set, **the pod aborts** — protection against accidental deploys without a defined config).
2. Clone the custom nodes listed in `nodes[]`.
3. `pip install` the requirements of each node.
4. Download the models listed in `models[]` (HF / Civitai using the tokens from the env vars).

Follow along in **Connect → Logs**. When you see `Starting ComfyUI on port 8188`, you're ready.

> Without `CONFIG_URL` set and without a pre-populated volume: the entrypoint prints instructions and exits with code 1. Check the logs and either (a) set `CONFIG_URL` on the template, or (b) SSH into the pod and `cp /opt/config.example.json /workspace/config.json` to use the embedded example set.

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
| `CONFIG_URL` | **required** — same as RunPod (public URL of a `config.json`) |
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

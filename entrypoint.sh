#!/bin/bash
# =============================================================================
#  Entrypoint for the comfyui-cloud image
#  - Ensures the expected structure under /workspace
#  - Reads /workspace/config.json (seeds from /opt/config.example.json if missing)
#  - Syncs custom_nodes and models
#  - Starts ComfyUI with --base-directory /workspace
# =============================================================================
set -uo pipefail

# ----- Mirror all output to a log file inside /workspace ---------------------
# Lets users tail logs via the File Browser (https://<host>:<port>/files/)
# without needing CLI/SSH access. Survives reboots in the persistent volume.
mkdir -p /workspace 2>/dev/null || true
exec > >(tee -a /workspace/comfyforge-boot.log) 2>&1

WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_HOME="${COMFYUI_HOME:-/opt/ComfyUI}"
CONFIG="${WORKSPACE}/config.json"
PORT="${COMFYUI_PORT:-8188}"
INTERNAL_PORT=8189  # ComfyUI listens here; nginx listens on $PORT and proxies

C_CYAN="\e[36m"; C_GREEN="\e[32m"; C_RED="\e[31m"; C_YELLOW="\e[33m"; C_RESET="\e[0m"
log()  { echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[-]${C_RESET} $*" >&2; }

# ----- Fix DNS if needed (RunPod sometimes ships with broken DNS) ------------
if ! getent hosts huggingface.co >/dev/null 2>&1; then
    warn "DNS cannot resolve huggingface.co — applying 8.8.8.8/1.1.1.1"
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
fi

# ----- SSH (Vast.ai compatibility) -------------------------------------------
# RunPod injects authorized_keys via its own template wrapper. Vast.ai expects
# the image to handle SSH itself: read PUBLIC_KEY / SSH_PUBLIC_KEY env, write
# authorized_keys, start sshd. Harmless on RunPod (the var is just empty).
SSH_KEY="${SSH_PUBLIC_KEY:-${PUBLIC_KEY:-}}"
if [[ -n "$SSH_KEY" ]]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    # Append only if not already present (avoid duplicates across reboots)
    grep -qxF "$SSH_KEY" /root/.ssh/authorized_keys 2>/dev/null \
        || echo "$SSH_KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    if command -v sshd >/dev/null 2>&1; then
        # /usr/sbin/sshd needs the host keys generated on first boot
        ssh-keygen -A >/dev/null 2>&1 || true
        /usr/sbin/sshd && ok "sshd running on :22"
    fi
fi

# ----- Vast.ai portal hint ---------------------------------------------------
# Vast.ai's "Instance Portal" UI reads PORTAL_CONFIG from the container env to
# render shortcut buttons. It must be set on the *template* (Vast passes it via
# docker run -e), not here — env vars set inside the container are not visible
# to Vast's portal. Print the recommended value so the user can copy/paste.
if [[ -z "${PORTAL_CONFIG:-}" ]]; then
    log "Vast.ai users: set this env var on your template for the portal UI:"
    log '  PORTAL_CONFIG="localhost:8188:18188:/:ComfyUI"'
fi

# ----- Pre-flight: check disk space ------------------------------------------
# Container disk: where pip installs custom-node deps (/usr/local/lib/...).
# Volume: where models and nodes live.
# Running out of space here = confusing failures later (sqlite, manager config,
# downloads).
check_disk() {
    local path="$1" label="$2" min_gb="$3"
    local avail_kb avail_gb
    avail_kb=$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$avail_kb" ]]; then
        warn "Could not check disk usage at $path"
        return
    fi
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( avail_gb < min_gb )); then
        err "========================================================="
        err " INSUFFICIENT DISK: ${label}"
        err " Available: ${avail_gb} GB  |  Minimum recommended: ${min_gb} GB"
        err " Path: $path"
        err ""
        if [[ "$label" == "Container Disk" ]]; then
            err " On RunPod, edit the template and increase 'Container Disk Size'."
            err " Custom nodes (Manager, FishSpeech, etc.) install lots of"
            err " Python dependencies into the container — 30 GB+ recommended."
        else
            err " On RunPod, attach a larger Network Volume (>= ${min_gb} GB)"
            err " at /workspace before starting the pod."
        fi
        err "========================================================="
        exit 1
    fi
    ok "${label}: ${avail_gb} GB free at $path"
}
check_disk "/"           "Container Disk" 15
check_disk "$WORKSPACE"  "Volume"         5

# ----- Pre-flight: GPU / driver compatibility --------------------------------
# Catches the most expensive failure mode: pod with NVIDIA driver too old for
# the image's CUDA runtime. Without this, the user discovers the mismatch only
# after ~40 min of model downloads, when ComfyUI fails to import torch.cuda.
# torch._C._cuda_init() is the exact call ComfyUI makes at startup, so if it
# succeeds here, it will succeed there too.
preflight_gpu() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        err "========================================================="
        err " nvidia-smi not found"
        err " This pod has no NVIDIA runtime. Pick a GPU pod and retry."
        err "========================================================="
        return 1
    fi
    local driver gpu
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    ok "GPU: ${gpu:-unknown} | driver: ${driver:-unknown}"

    if ! python3 -c "import torch; torch._C._cuda_init()" >/tmp/cuda-preflight.log 2>&1; then
        err "========================================================="
        err " CUDA INITIALIZATION FAILED"
        err " Image requires NVIDIA driver compatible with the CUDA"
        err " runtime baked into this PyTorch build."
        err " Detected driver: ${driver:-unknown}"
        err " Fix: on RunPod / Vast.ai, filter pods by a higher"
        err " 'CUDA Version' (e.g. >=13.0) and redeploy."
        err " ----- torch error -----"
        sed 's/^/   /' /tmp/cuda-preflight.log >&2
        err "========================================================="
        return 1
    fi
    ok "CUDA init OK"
}
if ! preflight_gpu; then
    err "Aborting before downloading models — refusing to burn pod time on a broken host."
    exit 1
fi

# ----- Volume structure ------------------------------------------------------
mkdir -p \
    "${WORKSPACE}/models" \
    "${WORKSPACE}/custom_nodes" \
    "${WORKSPACE}/user" \
    "${WORKSPACE}/user/default" \
    "${WORKSPACE}/input" \
    "${WORKSPACE}/output" \
    "${WORKSPACE}/temp"

# Provision config.json if it does not exist on the volume yet.
# Priority: CONFIG_URL (env) > /opt/config.example.json (bundled default).
# The example is a minimal config (just ComfyUI-Manager + ComfyUI-Lora-Manager,
# no models) — enough to land a working UI on first boot without forcing the
# user to provide a config upfront.
if [[ ! -f "$CONFIG" ]]; then
    if [[ -n "${CONFIG_URL:-}" ]]; then
        log "Downloading config from \$CONFIG_URL → $CONFIG"
        if ! curl --fail --location --retry 3 --retry-delay 5 -o "$CONFIG" "$CONFIG_URL"; then
            err "Failed to download CONFIG_URL: $CONFIG_URL"
            exit 1
        fi
    elif [[ -f /opt/config.example.json ]]; then
        log "No CONFIG_URL set and $CONFIG missing — seeding from bundled /opt/config.example.json"
        log "Edit $CONFIG and restart the pod to add your own nodes/models."
        cp /opt/config.example.json "$CONFIG"
    else
        err "Missing $CONFIG, CONFIG_URL not set, and no bundled example found."
        err "Set the CONFIG_URL env var or create $CONFIG manually and restart."
        exit 1
    fi
fi

# ----- Helpers ---------------------------------------------------------------
HF_TOKEN="${HF_TOKEN:-}"
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
UPDATE_NODES="${UPDATE_NODES:-false}"  # if true, git-pull existing nodes

# Prefer uv (Astral) for pip operations — ~10-30x faster than pip and
# resolves all requirements in a single pass. Falls back to pip if uv isn't
# installed (e.g. when entrypoint is run outside this image).
if command -v uv >/dev/null 2>&1; then
    PIP_INSTALL=(uv pip install --system)
else
    PIP_INSTALL=(pip install --upgrade-strategy only-if-needed)
fi

clone_node() {
    local url="$1" ref="${2:-}" path dir
    dir="${url##*/}"; dir="${dir%.git}"
    path="${WORKSPACE}/custom_nodes/${dir}"
    if [[ -d "$path/.git" ]]; then
        if [[ "$UPDATE_NODES" == "true" && -z "$ref" ]]; then
            log "Updating node: $dir"
            git -C "$path" pull --ff-only 2>/dev/null || warn "git pull failed for $dir"
        else
            ok "Node already present: $dir (skip)"
        fi
    else
        log "Cloning node: $dir${ref:+ @ $ref}"
        git clone --recursive "$url" "$path" || { warn "Clone failed: $url"; return; }
        if [[ -n "$ref" ]]; then
            git -C "$path" checkout "$ref" 2>/dev/null \
                || warn "checkout '$ref' failed for $dir (kept HEAD)"
        fi
    fi
    # NOTE: requirements.txt is NOT installed here. After all nodes are
    # processed, the main loop runs a single consolidated install — the
    # resolver runs once across every node's requirements instead of N times.
}

_download_curl() {
    local url="$1" dest_dir="$2" fname="$3" auth_header="$4"
    local args=(--fail --location --progress-bar --retry 3 --retry-delay 5 --continue-at -)
    [[ -n "$auth_header" ]] && args+=(-H "$auth_header")
    if ! curl "${args[@]}" -o "$dest_dir/$fname" "$url"; then
        local rc=$?
        warn "Failed: $url (curl exit ${rc})"
        [[ -f "$dest_dir/$fname" && ! -s "$dest_dir/$fname" ]] && rm -f "$dest_dir/$fname"
        if [[ $rc -eq 23 ]]; then
            err "curl 23 = write failure. Disk full?"
            df -h "$dest_dir" || true
        fi
        return $rc
    fi
}

download_model() {
    local url="$1" dest_dir="$2" fname="$3"
    mkdir -p "$dest_dir"

    if [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co.*/blob/ ]]; then
        url="${url/\/blob\//\/resolve\/}"
    fi

    if [[ -z "$fname" || "$fname" == "null" ]]; then
        fname="${url##*/}"; fname="${fname%%\?*}"
    fi

    if [[ -s "$dest_dir/$fname" ]]; then
        ok "Already present: $fname (skip)"
        return 0
    fi

    local auth_header=""
    if [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co ]]; then
        [[ -n "$HF_TOKEN" ]] && auth_header="Authorization: Bearer $HF_TOKEN"
    elif [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com ]]; then
        if [[ -n "$CIVITAI_TOKEN" ]]; then
            if [[ "$url" == *"?"* ]]; then url="${url}&token=$CIVITAI_TOKEN"
            else                            url="${url}?token=$CIVITAI_TOKEN"; fi
        fi
    fi

    # HuggingFace URLs: try huggingface_hub + hf_transfer first. Falls through
    # to aria2c/curl on any failure (network, parse, transfer crash).
    if [[ "$url" =~ ^https://huggingface\.co/(datasets/)?([^/]+/[^/]+)/resolve/([^/?#]+)/([^?#]+) ]]; then
        local hf_repo_prefix="${BASH_REMATCH[1]}"
        local hf_repo_id="${BASH_REMATCH[2]}"
        local hf_revision="${BASH_REMATCH[3]}"
        local hf_path_in_repo="${BASH_REMATCH[4]}"
        local hf_repo_type="model"
        [[ -n "$hf_repo_prefix" ]] && hf_repo_type="dataset"
        log "Downloading $fname (hf_transfer)"
        if _download_hf_transfer "$hf_repo_type" "$hf_repo_id" "$hf_revision" \
                                 "$hf_path_in_repo" "$dest_dir" "$fname"; then
            return 0
        fi
        warn "hf_transfer failed — retrying with aria2c"
    else
        log "Downloading $fname"
    fi

    # aria2c uses up to 16 parallel connections to a single file — typically
    # 4-16x faster than curl on multi-GB models from HF / Civitai CDNs.
    if command -v aria2c >/dev/null 2>&1; then
        local args=(
            --console-log-level=warn --summary-interval=10
            --max-tries=3 --retry-wait=5
            --max-connection-per-server=16 --split=16 --min-split-size=1M
            --auto-file-renaming=false --allow-overwrite=true
            --continue=true
            --dir="$dest_dir" --out="$fname"
        )
        [[ -n "$auth_header" ]] && args+=(--header="$auth_header")
        if aria2c "${args[@]}" "$url"; then
            return 0
        fi
        warn "aria2 failed — retrying with curl"
        [[ -f "$dest_dir/$fname" && ! -s "$dest_dir/$fname" ]] && rm -f "$dest_dir/$fname"
    fi
    _download_curl "$url" "$dest_dir" "$fname" "$auth_header"
}

# huggingface_hub.hf_hub_download with HF_HUB_ENABLE_HF_TRANSFER=1 uses the
# hf_transfer Rust binary for ranged parallel downloads (~2-3x aria2c on HF's
# CDN). The library always writes to {local_dir}/{path_in_repo} preserving
# subdirs, so we download to a temp dir and move the leaf file to {dest}/{fname}
# to keep the flat layout expected by ComfyUI's loaders.
_download_hf_transfer() {
    local repo_type="$1" repo_id="$2" revision="$3" path_in_repo="$4"
    local dest_dir="$5" fname="$6"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! HF_HUB_ENABLE_HF_TRANSFER=1 python3 - <<PY
import os, sys
from huggingface_hub import hf_hub_download
try:
    hf_hub_download(
        repo_id="$repo_id",
        filename="$path_in_repo",
        revision="$revision",
        repo_type="$repo_type",
        local_dir="$tmp_dir",
        token=os.environ.get("HF_TOKEN") or None,
    )
except Exception as e:
    print(f"hf_hub_download error: {e}", file=sys.stderr)
    sys.exit(1)
PY
    then
        rm -rf "$tmp_dir"
        return 1
    fi
    local downloaded="$tmp_dir/$path_in_repo"
    if [[ ! -s "$downloaded" ]]; then
        rm -rf "$tmp_dir"
        return 1
    fi
    mv "$downloaded" "$dest_dir/$fname"
    rm -rf "$tmp_dir"
    return 0
}

# ----- Process config.json ---------------------------------------------------
if [[ ! -f "$CONFIG" ]]; then
    err "Missing config.json — aborting"
    exit 1
fi

if ! jq empty "$CONFIG" 2>/dev/null; then
    err "config.json at $CONFIG is invalid JSON. Fix it and restart."
    jq . "$CONFIG" || true   # prints the jq error
    exit 1
fi

log "Reading $CONFIG"

# Custom nodes — accepts a string "url" OR an object {url, ref}
NUM_NODES=$(jq -r '.nodes | length // 0' "$CONFIG")
log "Configuring ${NUM_NODES} custom node(s)..."
for ((i=0; i<NUM_NODES; i++)); do
    type=$(jq -r ".nodes[$i] | type" "$CONFIG")
    if [[ "$type" == "string" ]]; then
        url=$(jq -r ".nodes[$i]" "$CONFIG")
        clone_node "$url"
    else
        url=$(jq -r ".nodes[$i].url"       "$CONFIG")
        ref=$(jq -r ".nodes[$i].ref // empty" "$CONFIG")
        clone_node "$url" "$ref"
    fi
done

# Consolidated dependency install — passing all requirements.txt files to a
# single resolver invocation is dramatically faster than installing per-node,
# since pip/uv resolves shared dependencies (torch, numpy, transformers, ...)
# only once instead of N times.
REQ_ARGS=()
REQ_COUNT=0
for req in "${WORKSPACE}/custom_nodes/"*/requirements.txt; do
    [[ -f "$req" ]] || continue
    REQ_ARGS+=(-r "$req")
    REQ_COUNT=$((REQ_COUNT + 1))
done
if (( REQ_COUNT > 0 )); then
    log "Installing custom-node dependencies (${REQ_COUNT} requirements files, single pass via ${PIP_INSTALL[0]})"
    "${PIP_INSTALL[@]}" "${REQ_ARGS[@]}" \
        || warn "Some custom-node dependencies failed to install (see log above)"
fi

# Models (array of objects {category|path, url, filename?})
# - `path` (optional): destination override, relative to $WORKSPACE (or absolute).
# - `category` (fallback): destination = models/<category>/.
NUM_MODELS=$(jq -r '.models | length // 0' "$CONFIG")
log "Configuring ${NUM_MODELS} model(s)..."
for ((i=0; i<NUM_MODELS; i++)); do
    cat=$(jq -r ".models[$i].category // empty" "$CONFIG")
    p=$(jq  -r ".models[$i].path     // empty" "$CONFIG")
    url=$(jq -r ".models[$i].url"               "$CONFIG")
    fn=$(jq  -r ".models[$i].filename // empty" "$CONFIG")

    if [[ -n "$p" ]]; then
        if [[ "$p" == /* ]]; then dest="$p"; else dest="${WORKSPACE}/${p}"; fi
    elif [[ -n "$cat" ]]; then
        dest="${WORKSPACE}/models/${cat}"
    else
        warn "models[$i] has neither 'path' nor 'category' — skipping"; continue
    fi
    download_model "$url" "$dest" "$fn"
done

# Workflows (array of objects {url, filename?}) → /workspace/user/default/workflows/
NUM_WF=$(jq -r '.workflows | length // 0' "$CONFIG")
if (( NUM_WF > 0 )); then
    log "Configuring ${NUM_WF} workflow(s)..."
    WF_DIR="${WORKSPACE}/user/default/workflows"
    mkdir -p "$WF_DIR"
    for ((i=0; i<NUM_WF; i++)); do
        url=$(jq -r ".workflows[$i].url"               "$CONFIG")
        fn=$(jq  -r ".workflows[$i].filename // empty" "$CONFIG")
        download_model "$url" "$WF_DIR" "$fn"
    done
fi

# ----- Sage Attention build (runtime, GPU-arch specific) ---------------------
# Sage 2.x must match the target GPU's compute capability
# (Blackwell sm_120, Ada sm_89, Hopper sm_90, Ampere sm_86, ...). The base
# image is the `-runtime` PyTorch tag (no nvcc), so building from source isn't
# available by default.
#
# Install order (first that works wins):
#   1. Cached wheel at $WORKSPACE/cache/sage_wheels/ (from a previous boot).
#   2. Prebuilt wheel from $SAGE_PREBUILT_REPO (default
#      tcpassos/sage-wheels-linux) matching torch/cuda/python/SM of the
#      running container. Disable with SAGE_PREBUILT=false.
#   3. Compile from source — ONLY if nvcc is present (i.e. image was rebuilt
#      from a -devel base). Result is cached for future boots.
#   4. Fall back to PyPI sageattention (Sage 1.x, missing per_warp_int8_cuda).
if [[ "${INSTALL_SAGE:-true}" == "true" ]]; then
    # Sage 2.x exposes per_warp_int8_cuda (KJNodes LTX2 patch uses it).
    # The PyPI 1.0.6 fallback does NOT export it, so this check distinguishes.
    if python3 -c "from sageattention import per_warp_int8_cuda" 2>/dev/null; then
        ok "Sage 2.x already installed"
    else
        ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
        if [[ -z "$ARCH" ]]; then
            warn "nvidia-smi did not return a compute capability — skipping Sage build"
        else
            SM="${ARCH//./}"
            CACHE_DIR="${WORKSPACE}/cache/sage_wheels"
            mkdir -p "$CACHE_DIR"
            # The PEP 427 build tag in the wheel filename already encodes the SM
            # (sageattention-<ver>-<SM>-cp<py>-cp<py>-linux_x86_64.whl).
            CACHED=$(ls "${CACHE_DIR}"/sageattention-*-${SM}-cp${PY_DIGITS:-*}-cp${PY_DIGITS:-*}-*.whl 2>/dev/null | head -1)
            if [[ -n "$CACHED" && -f "$CACHED" ]]; then
                log "Installing cached Sage wheel for sm_${SM}: $(basename "$CACHED")"
                pip install --no-deps --force-reinstall "$CACHED" \
                    && ok "Sage installed from cache" \
                    || warn "Cached wheel install failed"
            else
                # ---------- Try a prebuilt wheel from GitHub releases --------
                # Repo layout: each release tag encodes the runtime that the
                # wheels target, e.g.
                #   sage-2.2.0-torch-2.12.0-cu130-py312
                # and the assets are
                #   sageattention-<ver>-<SM>-cp<py>-cp<py>-linux_x86_64.whl
                # We pick the newest release whose tag matches the current
                # torch/cuda/python combo and that ships a wheel for this SM.
                SAGE_PREBUILT_REPO="${SAGE_PREBUILT_REPO:-tcpassos/sage-wheels-linux}"
                INSTALLED_FROM_PREBUILT=false
                if [[ "${SAGE_PREBUILT:-true}" == "true" ]]; then
                    TORCH_VER=$(python3 -c 'import torch; print(torch.__version__.split("+")[0])' 2>/dev/null || true)
                    CUDA_RAW=$(python3 -c 'import torch; print((torch.version.cuda or "").replace(".",""))' 2>/dev/null || true)
                    PY_DIGITS=$(python3 -c 'import sys; print(f"{sys.version_info.major}{sys.version_info.minor}")' 2>/dev/null || true)
                    if [[ -n "$TORCH_VER" && -n "$CUDA_RAW" && -n "$PY_DIGITS" ]]; then
                        TAG_SUFFIX="torch-${TORCH_VER}-cu${CUDA_RAW}-py${PY_DIGITS}"
                        log "Looking for prebuilt Sage wheel: ${SAGE_PREBUILT_REPO} matching ${TAG_SUFFIX}, sm_${SM}"
                        # Plain GitHub REST works unauthenticated for public repos.
                        # GH_TOKEN raises the rate limit (60 → 5000/h) when set.
                        api_headers=(-H "Accept: application/vnd.github+json")
                        [[ -n "${GH_TOKEN:-}" ]] && api_headers+=(-H "Authorization: Bearer $GH_TOKEN")
                        releases_json=$(curl -fsSL "${api_headers[@]}" \
                            "https://api.github.com/repos/${SAGE_PREBUILT_REPO}/releases?per_page=50" 2>/dev/null || echo "")
                        if [[ -n "$releases_json" ]]; then
                            # Walk releases newest-first, pick first asset whose
                            # name matches sageattention-*-${SM}-cp${PY_DIGITS}-*.whl
                            # inside a release tagged with $TAG_SUFFIX.
                            asset_url=$(echo "$releases_json" | jq -r --arg suf "$TAG_SUFFIX" \
                                --arg sm  "$SM" --arg py "$PY_DIGITS" '
                                map(select(.tag_name | contains($suf)))
                                | .[].assets[]?
                                | select(.name | test("sageattention-[^-]+-\($sm)-cp\($py)-"))
                                | .browser_download_url' 2>/dev/null | head -1)
                            asset_name=$(echo "$releases_json" | jq -r --arg suf "$TAG_SUFFIX" \
                                --arg sm  "$SM" --arg py "$PY_DIGITS" '
                                map(select(.tag_name | contains($suf)))
                                | .[].assets[]?
                                | select(.name | test("sageattention-[^-]+-\($sm)-cp\($py)-"))
                                | .name' 2>/dev/null | head -1)
                            if [[ -n "$asset_url" && -n "$asset_name" ]]; then
                                log "Found prebuilt: $asset_name → downloading"
                                DL_PATH="${CACHE_DIR}/${asset_name}"
                                if curl -fsSL --retry 3 --retry-delay 5 \
                                        "${api_headers[@]}" \
                                        -o "$DL_PATH" "$asset_url"; then
                                    if pip install --no-deps --force-reinstall "$DL_PATH"; then
                                        ok "Sage installed from prebuilt release"
                                        INSTALLED_FROM_PREBUILT=true
                                    else
                                        warn "Prebuilt wheel install failed — will fall back to build"
                                        rm -f "$DL_PATH"
                                    fi
                                else
                                    warn "Prebuilt wheel download failed — will fall back to build"
                                fi
                            else
                                log "No prebuilt wheel for ${TAG_SUFFIX} / sm_${SM} — falling back to build"
                            fi
                        else
                            warn "Could not query ${SAGE_PREBUILT_REPO} releases — falling back to build"
                        fi
                    else
                        warn "Could not detect torch/cuda/py — falling back to build"
                    fi
                fi
                # ---------- Build from source (fallback) ---------------------
                if [[ "$INSTALLED_FROM_PREBUILT" != "true" ]]; then
                    if ! command -v nvcc >/dev/null 2>&1; then
                        warn "nvcc not found in this image (runtime base) — cannot build Sage from source"
                        warn "No prebuilt wheel matched torch=${TORCH_VER:-?} cuda=cu${CUDA_RAW:-?} py=${PY_DIGITS:-?} sm_${SM}."
                        warn "Options: (a) add a release at ${SAGE_PREBUILT_REPO} that ships this combo,"
                        warn "         (b) rebuild this image FROM a -devel base (pytorch/pytorch:*-devel)."
                        warn "Falling back to PyPI sageattention (Sage 1.x — lacks per_warp_int8_cuda)"
                        ${PIP_INSTALL[@]} sageattention || warn "PyPI fallback also failed"
                    else
                        log "Building Sage 2.x for sm_${SM} (compute cap $ARCH) — ~5 min, ~6 GB RAM"
                        pip uninstall -y sageattention 2>/dev/null || true
                        BUILD_TMP=$(mktemp -d)
                        if TORCH_CUDA_ARCH_LIST="$ARCH" \
                           MAX_JOBS="${SAGE_BUILD_JOBS:-4}" \
                           pip wheel --no-build-isolation --no-deps \
                               -w "$BUILD_TMP" \
                               git+https://github.com/thu-ml/SageAttention.git; then
                            BUILT=$(ls "$BUILD_TMP"/sageattention-*.whl 2>/dev/null | head -1)
                            if [[ -n "$BUILT" ]]; then
                                # Inject the SM as PEP 427 build tag so multiple
                                # GPU archs can coexist in the cache without
                                # clobbering each other. setup.py emits a plain
                                # sageattention-<ver>-cp<py>-cp<py>-<plat>.whl
                                # without a build tag; we splice -${SM}- in.
                                BASE=$(basename "$BUILT")
                                TAGGED="${BASE/-cp/-${SM}-cp}"
                                cp "$BUILT" "${CACHE_DIR}/${TAGGED}"
                                pip install --no-deps "${CACHE_DIR}/${TAGGED}" \
                                    && ok "Sage 2.x compiled, cached and installed for sm_${SM}"
                            else
                                warn "Build succeeded but no wheel found in $BUILD_TMP"
                            fi
                        else
                            warn "Sage 2.x build failed — falling back to PyPI sageattention"
                            pip install sageattention || warn "PyPI fallback also failed"
                        fi
                        rm -rf "$BUILD_TMP"
                    fi
                fi
            fi
        fi
    fi
fi

# ----- Start ComfyUI first (in background) -----------------------------------
# We start ComfyUI before nginx to avoid a 502 Bad Gateway window during
# custom-node loading (which can take 15-30s).
ok "Starting ComfyUI on 127.0.0.1:${INTERNAL_PORT}"
cd "$COMFYUI_HOME"
# Vast.ai/RunPod containers default to RLIMIT_MEMLOCK=8MB and don't grant
# IPC_LOCK, so we can't raise it from inside. ComfyUI's "smart memory" mode
# tries to pin near-all-host-RAM (it reads /proc/meminfo, not the cgroup),
# then mlock() fails mid-generation (typically at RIFE/IFNet frame
# interpolation) and the kernel kills the process. --disable-smart-memory
# falls back to load/unload of models per step and avoids the pinned path.
# Try to raise memlock first (works on hosts with IPC_LOCK granted, no-op
# otherwise — never fatal).
ulimit -l unlimited 2>/dev/null || true
python3 main.py \
    --listen 127.0.0.1 \
    --port "$INTERNAL_PORT" \
    --base-directory "$WORKSPACE" \
    --enable-cors-header \
    --disable-smart-memory \
    "$@" &
COMFY_PID=$!

# Bring nginx down with us if ComfyUI dies
trap 'kill -TERM $COMFY_PID 2>/dev/null; nginx -s quit 2>/dev/null; exit' INT TERM

# Wait for ComfyUI to bind the internal port (5 min timeout)
log "Waiting for ComfyUI to bind 127.0.0.1:${INTERNAL_PORT}..."
for i in $(seq 1 150); do
    if ! kill -0 $COMFY_PID 2>/dev/null; then
        err "ComfyUI died during boot. See the log above."
        exit 1
    fi
    if curl -fsS "http://127.0.0.1:${INTERNAL_PORT}/" -o /dev/null 2>/dev/null; then
        ok "ComfyUI responding on 127.0.0.1:${INTERNAL_PORT}"
        break
    fi
    sleep 2
    if (( i == 150 )); then
        warn "ComfyUI did not respond in 5 min — starting nginx anyway"
    fi
done

# ----- Start nginx (proxy with WebSocket support) ----------------------------
sed -i "s/listen 8188;/listen ${PORT};/" /etc/nginx/conf.d/comfyui.conf
nginx -t || { err "nginx config test failed"; exit 1; }
nginx
# Verify nginx actually bound the public port (the base image ships its own
# nginx.conf — if conf.d include is missing our server block is silently dropped)
for i in {1..10}; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null; then
        ok "nginx running on port ${PORT} → proxy to 127.0.0.1:${INTERNAL_PORT}"
        break
    fi
    if (( i == 10 )); then
        warn "nginx is NOT responding on port ${PORT} after 10s"
        warn "Active nginx listeners:"
        nginx -T 2>/dev/null | grep -E "^\s*listen" || true
        err "nginx failed to bind ${PORT} — check /etc/nginx/nginx.conf includes conf.d/*.conf"
        exit 1
    fi
    sleep 1
done

# Keep the container alive while ComfyUI runs
wait $COMFY_PID

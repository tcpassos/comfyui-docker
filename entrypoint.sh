#!/bin/bash
# =============================================================================
#  Entrypoint for the comfyui-cloud image
#  - Ensures the expected structure under /workspace
#  - Reads /workspace/config.json (fails fast if missing)
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
# Priority: CONFIG_URL (env) > error (fail-fast, avoids downloading an
# unwanted default set).
if [[ ! -f "$CONFIG" ]]; then
    if [[ -n "${CONFIG_URL:-}" ]]; then
        log "Downloading config from \$CONFIG_URL → $CONFIG"
        if ! curl --fail --location --retry 3 --retry-delay 5 -o "$CONFIG" "$CONFIG_URL"; then
            err "Failed to download CONFIG_URL: $CONFIG_URL"
            exit 1
        fi
    else
        err "Missing $CONFIG and CONFIG_URL is not set."
        err "Set the CONFIG_URL env var (raw URL of a config.json) OR"
        err "create $CONFIG manually (e.g. cp /opt/config.example.json $CONFIG) and restart."
        exit 1
    fi
fi

# ----- Helpers ---------------------------------------------------------------
HF_TOKEN="${HF_TOKEN:-}"
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
UPDATE_NODES="${UPDATE_NODES:-false}"  # if true, git-pull existing nodes

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
    if [[ -f "$path/requirements.txt" ]]; then
        pip install --upgrade-strategy only-if-needed -r "$path/requirements.txt" \
            || warn "requirements for $dir failed"
    fi
}

download_model() {
    local url="$1" dest_dir="$2" fname="$3"
    mkdir -p "$dest_dir"

    if [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co.*/blob/ ]]; then
        url="${url/\/blob\//\/resolve\/}"
    fi

    # Resolve filename if not provided
    if [[ -z "$fname" || "$fname" == "null" ]]; then
        fname="${url##*/}"; fname="${fname%%\?*}"
    fi

    if [[ -s "$dest_dir/$fname" ]]; then
        ok "Already present: $fname (skip)"
        return 0
    fi

    local args=(--fail --location --progress-bar --retry 3 --retry-delay 5 --continue-at -)
    if [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co ]]; then
        [[ -n "$HF_TOKEN" ]] && args+=(-H "Authorization: Bearer $HF_TOKEN")
    elif [[ "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com ]]; then
        if [[ -n "$CIVITAI_TOKEN" ]]; then
            if [[ "$url" == *"?"* ]]; then url="${url}&token=$CIVITAI_TOKEN"
            else                            url="${url}?token=$CIVITAI_TOKEN"; fi
        fi
    fi

    log "Downloading $fname"
    if ! curl "${args[@]}" -o "$dest_dir/$fname" "$url"; then
        local rc=$?
        warn "Failed: $url (curl exit ${rc})"
        # Remove partial/zero-byte file so the next boot retries cleanly
        [[ -f "$dest_dir/$fname" && ! -s "$dest_dir/$fname" ]] && rm -f "$dest_dir/$fname"
        # curl 23 = write error (usually disk full)
        if [[ $rc -eq 23 ]]; then
            err "curl 23 = write failure. Disk full?"
            df -h "$dest_dir" || true
        fi
    fi
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
# Sage 2.x must be built from source for the target GPU's compute capability
# (Blackwell sm_120, Ada sm_89, Hopper sm_90, Ampere sm_86). Building all
# archs at image-build time peaks ~22 GB RAM (the _fused.so link step), which
# OOMs Docker Desktop. Compiling only the device's arch at runtime keeps RAM
# under ~6 GB and finishes in ~5 min on a modern GPU.
#
# The wheel is cached at $WORKSPACE/cache/sage_wheels/ so subsequent boots of
# the same instance type (same GPU arch) skip the rebuild and just pip install.
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
            CACHED=$(ls "${CACHE_DIR}"/sageattention-*-sm${SM}.whl 2>/dev/null | head -1)
            if [[ -n "$CACHED" && -f "$CACHED" ]]; then
                log "Installing cached Sage wheel for sm_${SM}: $(basename "$CACHED")"
                pip install --no-deps --force-reinstall "$CACHED" \
                    && ok "Sage installed from cache" \
                    || warn "Cached wheel install failed"
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
                        NAME=$(basename "$BUILT" .whl)
                        cp "$BUILT" "${CACHE_DIR}/${NAME}-sm${SM}.whl"
                        pip install --no-deps "$BUILT" \
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

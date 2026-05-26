#!/bin/bash
# =============================================================================
#  comfy-provision — populate a target directory from a config.json
#  - Used at runtime by entrypoint.sh (TARGET=/workspace, default)
#  - Used at build time by ComfyForge-generated Dockerfile.bake (TARGET=/opt/preinstalled)
#  Idempotent: skips clones that already have .git and downloads whose file
#  already exists and is non-empty.
#
#  Env:
#    CONFIG               Path to config.json (required)
#    PROVISION_TARGET     Destination root (default /workspace)
#    HF_TOKEN             HuggingFace token (optional)
#    CIVITAI_TOKEN        Civitai token (optional)
#    UPDATE_NODES         If "true", git-pull existing nodes (default false)
# =============================================================================
set -uo pipefail

CONFIG="${CONFIG:?CONFIG env var is required (path to config.json)}"
TARGET="${PROVISION_TARGET:-/workspace}"
HF_TOKEN="${HF_TOKEN:-}"
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
UPDATE_NODES="${UPDATE_NODES:-false}"

C_CYAN="\e[36m"; C_GREEN="\e[32m"; C_RED="\e[31m"; C_YELLOW="\e[33m"; C_RESET="\e[0m"
log()  { echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[-]${C_RESET} $*" >&2; }

if [[ ! -f "$CONFIG" ]]; then
    err "Missing config.json at $CONFIG"
    exit 1
fi
if ! jq empty "$CONFIG" 2>/dev/null; then
    err "config.json at $CONFIG is invalid JSON. Fix it and retry."
    jq . "$CONFIG" || true
    exit 1
fi

# schemaVersion check — absent = legacy v1 (silent), unknown future = warn but proceed.
CFG_SCHEMA=$(jq -r '.schemaVersion // 1' "$CONFIG" 2>/dev/null || echo 1)
if [[ "$CFG_SCHEMA" != "1" ]]; then
    warn "config schemaVersion=$CFG_SCHEMA is newer than this provision script (supported: 1). Trying anyway."
fi

mkdir -p "${TARGET}/custom_nodes" "${TARGET}/models" "${TARGET}/user/default/workflows"

# Prefer uv (Astral) for pip operations — ~10-30x faster than pip and
# resolves all requirements in a single pass. Falls back to pip if uv isn't
# installed.
if command -v uv >/dev/null 2>&1; then
    PIP_INSTALL=(uv pip install --system)
else
    PIP_INSTALL=(pip install --upgrade-strategy only-if-needed)
fi

clone_node() {
    local url="$1" ref="${2:-}" path dir
    dir="${url##*/}"; dir="${dir%.git}"
    path="${TARGET}/custom_nodes/${dir}"
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

# huggingface_hub.hf_hub_download with HF_XET_HIGH_PERFORMANCE=1 uses hf-xet
# (bundled in huggingface_hub 1.x) for high-performance parallel downloads.
# The library always writes to {local_dir}/{path_in_repo} preserving subdirs,
# so we download to a temp dir and move the leaf file to {dest}/{fname} to keep
# the flat layout expected by ComfyUI's loaders.
_download_hf_xet() {
    local repo_type="$1" repo_id="$2" revision="$3" path_in_repo="$4"
    local dest_dir="$5" fname="$6"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! HF_XET_HIGH_PERFORMANCE=1 python3 - <<PY
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

    # HuggingFace URLs: try huggingface_hub + hf-xet first.
    # Falls through to aria2c/curl on any failure.
    if [[ "$url" =~ ^https://huggingface\.co/(datasets/)?([^/]+/[^/]+)/resolve/([^/?#]+)/([^?#]+) ]]; then
        local hf_repo_prefix="${BASH_REMATCH[1]}"
        local hf_repo_id="${BASH_REMATCH[2]}"
        local hf_revision="${BASH_REMATCH[3]}"
        local hf_path_in_repo="${BASH_REMATCH[4]}"
        local hf_repo_type="model"
        [[ -n "$hf_repo_prefix" ]] && hf_repo_type="dataset"
        log "Downloading $fname (hf_xet)"
        if _download_hf_xet "$hf_repo_type" "$hf_repo_id" "$hf_revision" \
                            "$hf_path_in_repo" "$dest_dir" "$fname"; then
            return 0
        fi
        warn "hf_xet failed — retrying with aria2c"
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
            --file-allocation=none
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

# ----- Process config.json ---------------------------------------------------
log "Provisioning from $CONFIG → $TARGET"

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
# single resolver invocation is dramatically faster than installing per-node.
REQ_ARGS=()
REQ_COUNT=0
for req in "${TARGET}/custom_nodes/"*/requirements.txt; do
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
NUM_MODELS=$(jq -r '.models | length // 0' "$CONFIG")
log "Configuring ${NUM_MODELS} model(s)..."
for ((i=0; i<NUM_MODELS; i++)); do
    cat=$(jq -r ".models[$i].category // empty" "$CONFIG")
    p=$(jq  -r ".models[$i].path     // empty" "$CONFIG")
    url=$(jq -r ".models[$i].url"               "$CONFIG")
    fn=$(jq  -r ".models[$i].filename // empty" "$CONFIG")

    if [[ -n "$p" ]]; then
        if [[ "$p" == /* ]]; then dest="$p"; else dest="${TARGET}/${p}"; fi
    elif [[ -n "$cat" ]]; then
        dest="${TARGET}/models/${cat}"
    else
        warn "models[$i] has neither 'path' nor 'category' — skipping"; continue
    fi
    download_model "$url" "$dest" "$fn"
done

# Workflows (array of objects {url, filename?}) → $TARGET/user/default/workflows/
NUM_WF=$(jq -r '.workflows | length // 0' "$CONFIG")
if (( NUM_WF > 0 )); then
    log "Configuring ${NUM_WF} workflow(s)..."
    WF_DIR="${TARGET}/user/default/workflows"
    mkdir -p "$WF_DIR"
    for ((i=0; i<NUM_WF; i++)); do
        url=$(jq -r ".workflows[$i].url"               "$CONFIG")
        fn=$(jq  -r ".workflows[$i].filename // empty" "$CONFIG")
        download_model "$url" "$WF_DIR" "$fn"
    done
fi

ok "Provisioning complete."

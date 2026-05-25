#!/bin/bash
# =============================================================================
#  comfy-merge-preinstalled — copy baked content from /opt/preinstalled to /workspace
#
#  Strategy: cp -rn (recursive, no-clobber). User content always wins.
#  Mental model: /opt/preinstalled is the "template" of the baked image.
#  On first boot it's copied into /workspace. After that, /workspace is yours.
#  Delete a file there and restart to re-seed it from the template.
#
#  No-op if /opt/preinstalled does not exist (running an un-baked image).
#
#  Env:
#    PREINSTALLED_DIR     Source root (default /opt/preinstalled)
#    WORKSPACE            Destination root (default /workspace)
# =============================================================================
set -uo pipefail

SRC="${PREINSTALLED_DIR:-/opt/preinstalled}"
DST="${WORKSPACE:-/workspace}"

C_CYAN="\e[36m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_RESET="\e[0m"
log()  { echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }

if [[ ! -d "$SRC" ]]; then
    # Not a baked image — nothing to merge. Silent no-op.
    exit 0
fi

if [[ -f "$SRC/.manifest.json" ]] && command -v jq >/dev/null 2>&1; then
    sha=$(jq -r '.config_sha12 // .config_sha256 // "unknown"' "$SRC/.manifest.json" 2>/dev/null)
    nodes=$(jq -r '.counts.nodes // 0' "$SRC/.manifest.json" 2>/dev/null)
    models=$(jq -r '.counts.models // 0' "$SRC/.manifest.json" 2>/dev/null)
    workflows=$(jq -r '.counts.workflows // 0' "$SRC/.manifest.json" 2>/dev/null)
    log "Merging preinstalled content (config: $sha, $nodes nodes, $models models, $workflows workflows)"
else
    log "Merging preinstalled content from $SRC → $DST"
fi

mkdir -p "$DST"

# Copy each top-level subdirectory (custom_nodes, models, user, ...)
# `cp -rn` = recursive, no-clobber. User-modified files are preserved.
# Skip the manifest itself (stays at /opt/preinstalled for diagnostics).
shopt -s nullglob
for entry in "$SRC"/*; do
    name=$(basename "$entry")
    [[ "$name" == ".manifest.json" ]] && continue
    cp -rn "$entry" "$DST/" 2>/dev/null || warn "Some files in $name were not copied (already present?)"
done
shopt -u nullglob

ok "Merge complete."

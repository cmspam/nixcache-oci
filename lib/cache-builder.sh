#!/usr/bin/env bash
# cache-builder.sh — Build, filter, and upload a Nix binary cache to GHCR (OCI).
#
# Design:
#   - Each locally-built NAR is pushed as an OCI blob to ghcr.io
#   - Each store path gets a tagged OCI manifest containing:
#       - The narinfo as an annotation
#       - A single layer pointing to the NAR blob
#   - A "cache-index" tag holds a JSON manifest mapping all store hashes
#   - Upstream-available paths are NOT uploaded
set -euo pipefail

: "${NIXCACHE_REPO:=cmspam/nixcache-oci}"
: "${NIXCACHE_REGISTRY:=ghcr.io}"
: "${NIXCACHE_SIGNING_KEY_FILE:=}"
: "${NIXCACHE_WORK_DIR:=$(mktemp -d)}"
: "${NIXCACHE_CONFIG_DIR:=config}"
: "${NIXCACHE_UPSTREAM_CACHES:=https://cache.nixos.org}"
: "${NIXCACHE_IMAGE:=${NIXCACHE_REGISTRY}/${NIXCACHE_REPO}/nix-cache}"

CACHE_DIR="${NIXCACHE_WORK_DIR}/cache"

info() { echo ">>> $*" >&2; }
err()  { echo "!!! $*" >&2; }

# ── OCI registry helpers ──────────────────────────────────────────────

# Get a GHCR auth token via OCI token exchange
oci_token=""
oci_get_token() {
    if [[ -n "$oci_token" ]]; then return; fi

    local cred_token
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        cred_token="$GITHUB_TOKEN"
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        cred_token="$GH_TOKEN"
    else
        cred_token=$(gh auth token 2>/dev/null) || true
    fi
    if [[ -z "$cred_token" ]]; then
        err "No authentication token available for GHCR"
        return 1
    fi

    # Exchange credentials for an OCI registry token
    local scope="repository:${NIXCACHE_REPO}/nix-cache:pull,push"
    local token_response
    token_response=$(curl -s -u "token:${cred_token}" \
        "https://${NIXCACHE_REGISTRY}/token?scope=${scope}&service=${NIXCACHE_REGISTRY}" 2>/dev/null)
    oci_token=$(echo "$token_response" | jq -r '.token // empty' 2>/dev/null)

    if [[ -z "$oci_token" ]]; then
        # Fallback: try using the credential directly (some registries accept this)
        oci_token="$cred_token"
    fi
}

# Push a blob to the OCI registry, returns the digest
# oci_push_blob <file>
oci_push_blob() {
    local file="$1"
    oci_get_token

    local digest
    digest="sha256:$(sha256sum "$file" | cut -d' ' -f1)"
    local size
    size=$(stat -c%s "$file")

    # Check if blob already exists
    local check_code
    check_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $oci_token" \
        "https://${NIXCACHE_REGISTRY}/v2/${NIXCACHE_REPO}/nix-cache/blobs/$digest" 2>/dev/null)
    if [[ "$check_code" == "200" ]]; then
        echo "$digest"
        return 0
    fi

    # Initiate upload
    local upload_headers
    upload_headers=$(mktemp)
    curl -s -D "$upload_headers" -o /dev/null \
        -X POST \
        -H "Authorization: Bearer $oci_token" \
        "https://${NIXCACHE_REGISTRY}/v2/${NIXCACHE_REPO}/nix-cache/blobs/uploads/" 2>/dev/null

    local upload_url
    upload_url=$(grep -i '^location:' "$upload_headers" | tr -d '\r' | sed 's/^[Ll]ocation: *//')
    local upload_status
    upload_status=$(head -1 "$upload_headers" | grep -o '[0-9][0-9][0-9]')
    rm -f "$upload_headers"

    if [[ -z "$upload_url" ]]; then
        err "Failed to initiate blob upload (HTTP $upload_status)"
        return 1
    fi

    # Make URL absolute if relative
    if [[ "$upload_url" == /* ]]; then
        upload_url="https://${NIXCACHE_REGISTRY}${upload_url}"
    fi

    # Upload blob in single PUT
    local sep="?"
    [[ "$upload_url" == *"?"* ]] && sep="&"
    local put_code
    put_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer $oci_token" \
        -H "Content-Type: application/octet-stream" \
        -H "Content-Length: $size" \
        --data-binary "@$file" \
        "${upload_url}${sep}digest=${digest}" 2>/dev/null)

    if [[ "$put_code" != "201" && "$put_code" != "202" ]]; then
        err "Blob upload failed with HTTP $put_code"
        return 1
    fi

    echo "$digest"
}

# Push an OCI manifest and tag it
# oci_push_manifest <tag> <manifest_json>
oci_push_manifest() {
    local tag="$1"
    local manifest="$2"
    oci_get_token

    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer $oci_token" \
        -H "Content-Type: application/vnd.oci.image.manifest.v1+json" \
        -d "$manifest" \
        "https://${NIXCACHE_REGISTRY}/v2/${NIXCACHE_REPO}/nix-cache/manifests/${tag}" 2>/dev/null)

    if [[ "$code" != "201" && "$code" != "200" ]]; then
        err "Manifest push failed for tag $tag with HTTP $code"
        return 1
    fi
}

# Fetch a manifest by tag, returns empty string on 404
oci_get_manifest() {
    local tag="$1"
    oci_get_token

    curl -s -f \
        -H "Authorization: Bearer $oci_token" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "https://${NIXCACHE_REGISTRY}/v2/${NIXCACHE_REPO}/nix-cache/manifests/${tag}" 2>/dev/null || true
}

# Fetch a blob by digest
oci_get_blob() {
    local digest="$1"
    oci_get_token

    curl -s -f -L \
        -H "Authorization: Bearer $oci_token" \
        "https://${NIXCACHE_REGISTRY}/v2/${NIXCACHE_REPO}/nix-cache/blobs/${digest}" 2>/dev/null
}

# ── Nix helpers ───────────────────────────────────────────────────────

discover_outputs() {
    local flake_dir="$1"
    local system
    system=$(nix eval --raw --impure --expr 'builtins.currentSystem')
    info "Discovering flake outputs for $system in $flake_dir"

    local flake_ref="path:$(realpath "$flake_dir")"

    if [[ ! -f "$flake_dir/flake.lock" ]]; then
        info "Generating flake.lock for $flake_dir"
        nix flake update --flake "$flake_ref" 1>&2
    fi

    local refs=()

    local pkg_names
    pkg_names=$(nix eval "$flake_ref#packages.${system}" --apply 'attrs: builtins.concatStringsSep "\n" (builtins.attrNames attrs)' --raw 2>/dev/null) || true
    if [[ -n "$pkg_names" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && refs+=("${flake_ref}#packages.${system}.${name}")
        done <<< "$pkg_names"
    fi

    local nixos_names
    nixos_names=$(nix eval "$flake_ref#nixosConfigurations" --apply 'attrs: builtins.concatStringsSep "\n" (builtins.attrNames attrs)' --raw 2>/dev/null) || true
    if [[ -n "$nixos_names" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && refs+=("${flake_ref}#nixosConfigurations.${name}.config.system.build.toplevel")
        done <<< "$nixos_names"
    fi

    local shell_names
    shell_names=$(nix eval "$flake_ref#devShells.${system}" --apply 'attrs: builtins.concatStringsSep "\n" (builtins.attrNames attrs)' --raw 2>/dev/null) || true
    if [[ -n "$shell_names" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && refs+=("${flake_ref}#devShells.${system}.${name}")
        done <<< "$shell_names"
    fi

    if [[ ${#refs[@]} -eq 0 ]]; then
        err "No buildable outputs found for $system in $flake_dir"
        return 1
    fi

    printf '%s\n' "${refs[@]}"
}

build_outputs() {
    local refs=("$@")
    local all_paths=()
    for ref in "${refs[@]}"; do
        info "Building $ref"
        local json_file
        json_file=$(mktemp)
        nix build "$ref" --no-link --accept-flake-config --json > "$json_file" 2>&2 || {
            err "Failed to build $ref"
            rm -f "$json_file"
            return 1
        }
        local paths
        paths=$(grep -o '\[.*\]' "$json_file" | jq -r '.[].outputs | to_entries[].value' 2>/dev/null) || {
            err "JSON parse failed, falling back to nix path-info"
            paths=$(nix path-info "$ref" 2>/dev/null)
        }
        rm -f "$json_file"
        all_paths+=($paths)
    done
    printf '%s\n' "${all_paths[@]}"
}

get_closure() {
    nix-store --query --requisites "$@" | sort -u
}

# export_paths_directly <store_paths...> — export only the given paths as NARs
# This is MUCH faster than `nix copy --to file://` which exports the entire
# closure (potentially thousands of paths). We dump each path individually,
# compress it, compute hashes, generate narinfo, and sign if configured.
export_paths_directly() {
    local paths=("$@")
    if [[ ${#paths[@]} -eq 0 ]]; then
        info "No paths to export"
        return 0
    fi

    mkdir -p "$CACHE_DIR/nar"

    # Sign paths in the local store if we have a key
    if [[ -n "$NIXCACHE_SIGNING_KEY_FILE" ]]; then
        info "Signing ${#paths[@]} store paths"
        nix store sign --key-file "$NIXCACHE_SIGNING_KEY_FILE" "${paths[@]}" 2>&1 >&2 || true
    fi

    info "Exporting ${#paths[@]} store paths (direct NAR dump, skipping full closure)"

    for store_path in "${paths[@]}"; do
        local hash
        hash=$(basename "$store_path" | cut -c1-32)
        local nar_file="$CACHE_DIR/nar/${hash}.nar.xz"

        # Dump and compress the NAR
        nix-store --dump "$store_path" | xz -1 > "$nar_file"

        local file_size file_hash
        file_size=$(stat -c%s "$nar_file")
        file_hash=$(nix hash file --type sha256 --base32 "$nar_file")

        # Get path info for narinfo metadata
        local path_info
        path_info=$(nix path-info --json "$store_path" 2>/dev/null)

        # Generate narinfo
        python3 -c "
import json, sys, os

store_path = sys.argv[1]
hash_prefix = sys.argv[2]
nar_file = sys.argv[3]
file_size = int(sys.argv[4])
file_hash = sys.argv[5]
cache_dir = sys.argv[6]

info = json.loads(sys.argv[7])
# nix path-info --json returns a list or dict depending on version
if isinstance(info, list):
    info = info[0]
elif isinstance(info, dict) and store_path in info:
    info = info[store_path]

nar_hash = info.get('narHash', '')
nar_size = info.get('narSize', 0)
refs = info.get('references', [])
deriver = info.get('deriver', '')
sigs = info.get('signatures', info.get('sigs', []))

# Build references as just the basename of each ref path
ref_names = ' '.join(os.path.basename(r) for r in refs)

lines = [
    f'StorePath: {store_path}',
    f'URL: nar/{hash_prefix}.nar.xz',
    f'Compression: xz',
    f'FileHash: sha256:{file_hash}',
    f'FileSize: {file_size}',
    f'NarHash: {nar_hash}',
    f'NarSize: {nar_size}',
]
if ref_names:
    lines.append(f'References: {ref_names}')
if deriver:
    lines.append(f'Deriver: {os.path.basename(deriver)}')
for sig in sigs:
    lines.append(f'Sig: {sig}')

narinfo_path = os.path.join(cache_dir, f'{hash_prefix}.narinfo')
with open(narinfo_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
" "$store_path" "$hash" "$nar_file" "$file_size" "$file_hash" "$CACHE_DIR" "$path_info"

        info "  Exported $hash ($(numfmt --to=iec "$file_size" 2>/dev/null || echo "${file_size}B"))"
    done

    info "Export complete: ${#paths[@]} paths"
}

# ── OCI upload pipeline ──────────────────────────────────────────────

# Upload all locally-built paths to GHCR as OCI artifacts.
# State that could grow past ARG_MAX (the existing index, per-path receipts)
# is passed via files, not argv — otherwise a few hundred uploads blow past
# the exec limit.
upload_to_oci() {
    info "Uploading to GHCR: ${NIXCACHE_IMAGE}"

    # Download existing index to a file.
    local existing_index_file="$NIXCACHE_WORK_DIR/existing-index.json"
    echo '{}' > "$existing_index_file"
    local existing_manifest
    existing_manifest=$(oci_get_manifest "cache-index")
    if [[ -n "$existing_manifest" ]]; then
        local index_digest
        index_digest=$(echo "$existing_manifest" | jq -r '.layers[0].digest // empty' 2>/dev/null)
        if [[ -n "$index_digest" ]]; then
            oci_get_blob "$index_digest" > "$existing_index_file" 2>/dev/null \
                || echo '{}' > "$existing_index_file"
        fi
    fi

    # Per-upload receipts go to a JSONL file.
    local receipts_file="$NIXCACHE_WORK_DIR/uploads.jsonl"
    : > "$receipts_file"

    local uploaded=0
    local upload_failures=0

    for narinfo in "$CACHE_DIR"/*.narinfo; do
        [[ -f "$narinfo" ]] || continue
        local hash
        hash=$(basename "$narinfo" .narinfo)

        local nar_url
        nar_url=$(grep '^URL: ' "$narinfo" | head -1 | cut -d' ' -f2)
        local nar_file="$CACHE_DIR/$nar_url"

        if [[ ! -f "$nar_file" ]]; then
            err "NAR file not found for $hash: $nar_url"
            continue
        fi

        local nar_size
        nar_size=$(stat -c%s "$nar_file")

        info "  Uploading NAR for $hash ($(numfmt --to=iec "$nar_size" 2>/dev/null || echo "${nar_size}B"))"
        local nar_digest
        nar_digest=$(oci_push_blob "$nar_file") || {
            err "Failed to upload NAR for $hash"
            upload_failures=$((upload_failures + 1))
            continue
        }

        # Append one-line JSON receipt; the final index-build reads these.
        jq -n -c \
            --arg hash "$hash" \
            --arg narinfo_file "$narinfo" \
            --arg nar_digest "$nar_digest" \
            --argjson nar_size "$nar_size" \
            '{hash: $hash, narinfo_file: $narinfo_file, nar_digest: $nar_digest, nar_size: $nar_size}' \
            >> "$receipts_file"

        uploaded=$((uploaded + 1))
    done

    if [[ "$uploaded" -eq 0 ]]; then
        info "No new paths to upload"
        return 0
    fi

    if [[ "$upload_failures" -gt 0 ]]; then
        err "$upload_failures upload(s) failed. Updating index with $uploaded successful upload(s) only."
    fi

    info "Uploaded $uploaded NAR(s), updating index"
    update_cache_index "$existing_index_file" "$receipts_file" "$@"
}

# Update the cache-index manifest with new entries.
# update_cache_index <existing_index_file> <receipts_file> <gc_root_paths...>
update_cache_index() {
    local existing_index_file="$1"
    local receipts_file="$2"
    shift 2
    local gc_root_paths=("$@")

    # Collect gc-root hashes into a file.
    local gc_roots_file="$NIXCACHE_WORK_DIR/gc-roots.json"
    local gc_json="[]"
    for p in "${gc_root_paths[@]}"; do
        local h
        h=$(basename "$p" | cut -c1-32)
        gc_json=$(echo "$gc_json" | jq -c --arg h "$h" '. + [$h]')
    done
    printf '%s' "$gc_json" > "$gc_roots_file"

    local public_key=""
    if [[ -n "$NIXCACHE_SIGNING_KEY_FILE" ]] && [[ -f "${NIXCACHE_SIGNING_KEY_FILE}.pub" ]]; then
        public_key=$(cat "${NIXCACHE_SIGNING_KEY_FILE}.pub")
    fi

    # Build the merged index in one Python run, reading large inputs from
    # files/env so argv stays tiny regardless of how many entries there are.
    local index_file="$NIXCACHE_WORK_DIR/cache-index.json"
    EXISTING_INDEX_FILE="$existing_index_file" \
    RECEIPTS_FILE="$receipts_file" \
    GC_ROOTS_FILE="$gc_roots_file" \
    OUTPUT_FILE="$index_file" \
    PUBLIC_KEY="$public_key" \
    NIXCACHE_REPO="$NIXCACHE_REPO" \
    NIXCACHE_REGISTRY="$NIXCACHE_REGISTRY" \
    NIXCACHE_IMAGE="$NIXCACHE_IMAGE" \
    GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    python3 <<'PYEOF'
import json, os

with open(os.environ["EXISTING_INDEX_FILE"]) as f:
    try:
        existing = json.load(f)
    except json.JSONDecodeError:
        existing = {}

with open(os.environ["GC_ROOTS_FILE"]) as f:
    new_gc_roots = json.load(f)

new_entries = {}
with open(os.environ["RECEIPTS_FILE"]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        with open(r["narinfo_file"]) as nf:
            narinfo = nf.read()
        store_path = ""
        for l in narinfo.splitlines():
            if l.startswith("StorePath: "):
                store_path = l[len("StorePath: "):].strip()
                break
        name = (
            os.path.basename(store_path).split("-", 1)[-1]
            if store_path else r["hash"]
        )
        new_entries[r["hash"]] = {
            "name": name,
            "narinfo": narinfo,
            "nar_digest": r["nar_digest"],
            "nar_size": int(r["nar_size"]),
            "added": os.environ["GENERATED_AT"],
        }

index = {
    "version": 1,
    "repo": os.environ["NIXCACHE_REPO"],
    "registry": os.environ["NIXCACHE_REGISTRY"],
    "image": os.environ["NIXCACHE_IMAGE"],
    "generated": os.environ["GENERATED_AT"],
    "public_key": os.environ["PUBLIC_KEY"] or existing.get("public_key", ""),
    "entries": {},
    "gc_roots": [],
}

index["entries"].update(existing.get("entries", {}))
index["entries"].update(new_entries)

index["gc_roots"] = sorted(
    set(existing.get("gc_roots", [])) | set(new_gc_roots)
)

with open(os.environ["OUTPUT_FILE"], "w") as f:
    json.dump(index, f, indent=2, sort_keys=True)

print(
    f">>> Cache index rebuilt: {len(index['entries'])} total entries "
    f"({len(new_entries)} new), {len(index['gc_roots'])} gc roots"
)
PYEOF

    # Push index as a blob
    local index_digest
    index_digest=$(oci_push_blob "$index_file")
    local index_size
    index_size=$(stat -c%s "$index_file")

    # Create an empty config blob (required by OCI spec)
    local config_file="$NIXCACHE_WORK_DIR/config.json"
    echo '{}' > "$config_file"
    local config_digest
    config_digest=$(oci_push_blob "$config_file")
    local config_size
    config_size=$(stat -c%s "$config_file")

    # Create and push the manifest tagged as cache-index
    local manifest
    manifest=$(jq -n \
        --arg config_digest "$config_digest" \
        --argjson config_size "$config_size" \
        --arg index_digest "$index_digest" \
        --argjson index_size "$index_size" \
        '{
            schemaVersion: 2,
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            config: {
                mediaType: "application/vnd.oci.image.config.v1+json",
                digest: $config_digest,
                size: $config_size
            },
            layers: [{
                mediaType: "application/vnd.nix.cache.index.v1+json",
                digest: $index_digest,
                size: $index_size
            }]
        }')

    oci_push_manifest "cache-index" "$manifest"
    info "Cache index updated ($(echo "$new_entries" | jq 'length') new entries)"
}

# ── Main pipeline ─────────────────────────────────────────────────────

# start_self_substituter — start the proxy on the CI runner so that Nix can
# pull previously-cached paths from our own GHCR cache instead of rebuilding.
# This avoids recompiling packages that haven't changed between runs.
start_self_substituter() {
    info "Starting self-substituter to reuse previously cached builds"

    # The proxy script is at proxy/main.py relative to the repo root
    local proxy_script
    proxy_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/proxy/main.py"
    if [[ ! -f "$proxy_script" ]]; then
        info "Proxy script not found at $proxy_script, skipping self-substitution"
        return 0
    fi

    # NIXCACHE_UPSTREAM="" — skip proxy's internal upstream fallback. Nix
    # already queries cache.nixos.org and the flake's other substituters
    # directly in parallel, so the proxy blocking on an upstream HTTP call
    # per miss just serializes what Nix would otherwise do concurrently.
    NIXCACHE_REPO="$NIXCACHE_REPO" \
    NIXCACHE_PORT=37515 \
    NIXCACHE_LISTEN=127.0.0.1 \
    NIXCACHE_UPSTREAM="" \
    GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" \
        python3 "$proxy_script" &
    SELF_PROXY_PID=$!

    # Wait for it to be ready
    local ready=false
    for i in $(seq 1 15); do
        if curl -fs --max-time 2 http://127.0.0.1:37515/nix-cache-info >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 1
    done

    if [[ "$ready" == "true" ]]; then
        info "Self-substituter running (pid=$SELF_PROXY_PID)"
        # Configure Nix to use our own cache during builds
        # Try system config first, fall back to user config
        local nix_conf="/etc/nix/nix.conf"
        if [[ ! -w "$nix_conf" ]] && [[ ! -w "$(dirname "$nix_conf")" ]]; then
            nix_conf="${HOME}/.config/nix/nix.conf"
            mkdir -p "$(dirname "$nix_conf")"
        fi
        cat >> "$nix_conf" <<EOF
extra-substituters = http://127.0.0.1:37515
extra-trusted-substituters = http://127.0.0.1:37515
EOF
        info "Added self-substituter to $nix_conf"

        # Trust our own signing key so Nix will accept signed NARs served
        # by the proxy. Without this, require-sigs rejects them and we'd
        # rebuild everything on every run instead of substituting.
        if [[ -n "${NIXCACHE_SIGNING_KEY_FILE:-}" ]] && [[ -f "$NIXCACHE_SIGNING_KEY_FILE" ]]; then
            local pub_key
            pub_key=$(nix key convert-secret-to-public < "$NIXCACHE_SIGNING_KEY_FILE" 2>/dev/null || true)
            if [[ -n "$pub_key" ]]; then
                echo "extra-trusted-public-keys = $pub_key" >> "$nix_conf"
                info "Trusted own public key: $pub_key"
            fi
        fi
    else
        info "Self-substituter failed to start, continuing without it"
        kill "$SELF_PROXY_PID" 2>/dev/null || true
        SELF_PROXY_PID=""
    fi
}

# find_locally_built_paths — enumerate the full closure of the given output
# paths and return only those with NO signatures. Paths substituted from
# any cache (external or our own) carry that cache's signature in their
# narinfo; locally-built paths have no signature. Skip anything already in
# our GHCR index (uploaded in a previous run). This replaces the old
# --dry-run narinfo fan-out: it's pure local sqlite state, thousands of
# times faster, and it's what cachix-action does.
find_locally_built_paths() {
    local paths=("$@")

    # Pull our GHCR index so we can skip already-uploaded paths.
    local own_hashes=""
    oci_get_token 2>/dev/null || true
    local existing_manifest
    existing_manifest=$(oci_get_manifest "cache-index" 2>/dev/null)
    if [[ -n "$existing_manifest" ]]; then
        local index_digest
        index_digest=$(echo "$existing_manifest" | jq -r '.layers[0].digest // empty' 2>/dev/null)
        if [[ -n "$index_digest" ]]; then
            own_hashes=$(oci_get_blob "$index_digest" 2>/dev/null | \
                jq -r '.entries | keys[]' 2>/dev/null || true)
        fi
    fi
    local own_count=0
    if [[ -n "$own_hashes" ]]; then
        own_count=$(echo "$own_hashes" | wc -l)
    fi
    info "GHCR index contains $own_count previously-cached entries"

    # Walk the closure once. `nix path-info --json --recursive` returns
    # either a list (newer Nix) or a path-keyed object (older Nix); the
    # jq normalization handles both.
    nix path-info --json --recursive "${paths[@]}" 2>/dev/null | \
        jq -r '
            (if type == "array" then .
             else (to_entries | map({path: .key} + .value))
             end) |
            .[] | select((.signatures // []) | length == 0) | .path
        ' | while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            local h
            h=$(basename "$path" | cut -c1-32)
            if [[ -n "$own_hashes" ]] && echo "$own_hashes" | grep -qxF "$h"; then
                continue
            fi
            echo "$path"
        done | sort -u
}

stop_self_substituter() {
    if [[ -n "${SELF_PROXY_PID:-}" ]]; then
        kill "$SELF_PROXY_PID" 2>/dev/null || true
        info "Self-substituter stopped"
    fi
}

full_pipeline() {
    local flake_dir="${NIXCACHE_CONFIG_DIR}"

    info "Starting OCI cache pipeline"
    info "Config: $flake_dir | Image: $NIXCACHE_IMAGE"

    # 0. Start our proxy as a substituter. Gives Nix access to paths
    #    cached from previous runs without rebuilding.
    SELF_PROXY_PID=""
    start_self_substituter

    # 1. Discover outputs.
    local discovered
    discovered=$(discover_outputs "$flake_dir")
    if [[ -z "$discovered" ]]; then
        err "No buildable outputs found in $flake_dir"
        stop_self_substituter
        return 1
    fi
    local refs_array
    mapfile -t refs_array <<< "$discovered"
    info "Discovered ${#refs_array[@]} output(s) to build"
    printf '    %s\n' "${refs_array[@]}" >&2

    # 2. Build all outputs. Nix does narinfo resolution and substitution
    #    inline, interleaved with compilation — no separate dry-run pass.
    #    --accept-flake-config so the flake's extra-substituters (jovian,
    #    cachyos via lantian, etc.) are used in parallel with cache.nixos.org.
    local output_paths
    output_paths=$(build_outputs "${refs_array[@]}")
    local paths_array
    mapfile -t paths_array <<< "$output_paths"
    info "Built ${#paths_array[@]} top-level output(s)"

    # Done with the self-substituter — the rest is local + GHCR uploads.
    stop_self_substituter

    # 3. Signature-based filter: upload only paths built locally (no sig).
    #    Paths with any signature came from some cache already.
    info "Inspecting closure signatures to find locally-built paths"
    local upload_list
    upload_list=$(find_locally_built_paths "${paths_array[@]}")
    if [[ -z "$upload_list" ]]; then
        info "Nothing to upload — every path has an external or existing signature"
        write_summary "${#refs_array[@]}" 0 0 "${#paths_array[@]}"
        return 0
    fi
    local upload_array
    mapfile -t upload_array <<< "$upload_list"
    info "Locally-built paths to upload: ${#upload_array[@]}"

    # 4. Export NARs (this step also signs them with our key).
    export_paths_directly "${upload_array[@]}"

    # 5. Upload NARs + index manifest to GHCR.
    upload_to_oci "${paths_array[@]}"

    write_summary "${#refs_array[@]}" "${#upload_array[@]}" "${#upload_array[@]}" "${#paths_array[@]}"
    info "Pipeline complete!"
}

# Write a GitHub Actions step summary if available
write_summary() {
    local outputs="$1" new_paths="$2" uploaded="$3" total_outputs="$4"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        cat >> "$GITHUB_STEP_SUMMARY" <<EOF
## Cache Build Summary

| Metric | Count |
|---|---|
| Flake outputs discovered | $outputs |
| Output paths built | $total_outputs |
| New paths cached to GHCR | $new_paths |
| Paths already cached | skipped |
EOF
    fi
}

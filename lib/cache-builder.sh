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
        # Build with verbose output (stderr shown in CI logs), JSON to file
        local json_file
        json_file=$(mktemp)
        nix build "$ref" --no-link --json > "$json_file" 2>&2 || {
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

filter_upstream() {
    local paths=("$@")
    local upstream_caches
    IFS=' ' read -ra upstream_caches <<< "$NIXCACHE_UPSTREAM_CACHES"

    info "Checking ${#paths[@]} paths against upstream caches"

    local local_only=()
    local skipped=0

    for store_path in "${paths[@]}"; do
        local hash
        hash=$(basename "$store_path" | cut -c1-32)
        local found_upstream=false

        for cache_url in "${upstream_caches[@]}"; do
            local http_code
            http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                "${cache_url}/${hash}.narinfo" 2>/dev/null || echo "000")
            if [[ "$http_code" == "200" ]]; then
                found_upstream=true
                break
            fi
        done

        if [[ "$found_upstream" == "true" ]]; then
            skipped=$((skipped + 1))
        else
            local_only+=("$store_path")
        fi
    done

    info "Upstream: ${skipped} available, ${#local_only[@]} locally-built"

    if [[ ${#local_only[@]} -gt 0 ]]; then
        printf '%s\n' "${local_only[@]}"
    fi
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

# Upload all locally-built paths to GHCR as OCI artifacts
upload_to_oci() {
    info "Uploading to GHCR: ${NIXCACHE_IMAGE}"

    # Download existing index if any
    local existing_index="{}"
    local existing_manifest
    existing_manifest=$(oci_get_manifest "cache-index")
    if [[ -n "$existing_manifest" ]]; then
        local index_digest
        index_digest=$(echo "$existing_manifest" | jq -r '.layers[0].digest // empty' 2>/dev/null)
        if [[ -n "$index_digest" ]]; then
            existing_index=$(oci_get_blob "$index_digest" 2>/dev/null || echo "{}")
        fi
    fi

    local new_entries="{}"
    local uploaded=0

    for narinfo in "$CACHE_DIR"/*.narinfo; do
        [[ -f "$narinfo" ]] || continue
        local hash
        hash=$(basename "$narinfo" .narinfo)
        local narinfo_content
        narinfo_content=$(cat "$narinfo")

        # Find the NAR file
        local nar_url
        nar_url=$(grep '^URL: ' "$narinfo" | head -1 | cut -d' ' -f2)
        local nar_file="$CACHE_DIR/$nar_url"

        if [[ ! -f "$nar_file" ]]; then
            err "NAR file not found for $hash: $nar_url"
            continue
        fi

        local nar_size
        nar_size=$(stat -c%s "$nar_file")

        # Push NAR blob
        info "  Uploading NAR for $hash ($(numfmt --to=iec "$nar_size" 2>/dev/null || echo "${nar_size}B"))"
        local nar_digest
        nar_digest=$(oci_push_blob "$nar_file") || {
            err "Failed to upload NAR for $hash"
            continue
        }

        # Store entry in index
        local store_path
        store_path=$(grep '^StorePath: ' "$narinfo" | head -1 | cut -d' ' -f2)
        local name
        name=$(basename "$store_path" | sed 's/^[a-z0-9]*-//')

        # Use python to properly handle narinfo with newlines in JSON
        new_entries=$(python3 -c "
import json, sys
entries = json.loads(sys.argv[1])
entries[sys.argv[2]] = {
    'name': sys.argv[3],
    'narinfo': open(sys.argv[4]).read(),
    'nar_digest': sys.argv[5],
    'nar_size': int(sys.argv[6]),
    'added': sys.argv[7]
}
print(json.dumps(entries))
" "$new_entries" "$hash" "$name" "$narinfo" "$nar_digest" "$nar_size" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

        uploaded=$((uploaded + 1))
    done

    if [[ "$uploaded" -eq 0 ]]; then
        info "No new paths to upload"
        return 0
    fi

    info "Uploaded $uploaded NAR(s), updating index"
    update_cache_index "$existing_index" "$new_entries" "$@"
}

# Update the cache-index manifest with new entries
# update_cache_index <existing_json> <new_entries_json> <gc_root_paths...>
update_cache_index() {
    local existing_index="$1"
    local new_entries="$2"
    shift 2
    local gc_root_paths=("$@")

    local gc_roots="[]"
    for p in "${gc_root_paths[@]}"; do
        local h
        h=$(basename "$p" | cut -c1-32)
        gc_roots=$(echo "$gc_roots" | jq --arg h "$h" '. + [$h]')
    done

    local public_key=""
    if [[ -n "$NIXCACHE_SIGNING_KEY_FILE" ]] && [[ -f "${NIXCACHE_SIGNING_KEY_FILE}.pub" ]]; then
        public_key=$(cat "${NIXCACHE_SIGNING_KEY_FILE}.pub")
    fi

    # Merge indices
    local index_file="$NIXCACHE_WORK_DIR/cache-index.json"
    python3 -c "
import json, sys

existing = json.loads(sys.argv[1])
new_entries = json.loads(sys.argv[2])
gc_roots = json.loads(sys.argv[3])
public_key = sys.argv[4]
repo = sys.argv[5]

index = {
    'version': 1,
    'repo': repo,
    'registry': '${NIXCACHE_REGISTRY}',
    'image': '${NIXCACHE_IMAGE}',
    'generated': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'public_key': public_key,
    'entries': {},
    'gc_roots': []
}

if 'entries' in existing:
    index['entries'].update(existing['entries'])
if 'gc_roots' in existing:
    index['gc_roots'] = existing['gc_roots']

index['entries'].update(new_entries)
index['gc_roots'] = list(set(index['gc_roots'] + gc_roots))

if not public_key and existing.get('public_key'):
    index['public_key'] = existing['public_key']

json.dump(index, open('$index_file', 'w'), indent=2, sort_keys=True)
" "$existing_index" "$new_entries" "$gc_roots" "$public_key" "$NIXCACHE_REPO"

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

full_pipeline() {
    local flake_dir="${NIXCACHE_CONFIG_DIR}"

    info "Starting OCI cache pipeline"
    info "Config: $flake_dir | Image: $NIXCACHE_IMAGE"

    # 1. Discover outputs
    local discovered
    discovered=$(discover_outputs "$flake_dir")
    if [[ -z "$discovered" ]]; then
        err "No buildable outputs found in $flake_dir"
        return 1
    fi
    local refs_array
    mapfile -t refs_array <<< "$discovered"
    info "Discovered ${#refs_array[@]} output(s) to build"
    printf '    %s\n' "${refs_array[@]}" >&2

    # 2. Build all outputs
    local output_paths
    output_paths=$(build_outputs "${refs_array[@]}")
    local paths_array
    mapfile -t paths_array <<< "$output_paths"
    info "Built ${#paths_array[@]} output path(s)"

    # 3. Get closure
    local closure
    closure=$(get_closure "${paths_array[@]}")
    local closure_array
    mapfile -t closure_array <<< "$closure"
    info "Full closure: ${#closure_array[@]} store paths"

    # 4. Filter upstream
    local local_paths
    local_paths=$(filter_upstream "${closure_array[@]}")
    if [[ -z "$local_paths" ]]; then
        info "All closure paths are available upstream — nothing to upload"
        return 0
    fi
    local local_array
    mapfile -t local_array <<< "$local_paths"
    info "Locally-built paths to cache: ${#local_array[@]}"

    # 5. Export only locally-built paths (direct NAR dump, no full closure)
    export_paths_directly "${local_array[@]}"

    # 6. Upload to GHCR
    upload_to_oci "${paths_array[@]}"

    info "Pipeline complete!"
}

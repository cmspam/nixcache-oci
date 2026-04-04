#!/usr/bin/env bash
# test-substitution.sh — Integration test using podman to verify OCI-backed cache works
set -euo pipefail

REPO="${1:-cmspam/nixcache-oci}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Nix Binary Cache (OCI) Substitution Test ==="
echo "Repo: $REPO"

# Fetch the cache index from GHCR
echo ">>> Fetching cache index from GHCR..."
TOKEN=$(gh auth token 2>/dev/null || echo "")
MANIFEST=$(curl -fsSL \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/${REPO}/nix-cache/manifests/cache-index" 2>/dev/null) || {
    echo "!!! Cannot fetch cache index. Has the cache been published?"
    exit 1
}

INDEX_DIGEST=$(echo "$MANIFEST" | jq -r '.layers[0].digest')
INDEX=$(curl -fsSL -L \
    -H "Authorization: Bearer $TOKEN" \
    "https://ghcr.io/v2/${REPO}/nix-cache/blobs/${INDEX_DIGEST}" 2>/dev/null)

STORE_HASH=$(echo "$INDEX" | python3 -c "
import json, sys
idx = json.load(sys.stdin)
roots = idx.get('gc_roots', [])
entries = idx.get('entries', {})
for r in roots:
    if r in entries:
        print(r)
        sys.exit(0)
if entries:
    print(next(iter(entries)))
")

if [[ -z "$STORE_HASH" ]]; then
    echo "!!! Index is empty"
    exit 1
fi

STORE_NAME=$(echo "$INDEX" | python3 -c "
import json, sys
idx = json.load(sys.stdin)
print(idx['entries']['$STORE_HASH'].get('name', 'unknown'))
")

echo ">>> Testing: $STORE_HASH-$STORE_NAME"

cat <<'CONTAINER_SCRIPT' > "$PROJECT_DIR/test/run-in-container.sh"
#!/usr/bin/env bash
set -euo pipefail

REPO="$1"
STORE_HASH="$2"

echo "=== Inside container ==="

echo ">>> Installing python3 and curl..."
nix-env -iA nixpkgs.python3 nixpkgs.curl 2>&1 | tail -3

echo ">>> Starting proxy..."
NIXCACHE_REPO="$REPO" python3 /proxy/main.py &
PROXY_PID=$!
sleep 2

if ! kill -0 $PROXY_PID 2>/dev/null; then
    echo "!!! Proxy failed to start"
    exit 1
fi

echo ">>> Testing /nix-cache-info..."
CACHE_INFO=$(curl -fs http://localhost:37515/nix-cache-info)
echo "$CACHE_INFO"

echo ">>> Testing narinfo lookup for $STORE_HASH..."
NARINFO=$(curl -fs "http://localhost:37515/${STORE_HASH}.narinfo") || {
    echo "!!! narinfo lookup failed"
    kill $PROXY_PID 2>/dev/null; exit 1
}
echo "$NARINFO"

STORE_PATH=$(echo "$NARINFO" | grep '^StorePath: ' | cut -d' ' -f2)
echo ">>> Full store path: $STORE_PATH"

mkdir -p /etc/nix
cat > /etc/nix/nix.conf <<EOF
substituters = http://localhost:37515
trusted-substituters = http://localhost:37515
require-sigs = false
sandbox = false
experimental-features = nix-command flakes
EOF

echo ">>> Realising $STORE_PATH from cache..."
nix-store --realise "$STORE_PATH" 2>&1 || {
    echo "!!! Failed to realise store path"
    kill $PROXY_PID 2>/dev/null; exit 1
}

if [[ -e "$STORE_PATH" ]]; then
    echo ">>> SUCCESS: $STORE_PATH exists!"
    if [[ -d "$STORE_PATH/bin" ]]; then
        FIRST_BIN=$(ls "$STORE_PATH/bin/" | head -1)
        echo ">>> Running $FIRST_BIN:"
        "$STORE_PATH/bin/$FIRST_BIN" 2>&1 || true
    fi
else
    echo "!!! Store path missing after realise"
    kill $PROXY_PID 2>/dev/null; exit 1
fi

echo "=== Test PASSED ==="
kill $PROXY_PID 2>/dev/null
CONTAINER_SCRIPT
chmod +x "$PROJECT_DIR/test/run-in-container.sh"

echo ">>> Running test in podman container..."
podman run --rm \
    -v "$PROJECT_DIR/proxy:/proxy:ro" \
    -v "$PROJECT_DIR/test/run-in-container.sh:/run-test.sh:ro" \
    -e "NIX_CONFIG=experimental-features = nix-command flakes" \
    docker.io/nixos/nix:latest \
    bash /run-test.sh "$REPO" "$STORE_HASH"

echo "=== All tests passed ==="

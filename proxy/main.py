#!/usr/bin/env python3
"""
nixcache-proxy — Local HTTP proxy bridging Nix binary cache protocol to GHCR.

Serves narinfo responses from a locally-cached index (zero network latency).
Fetches NAR blobs from GHCR on demand with disk caching.
Falls back to upstream caches for paths not in the OCI cache.
"""

import http.server
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = os.environ.get("NIXCACHE_REPO", "cmspam/nixcache-oci")
REGISTRY = os.environ.get("NIXCACHE_REGISTRY", "ghcr.io")
PORT = int(os.environ.get("NIXCACHE_PORT", "37515"))
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", os.environ.get("GH_TOKEN", ""))
CACHE_DIR = Path(
    os.environ.get(
        "NIXCACHE_CACHE_DIR",
        Path.home() / ".cache" / "nixcache-proxy" / REPO.replace("/", "--"),
    )
)
INDEX_TTL = int(os.environ.get("NIXCACHE_INDEX_TTL", "300"))  # seconds
UPSTREAM_CACHES = os.environ.get("NIXCACHE_UPSTREAM", "https://cache.nixos.org").split()
IMAGE = os.environ.get("NIXCACHE_IMAGE", f"{REGISTRY}/{REPO}/nix-cache")


def fetch_url(url: str, headers: dict | None = None, timeout: int = 60) -> bytes | None:
    req = urllib.request.Request(url)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return None


def ghcr_headers() -> dict:
    h = {"Accept": "application/vnd.oci.image.manifest.v1+json"}
    if GITHUB_TOKEN:
        h["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    return h


def ghcr_fetch(path: str) -> bytes | None:
    """Fetch from GHCR registry API."""
    url = f"https://{REGISTRY}/v2/{REPO}/nix-cache{path}"
    return fetch_url(url, ghcr_headers())


def ghcr_fetch_blob(digest: str) -> bytes | None:
    """Fetch an OCI blob by digest, following redirects."""
    url = f"https://{REGISTRY}/v2/{REPO}/nix-cache/blobs/{digest}"
    req = urllib.request.Request(url)
    for k, v in ghcr_headers().items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read()
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return None


class CacheIndex:
    """Thread-safe cache index loaded from GHCR."""

    def __init__(self):
        self._index: dict | None = None
        self._lock = threading.Lock()
        self._last_fetch = 0.0
        self._index_file = CACHE_DIR / "cache-index.json"

    def get(self) -> dict:
        with self._lock:
            if time.time() - self._last_fetch > INDEX_TTL:
                self._refresh()
            return self._index or {"entries": {}, "gc_roots": []}

    def _refresh(self):
        # Try to fetch from GHCR
        manifest_data = ghcr_fetch("/manifests/cache-index")
        if manifest_data:
            try:
                manifest = json.loads(manifest_data)
                layers = manifest.get("layers", [])
                if layers:
                    index_digest = layers[0]["digest"]
                    index_data = ghcr_fetch_blob(index_digest)
                    if index_data:
                        self._index = json.loads(index_data)
                        # Cache to disk
                        self._index_file.parent.mkdir(parents=True, exist_ok=True)
                        self._index_file.write_bytes(index_data)
            except (json.JSONDecodeError, KeyError):
                pass

        # Fall back to disk cache
        if not self._index and self._index_file.exists():
            try:
                self._index = json.loads(self._index_file.read_bytes())
            except json.JSONDecodeError:
                pass

        self._last_fetch = time.time()

    def lookup(self, store_hash: str) -> dict | None:
        index = self.get()
        return index.get("entries", {}).get(store_hash)


cache_index = CacheIndex()


class DiskCache:
    def __init__(self, base: Path):
        self.base = base
        self.base.mkdir(parents=True, exist_ok=True)

    def _key_path(self, key: str) -> Path:
        safe = key.replace("/", "--").replace(":", "_")
        return self.base / safe

    def get(self, key: str) -> bytes | None:
        p = self._key_path(key)
        return p.read_bytes() if p.exists() else None

    def put(self, key: str, data: bytes):
        p = self._key_path(key)
        p.write_bytes(data)


disk_cache = DiskCache(CACHE_DIR / "blobs")

NCI_RESPONSE = (
    b"StoreDir: /nix/store\n"
    b"WantMassQuery: 1\n"
    b"Priority: 40\n"
)


class CacheHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stderr.write(f"[nixcache-proxy] {args[0]}\n")

    def do_GET(self):
        path = self.path.rstrip("/")
        if path == "/nix-cache-info":
            self._serve_bytes(NCI_RESPONSE, "text/x-nix-cache-info")
        elif path.endswith(".narinfo"):
            self._serve_narinfo(path)
        elif path.startswith("/nar/"):
            self._serve_nar(path)
        else:
            self.send_error(404)

    def _serve_bytes(self, data: bytes, content_type: str):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _serve_narinfo(self, path: str):
        store_hash = path.lstrip("/").removesuffix(".narinfo")

        # Look up in our OCI index (local, zero latency)
        entry = cache_index.lookup(store_hash)
        if entry and "narinfo" in entry:
            body = entry["narinfo"].encode("utf-8")
            self._serve_bytes(body, "text/x-nix-narinfo")
            return

        # Fall back to upstream caches
        for cache_url in UPSTREAM_CACHES:
            data = fetch_url(f"{cache_url}/{store_hash}.narinfo", timeout=10)
            if data is not None:
                self._serve_bytes(data, "text/x-nix-narinfo")
                return

        self.send_error(404)

    def _serve_nar(self, path: str):
        # path = /nar/HASH.nar.xz
        nar_basename = path.removeprefix("/nar/")
        cache_key = f"nar-{nar_basename}"

        # Check disk cache
        cached = disk_cache.get(cache_key)
        if cached is not None:
            self._send_nar(cached, nar_basename)
            return

        # Look up in our index to find the OCI blob digest
        # We need to find which entry has this NAR
        index = cache_index.get()
        nar_digest = None
        for _hash, entry in index.get("entries", {}).items():
            narinfo = entry.get("narinfo", "")
            # Check if this entry's narinfo references this NAR file
            for line in narinfo.split("\n"):
                if line.startswith("URL: ") and nar_basename in line:
                    nar_digest = entry.get("nar_digest")
                    break
            if nar_digest:
                break

        if nar_digest:
            data = ghcr_fetch_blob(nar_digest)
            if data is not None:
                disk_cache.put(cache_key, data)
                self._send_nar(data, nar_basename)
                return

        # Fall back to upstream
        for cache_url in UPSTREAM_CACHES:
            data = fetch_url(f"{cache_url}{path}", timeout=60)
            if data is not None:
                disk_cache.put(cache_key, data)
                self._send_nar(data, nar_basename)
                return

        self.send_error(404)

    def _send_nar(self, data: bytes, basename: str):
        ct = "application/x-xz" if basename.endswith(".xz") else "application/x-nix-nar"
        self._serve_bytes(data, ct)


def main():
    print(f"nixcache-proxy starting on http://localhost:{PORT}", file=sys.stderr)
    print(f"  Image: {IMAGE}", file=sys.stderr)
    print(f"  Upstream: {', '.join(UPSTREAM_CACHES)}", file=sys.stderr)
    print(f"  Cache dir: {CACHE_DIR}", file=sys.stderr)
    print(f"  Index TTL: {INDEX_TTL}s", file=sys.stderr)

    # Pre-fetch index
    cache_index.get()

    server = http.server.HTTPServer(("127.0.0.1", PORT), CacheHandler)

    def shutdown(signum, frame):
        print("\nShutting down...", file=sys.stderr)
        server.shutdown()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    server.serve_forever()


if __name__ == "__main__":
    main()

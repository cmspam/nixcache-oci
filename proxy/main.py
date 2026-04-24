#!/usr/bin/env python3
"""
nixcache-proxy — Local HTTP proxy bridging Nix binary cache protocol to GHCR.

Serves narinfo responses from a locally-cached index (zero network latency).
Streams NAR blobs directly from GHCR or upstream caches to Nix — no disk
caching, no buffering entire files into memory.
"""

import base64
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

REPO = os.environ.get("NIXCACHE_REPO", "cmspam/mynixcache-oci")
REGISTRY = os.environ.get("NIXCACHE_REGISTRY", "ghcr.io")
PORT = int(os.environ.get("NIXCACHE_PORT", "37515"))
LISTEN_ADDR = os.environ.get("NIXCACHE_LISTEN", "127.0.0.1")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", os.environ.get("GH_TOKEN", ""))
def _default_index_dir() -> Path:
    # Honour an explicit NIXCACHE_INDEX_DIR first, then systemd's
    # $CACHE_DIRECTORY (set when the unit declares CacheDirectory=),
    # and only fall back to $HOME/.cache if neither is set. DynamicUser
    # services have no writable home — falling through to Path.home()
    # there gets you /.cache on a read-only root fs, which then crashes
    # every request with an OSError.
    explicit = os.environ.get("NIXCACHE_INDEX_DIR")
    if explicit:
        return Path(explicit)
    cache_dir = os.environ.get("CACHE_DIRECTORY")
    if cache_dir:
        return Path(cache_dir)
    return Path.home() / ".cache" / "nixcache-proxy" / REPO.replace("/", "--")


INDEX_DIR = _default_index_dir()
INDEX_TTL = int(os.environ.get("NIXCACHE_INDEX_TTL", "300"))  # seconds
UPSTREAM_CACHES = os.environ.get("NIXCACHE_UPSTREAM", "https://cache.nixos.org").split()
STREAM_CHUNK_SIZE = 64 * 1024  # 64 KB chunks for streaming


def fetch_url(url: str, headers: dict | None = None, timeout: int = 60) -> bytes | None:
    """Fetch a URL fully into memory. Used for small responses (narinfo, index)."""
    req = urllib.request.Request(url)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return None


def open_stream(url: str, headers: dict | None = None, timeout: int = 120):
    """Open a streaming connection to a URL. Returns (response, content_length) or (None, 0)."""
    req = urllib.request.Request(url)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        length = resp.headers.get("Content-Length")
        return resp, int(length) if length else None
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return None, 0


# ── OCI auth ──────────────────────────────────────────────────────────

_oci_token: str = ""
_oci_token_time: float = 0.0


def get_oci_token() -> str:
    global _oci_token, _oci_token_time
    if _oci_token and (time.time() - _oci_token_time) < 240:
        return _oci_token

    if GITHUB_TOKEN:
        scope = f"repository:{REPO}/nix-cache:pull"
        token_url = f"https://{REGISTRY}/token?scope={scope}&service={REGISTRY}"
        creds = base64.b64encode(f"token:{GITHUB_TOKEN}".encode()).decode()
        req = urllib.request.Request(token_url)
        req.add_header("Authorization", f"Basic {creds}")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
                _oci_token = data.get("token", GITHUB_TOKEN)
                _oci_token_time = time.time()
                return _oci_token
        except Exception:
            _oci_token = GITHUB_TOKEN
            _oci_token_time = time.time()
            return _oci_token

    # Anonymous token
    scope = f"repository:{REPO}/nix-cache:pull"
    token_url = f"https://{REGISTRY}/token?scope={scope}&service={REGISTRY}"
    data = fetch_url(token_url)
    if data:
        try:
            _oci_token = json.loads(data).get("token", "")
            _oci_token_time = time.time()
            return _oci_token
        except json.JSONDecodeError:
            pass
    return ""


def ghcr_headers() -> dict:
    token = get_oci_token()
    h = {"Accept": "application/vnd.oci.image.manifest.v1+json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def ghcr_fetch(path: str) -> bytes | None:
    url = f"https://{REGISTRY}/v2/{REPO}/nix-cache{path}"
    return fetch_url(url, ghcr_headers())


def ghcr_fetch_blob(digest: str) -> bytes | None:
    url = f"https://{REGISTRY}/v2/{REPO}/nix-cache/blobs/{digest}"
    return fetch_url(url, ghcr_headers(), timeout=120)


def ghcr_stream_blob(digest: str):
    """Open a streaming connection to a GHCR blob. Returns (response, content_length) or (None, 0)."""
    url = f"https://{REGISTRY}/v2/{REPO}/nix-cache/blobs/{digest}"
    return open_stream(url, ghcr_headers())


def upstream_stream_nar(path: str):
    """Try to open a streaming connection to an upstream cache NAR. Returns (response, content_length) or (None, 0)."""
    for cache_url in UPSTREAM_CACHES:
        resp, length = open_stream(f"{cache_url}{path}", timeout=60)
        if resp is not None:
            return resp, length
    return None, 0


# ── Index ─────────────────────────────────────────────────────────────

class CacheIndex:
    def __init__(self):
        self._index: dict | None = None
        self._lock = threading.Lock()
        self._last_fetch = 0.0
        self._index_file = INDEX_DIR / "cache-index.json"

    def get(self) -> dict:
        with self._lock:
            if time.time() - self._last_fetch > INDEX_TTL:
                self._refresh()
            return self._index or {"entries": {}, "gc_roots": []}

    def force_refresh(self) -> int:
        with self._lock:
            self._last_fetch = 0.0
            self._refresh()
            entries = self._index.get("entries", {}) if self._index else {}
            return len(entries)

    def _refresh(self):
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
                        self._index_file.parent.mkdir(parents=True, exist_ok=True)
                        self._index_file.write_bytes(index_data)
                        print(f"[nixcache-proxy] Index refreshed: "
                              f"{len(self._index.get('entries', {}))} entries",
                              file=sys.stderr)
            except (json.JSONDecodeError, KeyError):
                pass

        if not self._index and self._index_file.exists():
            try:
                self._index = json.loads(self._index_file.read_bytes())
            except json.JSONDecodeError:
                pass

        self._last_fetch = time.time()

    def lookup(self, store_hash: str) -> dict | None:
        index = self.get()
        return index.get("entries", {}).get(store_hash)

    def find_nar_digest(self, nar_basename: str) -> str | None:
        """Find the OCI blob digest for a NAR file by searching narinfo URL fields."""
        index = self.get()
        for _hash, entry in index.get("entries", {}).items():
            narinfo = entry.get("narinfo", "")
            for line in narinfo.split("\n"):
                if line.startswith("URL: ") and nar_basename in line:
                    return entry.get("nar_digest")
        return None


cache_index = CacheIndex()


# ── HTTP handler ──────────────────────────────────────────────────────

def get_nci_response() -> bytes:
    lines = [
        "StoreDir: /nix/store",
        "WantMassQuery: 1",
        "Priority: 40",
    ]
    return "\n".join(lines).encode() + b"\n"


class CacheHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stderr.write(f"[nixcache-proxy] {args[0]}\n")

    def do_GET(self):
        path = self.path.rstrip("/")
        if path == "/nix-cache-info":
            self._serve_bytes(get_nci_response(), "text/x-nix-cache-info")
        elif path == "/public-key":
            self._serve_public_key()
        elif path == "/_status":
            self._serve_status()
        elif path.endswith(".narinfo"):
            self._serve_narinfo(path)
        elif path.startswith("/nar/"):
            self._serve_nar(path)
        else:
            self.send_error(404)

    def do_POST(self):
        path = self.path.rstrip("/")
        if path == "/_refresh":
            self._handle_refresh()
        else:
            self.send_error(404)

    def _serve_bytes(self, data: bytes, content_type: str):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _stream_response(self, resp, content_length: int | None, content_type: str):
        """Stream an upstream response directly to the client."""
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        if content_length is not None:
            self.send_header("Content-Length", str(content_length))
        self.end_headers()
        while True:
            chunk = resp.read(STREAM_CHUNK_SIZE)
            if not chunk:
                break
            self.wfile.write(chunk)

    def _serve_public_key(self):
        index = cache_index.get()
        pk = index.get("public_key", "")
        if pk:
            self._serve_bytes(pk.encode() + b"\n", "text/plain")
        else:
            self.send_error(404, "No public key configured")

    def _serve_status(self):
        index = cache_index.get()
        status = {
            "index_entries": len(index.get("entries", {})),
            "index_generated": index.get("generated", "unknown"),
            "index_ttl": INDEX_TTL,
            "repo": REPO,
            "upstream": UPSTREAM_CACHES,
        }
        body = json.dumps(status, indent=2).encode() + b"\n"
        self._serve_bytes(body, "application/json")

    def _handle_refresh(self):
        count = cache_index.force_refresh()
        body = json.dumps({"refreshed": True, "entries": count}).encode() + b"\n"
        self._serve_bytes(body, "application/json")

    def _serve_narinfo(self, path: str):
        store_hash = path.lstrip("/").removesuffix(".narinfo")

        # Look up in our OCI index — instant, no network
        entry = cache_index.lookup(store_hash)
        if entry and "narinfo" in entry:
            body = entry["narinfo"].encode("utf-8")
            self._serve_bytes(body, "text/x-nix-narinfo")
            return

        # Fall back to upstream
        for cache_url in UPSTREAM_CACHES:
            data = fetch_url(f"{cache_url}/{store_hash}.narinfo", timeout=10)
            if data is not None:
                self._serve_bytes(data, "text/x-nix-narinfo")
                return

        self.send_error(404)

    def _serve_nar(self, path: str):
        nar_basename = path.removeprefix("/nar/")
        ct = "application/x-xz" if nar_basename.endswith(".xz") else "application/x-nix-nar"

        # Try our GHCR cache — stream directly
        nar_digest = cache_index.find_nar_digest(nar_basename)
        if nar_digest:
            resp, length = ghcr_stream_blob(nar_digest)
            if resp is not None:
                self._stream_response(resp, length, ct)
                resp.close()
                return

        # Fall back to upstream — stream directly
        resp, length = upstream_stream_nar(path)
        if resp is not None:
            self._stream_response(resp, length, ct)
            resp.close()
            return

        self.send_error(404)


def main():
    print(f"nixcache-proxy starting on http://{LISTEN_ADDR}:{PORT}", file=sys.stderr)
    print(f"  Repo: {REPO}", file=sys.stderr)
    print(f"  Upstream: {', '.join(UPSTREAM_CACHES)}", file=sys.stderr)
    print(f"  Index TTL: {INDEX_TTL}s", file=sys.stderr)

    server = http.server.ThreadingHTTPServer((LISTEN_ADDR, PORT), CacheHandler)

    # Pre-fetch index in background so server starts immediately
    threading.Thread(target=cache_index.get, daemon=True).start()

    def shutdown(signum, frame):
        print("\nShutting down...", file=sys.stderr)
        server.shutdown()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    server.serve_forever()


if __name__ == "__main__":
    main()

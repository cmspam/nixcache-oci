# nixcache-oci

Self-hosted Nix binary cache backed by GHCR (GitHub Container Registry). No external servers, CDNs, or databases. Free for public repos.

## How it works

1. Put your flake configuration in `config/` with any packages, NixOS hosts, or dev shells.

2. **GitHub Actions** builds everything, filters out upstream-available paths, and pushes only locally-built NARs as OCI blobs to GHCR. A single index manifest maps all store hashes to blob digests.

3. A **local proxy** serves narinfo from a cached index (zero-latency lookups) and fetches NAR blobs from GHCR on demand, with upstream fallback to cache.nixos.org.

4. **Automated updates**: a weekly workflow runs `nix flake update`, rebuilds, and caches new packages so your systems stay current.

## Why GHCR instead of GitHub Releases?

| | GitHub Releases | GHCR (OCI) |
|---|---|---|
| Storage limit | 1000 assets/release | Unlimited blobs |
| Max file size | 2 GiB | ~10 GiB |
| Sharding needed | Yes (complex) | No |
| Content-addressed | No | Yes (dedup free) |
| narinfo lookup | 1 HTTP request each | Local (from cached index) |
| Cost (public) | Free | Free |

## Quick start

### Publishing (repo owner)

1. Edit `config/flake.nix`:
   ```nix
   {
     inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
     outputs = { self, nixpkgs }: {
       packages.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.myPackage;
       nixosConfigurations.my-host = nixpkgs.lib.nixosSystem { ... };
     };
   }
   ```

2. Push to `main`. The workflow builds, filters upstream, and uploads only locally-built paths to GHCR.

3. Optionally set `NIX_SIGNING_KEY` secret for persistent signing.

### Automated updates

The `update-and-cache` workflow runs weekly to:
1. `nix flake update` in `config/`
2. Commit the new `flake.lock`
3. Rebuild and cache any new packages

Trigger manually anytime: `gh workflow run update-and-cache.yml`

### Consuming (client)

**Run the proxy:**
```bash
nix run github:cmspam/nixcache-oci#cache-proxy &
# Nix automatically uses the cache + upstream fallback
```

**NixOS module (persistent):**
```nix
{
  inputs.nixcache.url = "github:cmspam/nixcache-oci";
  outputs = { nixcache, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixcache.nixosModules.default
        { services.nixcache-proxy.enable = true; }
      ];
    };
  };
}
```

### Proxy configuration

| Variable | Default | Description |
|---|---|---|
| `NIXCACHE_REPO` | `cmspam/nixcache-oci` | GitHub owner/repo |
| `NIXCACHE_PORT` | `37515` | Local port |
| `NIXCACHE_UPSTREAM` | `https://cache.nixos.org` | Upstream cache URLs (space-separated) |
| `GITHUB_TOKEN` | (none) | Token for private repos |
| `NIXCACHE_INDEX_TTL` | `300` | Index refresh interval (seconds) |

## Architecture

```
config/flake.nix          GitHub Actions              GHCR (ghcr.io)
+--------------+   push   +------------------+  push  +----------------+
| packages     | -------- | build all outputs| ------ | NAR blobs      |
| nixosConfigs |          | filter upstream  |        | (content-addr) |
| devShells    |          | push OCI blobs   |        |                |
+--------------+          +------------------+        | cache-index    |
                                                       | (all narinfo)  |
                                                       +-------+--------+
                                                               |
                          +--------------+                     |
+-----------+    :37515   | nixcache-    |  OCI blob fetch ----+
| Nix client| ---------- | proxy        |
|           |  narinfo    |              |  cache.nixos.org
|           |  (instant!) |  fallback ---| ----------------
+-----------+  + nar      +--------------+  (upstream paths)
```

### Key design decisions

- **narinfo served from local index**: The proxy caches the entire index in memory. narinfo lookups are instant — no network round-trip.
- **NARs as OCI blobs**: Each NAR is content-addressed by sha256 digest, matching OCI's native addressing. No naming conflicts, free dedup.
- **No sharding**: OCI repos have no blob count limit, so the entire complexity of sharding is eliminated.
- **Upstream filtering**: Only locally-built paths are uploaded. The proxy falls back to cache.nixos.org for everything else.

## Limitations

- **Proxy required**: GHCR URLs don't match Nix's expected cache URL scheme.
- **API rate limits**: 5,000 req/hour authenticated. Mitigated by local caching.
- **Private repos**: Bandwidth is metered (1 GB/month free). Public repos are free.
- **GitHub dependency**: If GHCR is down, cached paths are unavailable (upstream fallback still works).

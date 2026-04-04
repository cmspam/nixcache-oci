# nixcache-oci

Turn any GitHub repository into a Nix binary cache. Push your flake, get a cache. Free for public repos.

Uses GitHub Container Registry (GHCR) as a storage backend — NARs are stored as OCI blobs with a single index manifest for instant lookups. No external servers, CDNs, or databases required.

## How it works

1. Put your flake configuration in `config/` with any packages, NixOS hosts, or dev shells.

2. **GitHub Actions** builds everything, determines which store paths are already available on cache.nixos.org, and pushes only the locally-built NARs to GHCR as content-addressed OCI blobs.

3. A **local proxy** serves narinfo from a cached index (zero-latency lookups) and fetches NAR blobs from GHCR on demand. Paths available on upstream caches are served transparently from there.

4. **Automated updates**: a weekly workflow runs `nix flake update`, rebuilds, and caches new packages so your systems stay current.

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

2. Push to `main`. The workflow auto-discovers all outputs, builds them, and uploads only what's not already on cache.nixos.org.

3. Optionally set `NIX_SIGNING_KEY` secret for persistent cache signing:
   ```bash
   nix-store --generate-binary-cache-key my-cache-1 signing-key signing-key.pub
   # Add contents of signing-key as the NIX_SIGNING_KEY repo secret
   ```

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

### Output auto-discovery

The workflow automatically finds and builds all outputs from `config/flake.nix`:
- `packages.<system>.<name>` -- all packages for the runner's architecture
- `nixosConfigurations.<hostname>` -- builds `config.system.build.toplevel` for each host
- `devShells.<system>.<name>` -- all development shells

### What gets cached

Only store paths that were **actually built locally** by the CI runner. Paths already available on upstream caches (cache.nixos.org) are skipped during upload. The proxy transparently serves those from upstream, so clients get a complete substitutable view without wasting storage.

### Why OCI / GHCR

- **Content-addressed by design** -- NAR sha256 digests map naturally to OCI blob digests. Deduplication is free.
- **No blob count limits** -- store as many paths as you need without worrying about partitioning.
- **Unlimited storage and bandwidth** for public packages on GHCR.
- **Single index manifest** -- all narinfo data lives in one blob, so the proxy can serve lookups from memory with no network round-trip.
- **~10 GiB per blob** -- large packages that exceed typical file hosting limits work fine.

### Garbage collection

The `gc-cache.yml` workflow runs weekly and removes cache entries that are:
- Not in the current flake output closure
- Older than the retention period (default 30 days)

Run manually with `gh workflow run gc-cache.yml`.

## Limitations

- **Proxy required**: Clients need to run the local proxy since GHCR's OCI API doesn't match Nix's binary cache URL scheme.
- **API rate limits**: 5,000 requests/hour for authenticated users. Mitigated by serving narinfo from the local index and disk-caching downloaded NARs.
- **Private repos**: Storage and bandwidth are metered beyond the free tier (500 MB storage, 1 GB/month bandwidth). Public repos are completely free.
- **GitHub dependency**: If GHCR is down, cached paths are unavailable (upstream fallback to cache.nixos.org still works for non-custom packages).

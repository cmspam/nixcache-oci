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

3. Set up signing (see [Signing](#signing) below), or disable it for quick testing.

### Signing

Signing is optional but recommended. It lets Nix verify that packages haven't been tampered with.

#### Without signing (quick start)

If you don't set a `NIX_SIGNING_KEY` secret, the cache works but packages are unsigned. Clients must disable signature verification:

**NixOS module:**
```nix
services.nixcache-proxy = {
  enable = true;
  requireSignatures = false;
};
```

**Manual nix.conf:**
```ini
extra-substituters = http://localhost:37515
extra-trusted-substituters = http://localhost:37515
require-sigs = false
```

This is fine for personal use or testing, but not recommended for shared or production caches.

#### With signing (recommended)

**Step 1 — Generate a key pair** (do this once, on any machine):
```bash
nix-store --generate-binary-cache-key my-cache-1 secret.key public.key
```

This creates two files:
- `secret.key` — the private signing key (keep this secret)
- `public.key` — contains a string like `my-cache-1:BASE64...=` (give this to clients)

**Step 2 — Store the private key** as a GitHub Actions secret:

Go to your repo's **Settings > Secrets and variables > Actions**, create a secret named `NIX_SIGNING_KEY`, and paste the contents of `secret.key`.

**Step 3 — Give the public key to clients.** Open `public.key` and copy the string. It looks like:
```
my-cache-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
```

Clients need this string to verify signatures. Three ways to provide it:

**NixOS module:**
```nix
services.nixcache-proxy = {
  enable = true;
  publicKey = "my-cache-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
};
```

**Manual nix.conf:**
```ini
extra-substituters = http://localhost:37515
extra-trusted-substituters = http://localhost:37515
extra-trusted-public-keys = my-cache-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
```

**Auto-discovery** (for scripts): the proxy serves the public key at `http://localhost:37515/public-key` if one was configured during publishing.

### Automated updates

The `update-and-cache` workflow runs weekly to:
1. `nix flake update` in `config/`
2. Commit the new `flake.lock`
3. Rebuild and cache any new packages

Trigger manually anytime: `gh workflow run update-and-cache.yml`

### Consuming (client)

**Option A — Run the proxy manually:**
```bash
nix run github:cmspam/nixcache-oci#cache-proxy &
```
Then configure Nix (see [Signing](#signing) above for what to put in nix.conf).

**Option B — NixOS module (persistent, recommended):**
```nix
{
  inputs.nixcache.url = "github:cmspam/nixcache-oci";
  outputs = { nixcache, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixcache.nixosModules.default
        {
          services.nixcache-proxy = {
            enable = true;
            # With signing:
            publicKey = "my-cache-1:BASE64KEY...=";
            # Or without signing:
            # requireSignatures = false;
          };
        }
      ];
    };
  };
}
```

This starts the proxy as a systemd service and configures Nix's substituters and trusted keys automatically.

### Proxy configuration

| Variable | Default | Description |
|---|---|---|
| `NIXCACHE_REPO` | `cmspam/nixcache-oci` | GitHub owner/repo |
| `NIXCACHE_PORT` | `37515` | Local port |
| `NIXCACHE_UPSTREAM` | `https://cache.nixos.org` | Upstream cache URLs (space-separated) |
| `GITHUB_TOKEN` | (none) | Token for private repos |
| `NIXCACHE_INDEX_TTL` | `300` | Index refresh interval (seconds) |

### How the proxy works

The proxy only caches one thing: the **index** (all narinfo data). It's held in memory and refreshed from GHCR every `NIXCACHE_INDEX_TTL` seconds (default 5 minutes). narinfo lookups are instant — no network calls. After a new publish, clients see new packages within this window.

**NAR blobs are streamed directly** from GHCR (or upstream caches) to Nix in 64 KB chunks. Nothing is buffered into memory or written to disk — the proxy is just a pass-through. Nix stores the data in `/nix/store/` as usual. This means the proxy uses minimal memory and zero disk space beyond the small index file.

### Proxy management endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/_status` | GET | Index entries, config, upstream caches |
| `/_refresh` | POST | Force immediate index refresh (don't wait for TTL) |
| `/public-key` | GET | Cache signing public key (if configured) |

```bash
# Check status
curl http://localhost:37515/_status

# Force refresh after a publish
curl -X POST http://localhost:37515/_refresh
```

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

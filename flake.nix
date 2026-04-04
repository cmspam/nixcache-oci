{
  description = "nixcache-oci: Self-hosted Nix binary cache via GHCR (OCI registry)";

  nixConfig = {
    extra-substituters = [ "http://localhost:37515" ];
    extra-trusted-public-keys = [ ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
  in {

    packages = forAllSystems (system:
    let pkgs = nixpkgs.legacyPackages.${system};
    in {
      cache-proxy = pkgs.stdenv.mkDerivation {
        pname = "nixcache-proxy";
        version = "0.1.0";
        src = ./proxy;
        nativeBuildInputs = [ pkgs.python3 ];
        installPhase = ''
          mkdir -p $out/bin
          cp main.py $out/bin/nixcache-proxy
          chmod +x $out/bin/nixcache-proxy
          patchShebangs $out/bin/nixcache-proxy
        '';
      };
    });

    apps = forAllSystems (system: {
      cache-proxy = {
        type = "app";
        program = "${self.packages.${system}.cache-proxy}/bin/nixcache-proxy";
      };
    });

    nixosModules.default = { config, pkgs, lib, ... }:
    let cfg = config.services.nixcache-proxy;
    in {
      options.services.nixcache-proxy = {
        enable = lib.mkEnableOption "nixcache-proxy OCI substituter bridge";
        repo = lib.mkOption {
          type = lib.types.str;
          default = "cmspam/nixcache-oci";
          description = "GitHub owner/repo hosting the OCI cache.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 37515;
          description = "Local port the proxy listens on.";
        };
      };

      config = lib.mkIf cfg.enable {
        systemd.services.nixcache-proxy = {
          description = "Nix binary cache proxy for GHCR";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          environment = {
            NIXCACHE_REPO = cfg.repo;
            NIXCACHE_PORT = toString cfg.port;
          };
          serviceConfig = {
            ExecStart = "${self.packages.${pkgs.system}.cache-proxy}/bin/nixcache-proxy";
            Restart = "on-failure";
            DynamicUser = true;
            CacheDirectory = "nixcache-proxy";
          };
        };
        nix.settings.substituters = [ "http://localhost:${toString cfg.port}" ];
      };
    };
  };
}

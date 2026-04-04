{
  description = "User configuration — add your packages and NixOS hosts here";

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
      default = pkgs.hello;

      # Custom package that won't be on cache.nixos.org
      nixcache-test = pkgs.writeShellScriptBin "nixcache-test" ''
        echo "Hello from nixcache-oci! Cache is working."
        echo "Built at: 2026-04-05"
      '';
    });

    # nixosConfigurations.my-host = nixpkgs.lib.nixosSystem { ... };
  };
}

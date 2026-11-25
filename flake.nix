{
  description = "crapper: CRAP scores for Clojure, Java, Go, TypeScript, Rust, and Python";

  inputs = {
    # nixos-unstable (26.11) dropped x86_64-darwin support; nixos-26.05 is the
    # current stable branch that still builds for it (security fixes through
    # end of 2026), so it's used here to keep all four systems buildable.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      uv2nix,
      pyproject-nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

      forAllSystems = f: lib.genAttrs systems (system: f system);

      mkPkgs = system: nixpkgs.legacyPackages.${system};

      # tree-sitter-language-pack only ships macOS wheels tagged macosx_15_0,
      # but nixpkgs pins darwinSdkVersion to 14.4; this is a pure metadata bump
      # (no SDK/toolchain rebuild) so pyproject-nix accepts the prebuilt wheel
      # instead of falling back to a from-source build that needs maturin/Rust.
      mkStdenv =
        pkgs:
        if pkgs.stdenv.hostPlatform.isDarwin then
          pkgs.stdenv
          // {
            buildPlatform = pkgs.stdenv.buildPlatform // { darwinSdkVersion = "15.0"; };
            hostPlatform = pkgs.stdenv.hostPlatform // { darwinSdkVersion = "15.0"; };
            targetPlatform = pkgs.stdenv.targetPlatform // { darwinSdkVersion = "15.0"; };
          }
        else
          pkgs.stdenv;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;

          python = pkgs.python312;

          pythonSet =
            (pkgs.callPackage pyproject-nix.build.packages {
              inherit python;
              stdenv = mkStdenv pkgs;
            }).overrideScope
              (
                lib.composeManyExtensions [
                  pyproject-build-systems.overlays.default
                  overlay
                ]
              );

          venv = pythonSet.mkVirtualEnv "crapper-env" workspace.deps.default;
        in
        {
          default = pkgs.writeShellApplication {
            name = "crapper";
            runtimeInputs = [ venv ];
            text = ''
              exec "${venv}/bin/crapper" "$@"
            '';
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/crapper";
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;

          python = pkgs.python312;

          pythonSet =
            (pkgs.callPackage pyproject-nix.build.packages {
              inherit python;
              stdenv = mkStdenv pkgs;
            }).overrideScope
              (
                lib.composeManyExtensions [
                  pyproject-build-systems.overlays.default
                  overlay
                ]
              );

          venv = pythonSet.mkVirtualEnv "crapper-dev-env" workspace.deps.all;
        in
        {
          default = pkgs.mkShell {
            packages = [ venv pkgs.uv ];
            shellHook = ''
              export UV_NO_SYNC=1
            '';
          };
        }
      );
    };
}

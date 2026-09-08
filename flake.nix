{
  description = "Nix overlay for Mistral Vibe - CLI coding agent by Mistral AI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mistral-vibe-src = {
      url = "github:mistralai/mistral-vibe";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, pyproject-nix, uv2nix, pyproject-build-systems, mistral-vibe-src }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkMistralVibe = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

          # WORKAROUND: upstream's pyproject.toml has declared [[tool.uv.index]]
          # before [tool.uv] since v2.24.3 (mistralai/mistral-vibe@a84be03),
          # still unfixed as of v2.25.0. Nix's fromTOML rejects that ordering
          # as "table defined twice", so loadWorkspace can't read the file
          # as-is. Swap the two blocks back to the order that parses; drop
          # this once upstream reorders them.
          mistral-vibe-src-patched = pkgs.runCommand "mistral-vibe-src-patched" {
            nativeBuildInputs = [ pkgs.python3 ];
          } ''
            cp -r ${mistral-vibe-src} $out
            chmod -R u+w $out
            python3 ${./fix-pyproject-toml-order.py} "$out/pyproject.toml"
          '';

          # Load workspace from upstream source
          workspace = uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = mistral-vibe-src-patched;
          };

          # Use Python 3.12 (minimum required version)
          python = pkgs.python312;

          # Create base Python package set
          pythonBase = pkgs.callPackage pyproject-nix.build.packages {
            inherit python;
          };

          # Generate overlay from uv.lock
          uvOverlay = workspace.mkPyprojectOverlay {
            sourcePreference = "wheel";
          };

          # Custom overrides for packages that need special handling
          customOverrides = final: prev: {
            # tree-sitter packages may need native dependencies
            tree-sitter = prev.tree-sitter.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                pkgs.tree-sitter
              ];
            });

            # WORKAROUND: proot (Termux) does not support fchmodat(AT_FDCWD,"",AT_EMPTY_PATH),
            # causing GNU coreutils cp to fail with ENOENT when copying the source directory.
            # Use tar instead of cp for the unpackPhase. Safe on all platforms.
            mistral-vibe = prev.mistral-vibe.overrideAttrs (_: {
              unpackPhase = ''
                runHook preUnpack
                mkdir source
                tar cf - -C "$src" . | tar xf - -C source
                chmod -R u+w source
                sourceRoot="source"
                runHook postUnpack
              '';
            });
          };

          # Compose all overlays into final Python set
          pythonSet = pythonBase.overrideScope (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.default
              uvOverlay
              customOverrides
            ]
          );

          # Build virtual environment with all dependencies
          venv = pythonSet.mkVirtualEnv "mistral-vibe-env" workspace.deps.default;

        in
        pkgs.stdenv.mkDerivation {
          pname = "mistral-vibe";
          version = "1.3.5";

          dontUnpack = true;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # Runtime dependencies
          buildInputs = [
            pkgs.ripgrep  # Used for code search
            pkgs.git      # Used for version control operations
          ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin

            # Link vibe executables
            for exe in vibe vibe-acp; do
              if [ -f "${venv}/bin/$exe" ]; then
                makeWrapper "${venv}/bin/$exe" "$out/bin/$exe" \
                  --prefix PATH : ${lib.makeBinPath [ pkgs.ripgrep pkgs.git ]}
              fi
            done

            runHook postInstall
          '';

          meta = with lib; {
            description = "Minimal CLI coding agent by Mistral AI";
            homepage = "https://github.com/mistralai/mistral-vibe";
            license = licenses.asl20;
            maintainers = [ ];
            platforms = supportedSystems;
            mainProgram = "vibe";
          };
        };

    in
    {
      # Overlay for use in other flakes
      overlays.default = final: prev: {
        mistral-vibe = mkMistralVibe prev.stdenv.hostPlatform.system;
      };

      # Direct packages for each system
      packages = forAllSystems (system: {
        default = mkMistralVibe system;
        mistral-vibe = mkMistralVibe system;
      });

      # Development shell
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              (mkMistralVibe system)
              pkgs.uv
            ];
          };
        }
      );
    };
}

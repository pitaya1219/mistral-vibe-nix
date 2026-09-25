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

      # The harness extension compiles the `v8` crate (pulled in by deno_core),
      # whose build script downloads a prebuilt static library from the rusty_v8
      # GitHub release at build time unless RUSTY_V8_ARCHIVE points at a local
      # copy. deno_core enables only the `simdutf` feature of v8, which is what
      # selects the archive name (see prebuilt_features_suffix in the v8 build
      # script).
      rustyV8Archives = {
        "x86_64-linux" = "librusty_v8_simdutf_release_x86_64-unknown-linux-gnu.a.gz";
        "aarch64-linux" = "librusty_v8_simdutf_release_aarch64-unknown-linux-gnu.a.gz";
        "x86_64-darwin" = "librusty_v8_simdutf_release_x86_64-apple-darwin.a.gz";
        "aarch64-darwin" = "librusty_v8_simdutf_release_aarch64-apple-darwin.a.gz";
      };

      mkMistralVibe = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

          # WORKAROUND: upstream's pyproject.toml has declared [[tool.uv.index]]
          # before [tool.uv] since v2.24.3 (mistralai/mistral-vibe@a84be03),
          # still unfixed as of v2.25.8. Nix's fromTOML rejects that ordering
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

          # Since v2.25.8 the wheel is produced by a custom maturin backend
          # (build_backend/maturin_backend.py) that compiles two Rust artifacts
          # inside the build: the vibe-rs TUI with plain `cargo build`, and the
          # pyo3 harness extension with `maturin build_wheel`. Both cargo runs
          # are offline in the Nix sandbox, so every crate from both
          # Cargo.lock files has to be vendored. rustPlatform.fetchCargoVendor
          # vendors one lockfile per call; its crate directories are
          # version-suffixed, so the union of the two serves both builds from
          # a single crates-io source replacement.
          cargoVendor = pkgs.runCommand "mistral-vibe-cargo-vendor" {
            cliDeps = pkgs.rustPlatform.fetchCargoVendor {
              name = "mistral-vibe-cli-rust-deps";
              src = mistral-vibe-src-patched;
              cargoRoot = "vibe/cli-rust";
              hash = "sha256-LGEjJuTBdoUR83Q5UeNKahJTwkxQIm8S9d+l/KDKpnc=";
            };
            harnessDeps = pkgs.rustPlatform.fetchCargoVendor {
              name = "mistral-vibe-harness-core-deps";
              src = mistral-vibe-src-patched;
              cargoRoot = "harness/core";
              hash = "sha256-3ykvTIESFANShoj3gFYw+vDoJCETOft0xYKCgpn2Iy0=";
            };
          } ''
            mkdir -p $out/.cargo $out/source-registry-0
            cp -rn $cliDeps/source-registry-0/. $out/source-registry-0/
            cp -rn $harnessDeps/source-registry-0/. $out/source-registry-0/
            # Both lockfiles use only the crates.io registry, so either
            # config.toml works; it just has to point at the merged directory.
            cp $cliDeps/.cargo/config.toml $out/.cargo/config.toml
          '';

          # Prebuilt rusty_v8 static library for the harness build; handed to
          # the v8 crate through RUSTY_V8_ARCHIVE below.
          rustyV8Archive = pkgs.fetchurl {
            url = "https://github.com/denoland/rusty_v8/releases/download/v150.3.0/${rustyV8Archives.${system}}";
            hash = "sha256-2wl+bvpVp14L3oayuhl5g9CpG76DAfRVDEkNecB9evA=";
          };

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
            mistral-vibe = prev.mistral-vibe.overrideAttrs (oldAttrs: {
              unpackPhase = ''
                runHook preUnpack
                mkdir source
                tar cf - -C "$src" . | tar xf - -C source
                chmod -R u+w source
                sourceRoot="source"
                runHook postUnpack
              '';

              # Toolchain for the backend's two cargo builds; maturin itself
              # comes in through [build-system].requires. On Linux the backend
              # forces maturin's --zig mode for the manylinux_2_28 wheel:
              # cargo-zigbuild looks for `python -m ziglang` first and falls
              # back to a plain `zig` on PATH, so pkgs.zig covers it (nixpkgs
              # ships zig 0.16.0, matching the ziglang==0.16.0 the backend
              # otherwise asks for dynamically).
              nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [
                pkgs.cargo
                pkgs.rustc
              ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.zig
              ];

              # The TUI's default features include `voice`, whose cpal
              # dependency links ALSA via pkg-config. Upstream's release CI
              # builds the wheel with `--no-default-features`, and the backend
              # appends CARGO_BUILD_FLAGS to its `cargo build` invocation.
              CARGO_BUILD_FLAGS = "--no-default-features";

              preBuild = ''
                # Point both cargo runs (the vibe-rs TUI and maturin's harness
                # build) at the vendored crates, the same way
                # rustPlatform.cargoSetupHook consumes a fetchCargoVendor
                # output: substitute the @vendor@ placeholder in its config
                # with the store path of the vendor directory. The config sits
                # in the source root, so it also covers the harness copy the
                # backend stages into .native-build before maturin runs.
                mkdir -p .cargo
                substitute ${cargoVendor}/.cargo/config.toml .cargo/config.toml \
                  --subst-var-by vendor ${cargoVendor}

                # Writable scratch state for cargo, and for cargo-zigbuild's
                # cache ($HOME is read-only in the sandbox).
                export CARGO_HOME="$PWD/.cargo-home"
                mkdir -p "$CARGO_HOME"
                export XDG_CACHE_HOME="$PWD/.cache"
                mkdir -p "$XDG_CACHE_HOME"

                # The v8 crate would otherwise download this at build time.
                export RUSTY_V8_ARCHIVE="${rustyV8Archive}"
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
                  --prefix PATH : ${lib.makeBinPath [ pkgs.ripgrep pkgs.git ]} \
                  --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath (lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.libgcc ])}
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

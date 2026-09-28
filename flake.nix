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
      # The harness extension compiles the `v8` crate (pulled in by deno_core),
      # whose build script downloads a prebuilt static library from the rusty_v8
      # GitHub release at build time unless RUSTY_V8_ARCHIVE points at a local
      # copy. The name it would have fetched is assembled from the crate's own
      # version, the target triple, the profile, and the features deno_core
      # enables -- only `simdutf` (see static_lib_url and
      # prebuilt_features_suffix in the v8 build script). Every part of that but
      # the target triple is fixed here, so the pin is a per-system archive and
      # nothing else.
      # What the crate itself would have fetched. RUSTY_V8_ARCHIVE is returned
      # verbatim by static_lib_url() without any comparison against
      # CARGO_PKG_VERSION, so archives left behind by an upstream bump are
      # accepted and linked: the fetch still succeeds, because its URL and hash
      # agree with each other and only disagree with the crate. Reading the
      # wanted version out of the lockfile is what makes that drift visible.
      lockedV8Version =
        let
          lock = builtins.fromTOML
            (builtins.readFile "${mistral-vibe-src}/harness/core/Cargo.lock");
          v8 = builtins.filter (pkg: pkg.name == "v8") lock.package;
        in
        if v8 == [ ] then
          throw ("No v8 crate in harness/core/Cargo.lock, so the rusty_v8 pin "
            + "in rusty-v8.nix has nothing to track. Has the harness stopped "
            + "using deno_core?")
        else (builtins.head v8).version;

      # Asserted here rather than at the fetch so that reading the pin at all
      # trips it -- supportedSystems below forces this, which every output of
      # the flake goes through, so a stale pin fails on every system at once
      # instead of surfacing as a link error on whichever one is built first.
      rustyV8 =
        let pinned = import ./rusty-v8.nix;
        in
        assert nixpkgs.lib.assertMsg (pinned.version == lockedV8Version) ''
          rusty-v8.nix pins the prebuilt archives for v8 ${pinned.version}, but
          harness/core/Cargo.lock now wants v8 ${lockedV8Version}; the pinned
          archives would link the wrong V8.

          Run ./update-rusty-v8.py and commit the result.
        '';
        pinned;

      # Each supported system needs a pinned archive, so the two lists are one.
      supportedSystems = builtins.attrNames rustyV8.targets;

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkMistralVibe = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

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
              src = mistral-vibe-src;
              cargoRoot = "vibe/cli-rust";
              hash = "sha256-LGEjJuTBdoUR83Q5UeNKahJTwkxQIm8S9d+l/KDKpnc=";
            };
            harnessDeps = pkgs.rustPlatform.fetchCargoVendor {
              name = "mistral-vibe-harness-core-deps";
              src = mistral-vibe-src;
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
            url = "https://github.com/denoland/rusty_v8/releases/download/"
              + "v${rustyV8.version}/librusty_v8_simdutf_release_"
              + "${rustyV8.targets.${system}}.a.gz";
            hash = rustyV8.hashes.${system};
          };

          # Load workspace from upstream source
          workspace = uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = mistral-vibe-src;
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

            mistral-vibe = prev.mistral-vibe.overrideAttrs (oldAttrs: {
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
          version = "2.25.8";

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

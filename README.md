# mistral-vibe-nix

Nix flake overlay for [Mistral Vibe](https://github.com/mistralai/mistral-vibe) - Minimal CLI coding agent by Mistral AI.

## Usage

### Direct Installation

```bash
# Run without installing
nix run github:YOUR_USERNAME/mistral-vibe-nix

# Install to profile
nix profile install github:YOUR_USERNAME/mistral-vibe-nix
```

### As Flake Input

Add to your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    mistral-vibe.url = "github:YOUR_USERNAME/mistral-vibe-nix";
  };

  outputs = { self, nixpkgs, mistral-vibe, ... }: {
    # Option 1: Use overlay
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [{
        nixpkgs.overlays = [ mistral-vibe.overlays.default ];
        environment.systemPackages = [ pkgs.mistral-vibe ];
      }];
    };

    # Option 2: Use package directly
    homeConfigurations.myuser = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [{
        home.packages = [ mistral-vibe.packages.x86_64-linux.default ];
      }];
    };
  };
}
```

### With Home Manager (in this dotfiles repo)

```nix
# In your profile, e.g., profiles/lepetitprince.nix
{ nixpkgs, home-manager, overlays, mistral-vibe }:

{
  mkHomeConfiguration = home-manager.lib.homeManagerConfiguration {
    pkgs = import nixpkgs {
      system = "x86_64-linux";
      overlays = [
        overlays.neovim-nightly
        mistral-vibe.overlays.default
      ];
    };
    modules = [{
      home.packages = [ pkgs.mistral-vibe ];
    }];
  };
}
```

## Building Locally

```bash
cd packages/mistral-vibe

# Update dependencies
nix flake update

# Build
nix build

# Run
nix run
```

## Configuration

After installation, configure your Mistral API key:

```bash
# Set API key (will be stored in ~/.vibe/.env)
export MISTRAL_API_KEY="your-api-key"
vibe
```

Or create `~/.vibe/config.toml`:

```toml
[api]
key = "your-api-key"
```

## Supported Platforms

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

## Version

Current version: **1.3.5**

## License

Apache-2.0 (same as upstream mistral-vibe)

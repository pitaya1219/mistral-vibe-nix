#!/usr/bin/env python3
"""Regenerate the hashes in cargo-vendor.nix for the current mistral-vibe-src.

Each entry is built with a fake hash against the flake's own pin of
mistral-vibe-src, and the hash Nix reports as `got:` is written back. This is
the other half of the fixed-output derivations in flake.nix, which fail with a
hash mismatch as soon as a flake.lock bump changes a Cargo.lock.

Exits 0 whether or not anything changed; `--check` exits 1 on a difference
instead of writing, for a CI job that only wants to know.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent
PIN = REPO / "cargo-vendor.nix"

FAKE_HASH = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# Same resolution as update-rusty-v8.py: the flake path is spelled out so the
# source is the one flake.nix sees, whatever the caller's working directory.
VENDOR_EXPR = """
let
  flake = builtins.getFlake "%s";
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
in pkgs.rustPlatform.fetchCargoVendor {
  name = "%s";
  src = flake.inputs.mistral-vibe-src;
  cargoRoot = "%s";
  hash = "%s";
}
"""


def run(*argv: str) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True)


def vendor_hash(name: str, cargo_root: str) -> str:
    expr = VENDOR_EXPR % (REPO, name, cargo_root, FAKE_HASH)
    done = run(
        "nix", "build", "--no-link", "--impure", "--no-write-lock-file",
        "--expr", expr,
    )
    got = re.search(r"got:\s+(sha256-\S+)", done.stderr)
    if not got:
        sys.exit(f"could not read a hash for {name}:\n{done.stderr.strip()}")
    return got.group(1)


def render(entries: dict) -> str:
    def block(key: str, entry: dict) -> str:
        return (
            f"  {key} = {{\n"
            f'    name = "{entry["name"]}";\n'
            f'    cargoRoot = "{entry["cargoRoot"]}";\n'
            f'    hash = "{entry["hash"]}";\n'
            f"  }};\n"
        )

    header = "".join(PIN.read_text().partition("{\n")[0])
    return header + "{\n" + "\n".join(block(k, entries[k]) for k in entries) + "}\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--check",
        action="store_true",
        help="report drift and exit 1 instead of rewriting the pin",
    )
    args = ap.parse_args()

    pinned = json.loads(
        run("nix", "eval", "--json", "--file", str(PIN), "--no-write-lock-file").stdout
    )
    updated = {
        key: {**entry, "hash": vendor_hash(entry["name"], entry["cargoRoot"])}
        for key, entry in pinned.items()
    }

    changed = {k: (pinned[k]["hash"], updated[k]["hash"]) for k in pinned if pinned[k]["hash"] != updated[k]["hash"]}
    if not changed:
        print("cargo-vendor.nix is current.")
        return 0

    for key, (was, now) in changed.items():
        print(f"  {key}: {was} -> {now}")

    if args.check:
        print("\ncargo-vendor.nix is stale; run without --check to rewrite it.", file=sys.stderr)
        return 1

    PIN.write_text(render(updated))
    print(f"\nwrote {PIN.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

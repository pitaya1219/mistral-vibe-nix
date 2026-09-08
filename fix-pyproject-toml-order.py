#!/usr/bin/env python3
"""Swap [tool.uv] and [[tool.uv.index]] into the order Nix's fromTOML accepts.

Once [[tool.uv.index]] appears in the file, "tool.uv" is implicitly created.
A [tool.uv] header appearing anywhere after that trips Nix's strict TOML
parser ("table defined twice"), even though other unrelated tables sit
between the two blocks. No-op if the file is already in the working order.
"""
import sys


def block_end(lines, start):
    end = start + 1
    while end < len(lines) and not lines[end].startswith("["):
        end += 1
    return end


def main(path):
    with open(path) as f:
        lines = f.readlines()

    try:
        idx_a = lines.index("[[tool.uv.index]]\n")
        idx_b = lines.index("[tool.uv]\n")
    except ValueError:
        return  # Nothing to fix; leave the file untouched.

    if idx_a > idx_b:
        return  # Already in the order Nix accepts.

    end_a = block_end(lines, idx_a)
    end_b = block_end(lines, idx_b)

    new_lines = (
        lines[:idx_a]
        + lines[idx_b:end_b]
        + lines[end_a:idx_b]
        + lines[idx_a:end_a]
        + lines[end_b:]
    )

    with open(path, "w") as f:
        f.writelines(new_lines)


if __name__ == "__main__":
    main(sys.argv[1])

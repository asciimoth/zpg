run:
    zig build run

check:
    zig fmt --check build.zig src/main.zig
    zig build

fmt:
    zig fmt build.zig src/main.zig
    nixfmt flake.nix
    just --fmt

hooks:
    pre-commit run --all-files

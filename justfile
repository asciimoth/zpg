[positional-arguments]
run *args:
    zig build
    ./zig-out/bin/zpg "$@"

demo:
    zig build
    PATH="./zig-out/bin:$PATH" zpg zpg --mock

check:
    zig fmt --check build.zig src test/fixtures/probe.zig
    zig build
    zig build test

fmt:
    zig fmt build.zig src test/fixtures/probe.zig
    nixfmt flake.nix
    just --fmt

hooks:
    pre-commit run --all-files

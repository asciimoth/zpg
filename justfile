[positional-arguments]
run *args:
    zig build
    ./zig-out/bin/zpg "$@"

demo:
    zig build
    PATH="./zig-out/bin:$PATH" zpg zpg --mock

check: typos
    zig fmt --check build.zig src test/fixtures
    zig build
    zig build test

typos:
    typos

fmt:
    zig fmt build.zig src test/fixtures
    nixfmt flake.nix
    just --fmt

hooks:
    pre-commit run --all-files

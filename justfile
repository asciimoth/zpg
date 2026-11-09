set dotenv-load

[positional-arguments]
run *args:
    zig build
    ./zig-out/bin/zpg "$@"

demo:
    zig build
    PATH="./zig-out/bin:$PATH" zpg zpg --mock

vhs:
    zig build
    PATH="./zig-out/bin:$PATH" vhs demo.tape

demo-test:
    zig build
    PATH="./zig-out/bin:$PATH" zpg --test zpg --mock

demo-report:
    zig build
    PATH="./zig-out/bin:$PATH" zpg --name "shell demo" sh examples/report-demo.sh

package:
    @goreleaser --version | awk '$1 == "GitVersion:" { split($2, v, "."); ok = v[1] > 2 || (v[1] == 2 && v[2] >= 19) } END { if (!ok) { print "GoReleaser 2.19 or newer is required" > "/dev/stderr"; exit 1 } }'
    goreleaser check
    env -u GITHUB_TOKEN goreleaser release --snapshot --clean
    python3 tools/package_artifacts.py

# Build and publish a versioned GitHub release. Add DEB/RPM packages to ghrepo when configured.
[positional-arguments]
release *args:
    ./scripts/release.sh "$@"

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

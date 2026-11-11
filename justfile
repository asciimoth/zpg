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

# Copy one file with delayed reads (Linux, strace).
demo-cp: (_demo-guess "cp")

# Copy three files in parallel to show a tree (Linux, strace).
demo-cp-parallel: (_demo-guess "cp-parallel")

# Extract an archive with delayed reads (Linux, strace).
demo-tar: (_demo-guess "tar")

# Compress a file with delayed reads (Linux, strace).
demo-gzip: (_demo-guess "gzip")

# Copy a directory with an rsync bandwidth limit (Linux).
demo-rsync: (_demo-guess "rsync")

# Download from a slow local HTTP server (Linux).
demo-curl: (_demo-guess "curl")

# Clone a temporary Git repository over slow local HTTP (Linux).
demo-git: (_demo-guess "git")

# Transcode a generated video at its playback speed (Linux).
demo-ffmpeg: (_demo-guess "ffmpeg")

[private]
_demo-guess tool:
    zig build
    python3 scripts/guess-demo.py "{{ tool }}"

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

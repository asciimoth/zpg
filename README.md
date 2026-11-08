# zpg

Standalone [ZIG_PROGRESS][progress] supervisor.

[progress]: https://andrewkelley.me/post/zig-new-cli-progress-bar-explained.html

`zpg` runs one command and shows its stdout and stderr unchanged. If the
child reports Zig progress, `zpg` shows its progress tree in an interactive
terminal. It also works with commands that do not report progress.

Requires Zig 0.17.0 to build. Linux and macOS are supported.

```sh
zig build
./zig-out/bin/zpg --name worker ./worker --flag value
./zig-out/bin/zpg --renderer tree ./worker
./zig-out/bin/zpg --no-progress ./worker
```

Use `zpg [options] <command> [args...]`.
The name sets the progress node label and defaults to the command's basename.
Flags after the
command go to the child unchanged. Use `--` before a command name that starts
with a hyphen.
Commands use normal PATH lookup; no shell is started. Use `--help` for usage.

Child stdin is closed. Child stdout and stderr are separate pipes, so the child
does not see a terminal on either stream. Both streams go to `zpg`'s stderr
without prefixes or added newlines. Partial lines and long lines pass through
as they arrive. Order is preserved within each stream. Output from the two
streams can interleave, including within a line.

Zig-aware children connect through the standard library's progress mechanism.
Shell scripts can use `zpg --report COMPLETED TOTAL` to send an update through
the same pipe. For example, run this script with `zpg --name build sh build.sh`:

```sh
#!/bin/sh
set -e
zpg --report 0 2
compile_assets
zpg --report 1 2
compile_code
zpg --report 2 2
```

Each call sets absolute counts and exits without output. The parent keeps the
last update until the next report or until the script exits. Use
`zpg --report 3 10 --name 'compile files'` to also change the node label. Without
`--name`, the report uses the supervisor's original node label. Use a total of
`0` when the total is unknown. Counts must be decimal integers from 0 to
4294967294.

Run `just demo-report` to see a [shell example](examples/report-demo.sh). It
starts three workers in parallel. Each worker reports four steps and writes
plain log lines. The main script reports its own three stages. `just demo`
continues to run the Zig mock workload.

Reports do nothing and return success when no `ZIG_PROGRESS` pipe is present.
Thus, the script also works without a supervisor, with `--no-progress`, or
with redirected output. Invalid arguments return 2; an invalid pipe or a
write failure returns 1. Keep `zpg` on PATH for scripts that use this command.
Reports share one node per supervised command: concurrent reports replace
each other. Use separate nested `zpg` commands for independent progress nodes.
Do not mix shell reports with another progress producer on the same pipe.

The default `bars` renderer shows a text bar, percentage, and item counts for
each node with a known total. Nodes with an unknown total show a spinner
and a completed count when available. For example:

```text
build [#########---] 75% 3/4
├─ assets [############] 100% 2/2
└─ code [######------] 50% 1/2
   └─ compile /
```

Bars stop at 100% if the completed count exceeds the estimate. The item count
still shows the reported value. Labels and tree depth are clipped to fit the
terminal. Control and Unicode format characters in progress labels are
replaced with `?`; child log bytes pass through unchanged.

Use `--renderer tree` for the standard Zig tree display. Use `just demo` to see
the default renderer, or `./zig-out/bin/zpg --renderer tree --mock` for the
standard display. The outermost `zpg` selects the renderer when commands are
nested.

Set bar and spinner styles with `--bar-style` and `--spinner-style`:

```sh
./zig-out/bin/zpg --bar-style block --spinner-style dots ./worker
./zig-out/bin/zpg --bar-style fira --spinner-style fira ./worker
UNICODE_PROGRESS_BAR=true ./zig-out/bin/zpg ./worker
./zig-out/bin/zpg --bar-style '█ ' --spinner-style '⠋⠙⠹⠸' --mock
./zig-out/bin/zpg --bar-style '(=.)' --spinner-style '.oO@' ./worker
```

Both options default to `ascii`. The `block` bar uses `█` for completed items
and spaces for remaining items, with no borders. The `dots` spinner uses
braille characters. For example, a half-complete node with the block style is:

```text
build ██████       50% 1/2
```

The `fira` presets use [Fira Code's dedicated progress characters][fira-progress].
The bar has separate empty and filled characters for its left end, middle,
and right end (U+EE00–U+EE05). Both ends are part of the 12 positions. The spinner
cycles through six frames (U+EE06–U+EE0B). These characters require Fira Code or
another terminal font that supports them.

Set `UNICODE_PROGRESS_BAR=true` to make `fira` the default for both styles.
Other values keep the `ascii` defaults. Each CLI style option overrides its
own default. For example, `--bar-style ascii` keeps the Fira Code spinner,
and `--bar-style ascii --spinner-style ascii` selects ASCII for both.

[fira-progress]: https://github.com/tonsky/FiraCode#whats-in-the-box

For a custom bar, supply two characters (filled, empty) or four characters
(left border, filled, empty, right border). Bars have 12 positions. For a custom
spinner, supply 1 to 64 characters in frame order. Each character must be one
UTF-8 codepoint; combined characters and multi-character frames are not
supported. Control and Unicode format characters are rejected. Quote values
that contain spaces or shell symbols. Block, braille, and Fira Code progress
characters use one column; other non-ASCII characters use a conservative
two-column estimate and can be clipped early.

Styles apply to the `bars` renderer, including `--mock`. The standard `tree`
renderer keeps its own style. For nested commands, set the style on the
outermost `zpg`.

The renderer clears the tree before each log write and redraws it after logs
scroll. It does not reserve a fixed footer. When stderr is redirected, logs
remain plain text. `--no-progress` or a terminal without ANSI support disables
the progress tree. The bars renderer uses no colors, including when `NO_COLOR`
is set.

The custom renderer uses snapshots from the linked Zig standard library to
keep child and grandchild progress collection unchanged. `src/progress.zig`
connects that snapshot stream to `src/renderer.zig`, which formats the tree.
The snapshot layout follows Zig 0.17.0 and must be checked when Zig is updated.

`zpg` returns the child's exit code without adding a status message. A child
killed by a signal returns `128 + signal`. CLI errors return 2; spawn or I/O
errors return 1. On SIGINT or SIGTERM, `zpg` asks the child process group to
stop, then sends SIGKILL after two seconds if needed. It reaps the direct
child. If a descendant keeps an output pipe open after the child exits, `zpg`
stops reading after two seconds and reports discarded output.

Child control bytes, including CR and ANSI escapes, pass through unchanged and
can affect the terminal display. Interactive stdin, full-screen applications,
and PTYs for children are not supported.

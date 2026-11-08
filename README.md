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
command go to the child unchanged.
Commands use normal PATH lookup; no shell is started. Use `--help` for usage.

Child stdin is closed. Child stdout and stderr are separate pipes, so the child
does not see a terminal on either stream. Both streams go to `zpg`'s stderr
without prefixes or added newlines. Partial lines and long lines pass through
as they arrive. Order is preserved within each stream. Output from the two
streams can interleave, including within a line.

Zig-aware children connect through the standard library's progress mechanism.
The default `bars` renderer shows a text bar, percentage, and item counts for
each node with a known total. Nodes with an unknown total show a spinner
and a completed count when available. For example:

```text
build [#########---] 75% 3/4
+- assets [############] 100% 2/2
`- code [######------] 50% 1/2
   `- compile /
```

Bars stop at 100% if the completed count exceeds the estimate. The item count
still shows the reported value. Labels and tree depth are clipped to fit the
terminal. Control bytes in progress labels are replaced with `?`; child log
bytes pass through unchanged.

Use `--renderer tree` for the standard Zig tree display. Use `just demo` to see
the default renderer, or `./zig-out/bin/zpg --renderer tree --mock` for the
standard display. The outermost `zpg` selects the renderer when commands are
nested.

Set bar and spinner styles with `--bar-style` and `--spinner-style`:

```sh
./zig-out/bin/zpg --bar-style block --spinner-style dots ./worker
./zig-out/bin/zpg --bar-style '█ ' --spinner-style '⠋⠙⠹⠸' --mock
./zig-out/bin/zpg --bar-style '(=.)' --spinner-style '.oO@' ./worker
```

Both options default to `ascii`. The `block` bar uses `█` for completed items
and spaces for remaining items, with no borders. The `dots` spinner uses
braille characters. For example, a half-complete node with the block style is:

```text
build ██████       50% 1/2
```

For a custom bar, supply two characters (filled, empty) or four characters
(left border, filled, empty, right border). Bars have 12 positions. For a custom
spinner, supply 1 to 64 characters in frame order. Each character must be one
UTF-8 codepoint; combined characters and multi-character frames are not
supported. Control characters are rejected. Quote values that contain spaces
or shell symbols. Block and braille characters use one column; other non-ASCII
characters use a conservative two-column estimate and can be clipped early.

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

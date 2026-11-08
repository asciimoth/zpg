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
./zig-out/bin/zpg --no-progress ./worker
```

Use `zpg [--name TEXT] [--no-progress] <command> [args...]`. The name sets the
progress node label and defaults to the command's basename. Flags after the
command go to the child unchanged.
Commands use normal PATH lookup; no shell is started. Use `--help` for usage.

Child stdin is closed. Child stdout and stderr are separate pipes, so the child
does not see a terminal on either stream. Both streams go to `zpg`'s stderr
without prefixes or added newlines. Partial lines and long lines pass through
as they arrive. Order is preserved within each stream. Output from the two
streams can interleave, including within a line.

Zig-aware children connect through the standard library's progress mechanism.
The renderer redraws progress after logs scroll; it does not reserve a fixed
footer. When stderr is redirected, logs remain plain text. `--no-progress`
disables the progress tree.

`zpg` returns the child's exit code without adding a status message. A child
killed by a signal returns `128 + signal`. CLI errors return 2; spawn or I/O
errors return 1. On SIGINT or SIGTERM, `zpg` asks the child process group to
stop, then sends SIGKILL after two seconds if needed. It reaps the direct
child. If a descendant keeps an output pipe open after the child exits, `zpg`
stops reading after two seconds and reports discarded output.

Child control bytes, including CR and ANSI escapes, pass through unchanged and
can affect the terminal display. Interactive stdin, full-screen applications,
and PTYs for children are not supported.

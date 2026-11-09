# zpg

`zpg` runs a command with a progress overlay.

[![Demo of zpg showing command output and progress](demo.gif)](https://asciinema.org/a/1271890)

## Usage

`zpg` supports Linux and macOS. Use Zig 0.17.0 to build it. Add `zig-out/bin`
to `PATH` before you run `zpg`:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
zpg --name build ./worker --flag value
zpg --guess cp large.iso /backup/
zpg --mock
```

`--mock` runs a fixed progress demo when stdin is empty. With input from a pipe
or file, it echoes each line after a short delay and shows input progress. The
demo preserves a final line without a newline:

```sh
printf 'one\ntwo\n' | zpg --mock
zpg --mock < input.txt
```

In the fixed demo, stdout logs are green when stdout is a terminal. Stderr logs
are red when stderr is a terminal. At the end, terminal stdout shows a bar
updated with `\r`. Terminal stderr shows a two-row footer updated with cursor
movement. Run `zpg zpg --mock` to check nested output.

Use `zpg [options] <command> [args...]`. Put `zpg` options before the command.
`zpg` passes arguments after the command to the command unchanged. It uses
`PATH` to find commands. To use shell syntax, run `zpg sh -c '...'`. If a
command name starts with a hyphen, put `--` before the name. Run `zpg --help`
for all options.

### Progress display

The default display shows bars, percentages, and counts. Tasks with unknown
totals show a spinner:

```text
build [#########---] 75% 3/4
├─ assets [############] 100% 2/2
└─ code [######------] 50% 1/2
   └─ compile /
```

Use `--name TEXT` to set the task label. By default, the label is the command's
basename. Use `--renderer tree` to show a plain tree with Zig progress counters.
Use `--no-progress` to hide progress.

By default, `zpg` shows progress on stderr if stderr is a terminal. If only
stdout is a terminal, it shows progress on stdout. If neither stream is a
terminal, it hides progress. Use `--progress-stream stdout` or
`--progress-stream stderr` to select a stream. The selected stream must be a
terminal that supports ANSI escapes. Use `--progress-stream auto` to restore
the default selection.

Set bar and spinner styles:

```sh
zpg --bar-style block --spinner-style dots ./worker
zpg --bar-style fira --spinner-style fira ./worker
zpg --bar-style '(=.)' --spinner-style '.oO@' ./worker
```

Both styles use `ascii` by default. The `fira` styles require Fira Code or a
font with the same progress characters. Set `UNICODE_PROGRESS_BAR=true` to use
`fira` by default for both styles. Command-line options override each style
separately.

For a custom bar, supply two characters (filled, empty) or four characters
(left border, filled, empty, right border). For a custom spinner, supply 1 to
64 characters, one per frame. Quote values that contain spaces or shell symbols.
Styles apply only to the `bars` renderer. For nested `zpg` commands, set the
renderer and styles on the outermost `zpg` command.

### Progress estimates

Use `--guess` for commands that do not report progress. On Linux, `zpg` estimates
progress for one open input file, including a file that a child process reads.
The estimate applies to that file, not to the command's total progress. The
percentage can decrease if files change. A value of 100% does not mean the
command has finished.

`zpg` cannot measure some read methods. If it cannot find a suitable input,
the display shows `I/O estimate (unknown)`. On macOS, the estimate always shows
unknown progress.

### Command output and exit status

`zpg` sends the command's stdout to `zpg`'s stdout and the command's stderr to
`zpg`'s stderr. It keeps the bytes and their order within each stream unchanged.
It adds progress controls only to the selected terminal stream. The command
inherits stdin when stdin is a pipe or a file:

```sh
zpg worker > output.txt
cat input.txt | zpg worker > output.txt
zpg worker < input.txt > output.txt
zpg worker 2> errors.log
zpg --progress-stream stderr worker > output.txt
```

When stdout goes to a file or a pipe, `zpg` shows progress on terminal stderr.
When only stdout is a terminal, it shows progress on stdout. To save both
streams without progress, use `zpg worker > combined.log 2>&1`. To combine
them in a pipeline, use `zpg worker 2>&1 | consumer`.

`zpg` gives each command output stream a separate pseudo-terminal when the
matching `zpg` stream is a terminal. Otherwise, it gives the command output
stream a pipe. Programs can use their normal TTY checks to enable colored logs.
This behavior works with `--no-progress` and nested `zpg` commands.
`--no-progress` also hides progress in nested `zpg` commands.

Programs can update a line with `\r` or draw a small footer with relative
cursor movement. `zpg` tracks carriage returns, line feeds, backspace, tabs,
relative cursor movement (`CSI A/B/C/D/E/F`), column selection (`CSI G`),
line erasure (`CSI K`), erasure to the end of the screen (`CSI J`), and cursor
save and restore (`ESC 7/8`, `CSI s/u`).

`zpg` keeps its progress display below the command's output rows. It waits
until a control sequence, UTF-8 character, or saved cursor operation is complete.
If there is not enough space below the output, it hides progress. After a
cursor save, `zpg` also avoids scrolling that could move the saved screen
position, even after a restore. Progress can stay hidden until `zpg` knows
that it has enough space to draw without scrolling. Both renderers use this
behavior. Child stdout and stderr bytes stay unchanged.

Unchanged progress frames do not redraw. For complete log writes, `zpg`
clears the tree, writes the log, and restores the tree in one synchronized
terminal update. Terminals that support synchronized updates do not show
a blank tree between these steps.

The pseudo-terminals use the initial size of their matching terminals. Output
conversion is disabled. `zpg` does not support absolute screen positioning,
scroll regions, alternate screens, or other complex terminal operations.

When stdin is a terminal, `zpg` gives the command an empty stdin. `zpg` does
not support interactive commands or full-screen applications.

`zpg` returns the command's exit code. If a signal kills the command, `zpg`
returns `128 + signal`. Invalid arguments return 2. Launch or I/O errors
return 1.

On Ctrl-C or SIGTERM, `zpg` asks the command's process group to stop. If
necessary, it forces the process group to stop after two seconds. If a
descendant keeps an output stream open after the command exits, `zpg` stops
reading after two seconds and warns that it discarded output.

## Developer guide

### Zig progress protocol

Workers use the [Zig progress protocol](https://andrewkelley.me/post/zig-new-cli-progress-bar-explained.html#the-zig-progress-protocol-specification)
to send progress updates to a supervisor through a pipe. Updates describe tasks
and subtasks. Each update includes completed and total item counts. `zpg`
supplies the pipe and displays the updates.

Zig programs can use `std.Progress` to report updates. Scripts can use
`zpg --report`. Any program that implements the protocol can report progress
to `zpg`.

### Reporting progress from workers

#### Zig

Use `std.Progress` from the Zig standard library to report progress. It
connects to the progress pipe that `zpg` supplies. You do not need a `zpg`
library or code to handle the protocol. Save this Zig 0.17.0 example as
`worker.zig`:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const root = std.Progress.start(init.io, .{
        .root_name = "work",
        .estimated_total_items = 4,
    });
    defer root.end();

    for (0..4) |_| {
        // Replace this delay with one item of work.
        try init.io.sleep(.fromMilliseconds(500), .awake);
        root.completeOne();
    }
}
```

Build the program with `zig build-exe worker.zig`. Then run `zpg ./worker`.
Call `completeOne()` after each item completes. To set an absolute count, use
`setCompletedItems(count)`. If the total is unknown, set the estimated total
to `0`. When you know the total, call `setEstimatedTotalItems(total)`. For a
subtask, call `root.start("task name", total)` and update the returned node.
Call `end()` on each node when its task ends.

The program also works without `zpg`. In this case, `std.Progress` controls
its own display.

#### Scripts

Use `zpg --report COMPLETED TOTAL`. Keep `zpg` on `PATH`. Save this script as
`build.sh`, then run `zpg --name build sh build.sh`:

```sh
#!/bin/sh
set -e
zpg --report 0 2
compile_assets
zpg --report 1 2
compile_code
zpg --report 2 2
```

Replace `compile_assets` and `compile_code` with your commands. Each report
sets absolute counts. If the total is unknown, use `0`. Counts must be decimal
integers from 0 to 4294967294. To set the task label, add `--name`, as in
`zpg --report 3 10 --name 'compile files'`.

Each call exits after it sends the update. The supervisor keeps the last
update until the next report or until the script exits. If progress is
disabled or no supervisor is present, reports succeed without output. The
script also works on its own.

Concurrent reports for one command replace each other. Use nested `zpg`
commands for separate tasks. Do not mix shell reports with other progress
reports that use the protocol in the same command.
See [the shell demo](examples/report-demo.sh) or run `just demo-report`.

### Test a progress implementation

Use `--test` to inspect a program's Zig progress packets without a terminal
overlay. `zpg` writes the log to stderr, including when stderr is a file or
pipe:

```sh
zpg --test ./worker --flag value
zpg --test --test-output progress.log ./worker --flag value
```

`--test-output FILE` creates or replaces the log file. Child stdout and stderr
keep their original bytes. Use a log file to keep progress separate from child
stderr.

The log includes pipe open and close events, each snapshot's node count,
whether the snapshot changed, and the process result. Changed snapshots list
each node's packet index, parent index, completed count, total count, and name.
A total of `0` means unknown. Parent `255` marks the root. `zpg` escapes name
bytes so names cannot insert terminal controls or extra log lines.

The protocol sends whole snapshots, not individual task events. Compare
snapshots to see tasks appear, change, or disappear. Node indices can change
between snapshots. An empty snapshot has zero nodes. If a program sends no
packets, the log says `no progress received`.

Test mode reports truncated packets, reserved node counts and total counts,
and invalid parent trees. If the command succeeds, these errors make `zpg`
return status 1. If the command exits with a nonzero status, `zpg` keeps that
status. These checks do not prove that reported counts match the program's
work. If descendants keep pipes open, the normal drain timeout applies. The
log then marks the capture incomplete.

Test mode requires a command. Do not combine it with `--mock`, `--report`,
`--guess`, or `--no-progress`. Display styles do not affect the test log.

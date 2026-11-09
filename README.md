# zpg

`zpg` runs a command with a progress overlay.

## Zig progress protocol

Workers use the [Zig progress protocol](https://andrewkelley.me/post/zig-new-cli-progress-bar-explained.html#the-zig-progress-protocol-specification)
to send progress updates to a supervising process through a pipe.
Updates describe tasks and subtasks. Each update includes completed and total
item counts.
`zpg` supplies the progress pipe and displays these updates.

Zig programs can use `std.Progress` to report updates automatically. Scripts
can use `zpg --report` to send updates. Any program that implements the
protocol can report progress to `zpg`.

## Usage

`zpg` supports Linux and macOS. Build with Zig 0.17.0. Then add `zig-out/bin`
to `PATH`:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
zpg --name build ./worker --flag value
zpg --guess cp large.iso /backup/
zpg --mock
```

`--mock` runs a fixed progress demo when stdin is empty. With piped or
redirected input, it echoes each line with a short delay and shows input
progress. In the fixed demo, stdout logs are green when stdout is a terminal,
and stderr logs are red when stderr is a terminal. At the end, terminal stdout
shows a bar updated with `\r`, and terminal stderr shows a two-row footer
updated with cursor movement. Try `zpg zpg --mock` to check nested output.
Input echo also preserves a final line that has no newline:

```sh
printf 'one\ntwo\n' | zpg --mock
zpg --mock < input.txt
```

Use `zpg [options] <command> [args...]`. Put `zpg` options before the command.
Arguments after the command go to the command unchanged. `zpg` uses `PATH`
to find commands. For shell syntax, use `zpg sh -c '...'`. If a command name
starts with a hyphen, put `--` before the name. Run `zpg --help` for all options.

### Progress display

The default display shows bars, percentages, and counts. Tasks with unknown
totals show a spinner:

```text
build [#########---] 75% 3/4
├─ assets [############] 100% 2/2
└─ code [######------] 50% 1/2
   └─ compile /
```

Use `--name TEXT` to set the task label. The default is the command's basename.
Use `--renderer tree` for a plain tree with Zig progress counters.
Use `--no-progress` to hide progress. By default, progress uses stderr if it is
a terminal, or stdout if only stdout is a terminal. If neither is a terminal,
progress is hidden.
Use `--progress-stream stdout` or `--progress-stream stderr` to select one
explicitly. The selected stream must be a terminal that supports ANSI escapes.
Use `--progress-stream auto` to select the default behavior.

Set bar and spinner styles:

```sh
zpg --bar-style block --spinner-style dots ./worker
zpg --bar-style fira --spinner-style fira ./worker
zpg --bar-style '(=.)' --spinner-style '.oO@' ./worker
```

Both styles default to `ascii`. The `fira` styles require Fira Code or a font
with its progress characters. Set `UNICODE_PROGRESS_BAR=true` to make `fira`
the default for both styles. Command-line options override each style separately.

For a custom bar, supply two characters (filled, empty) or four characters
(left border, filled, empty, right border). For a custom spinner, supply 1 to
64 characters, one per frame. Quote values that contain spaces or shell symbols.
Styles apply only to the `bars` renderer. For nested `zpg` commands, set the
renderer and styles on the outermost command.

### Test a progress implementation

Use `--test` to inspect a program's Zig progress packets without a terminal
overlay. The log goes to stderr, including when stderr is a file or pipe:

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
A total of `0` means unknown. Parent `255` marks the root. Names use escaped
bytes so they cannot insert terminal controls or extra log lines.

The protocol sends whole snapshots, not individual task events. Compare
snapshots to see tasks appear, change, or disappear. Node indices can change
between snapshots. An empty snapshot has zero nodes. A program that sends
no packets is reported as `no progress received`.

Test mode reports truncated packets, reserved node counts and total counts,
and invalid parent trees. These errors return status 1 if the command succeeds.
A nonzero command exit status is preserved. These checks do not prove that
reported counts match the program's work. If descendants keep pipes open,
the normal drain timeout applies and the log marks the capture incomplete.

Test mode requires a command and cannot be combined with `--mock`, `--report`,
`--guess`, or `--no-progress`. Display styles do not affect the test log.

### Progress estimates

Use `--guess` for commands that do not report progress. On Linux, `zpg` estimates
progress for one open input file. This file can be one that a child process reads.
The estimate applies to that file, not to the command's total progress.
The percentage can decrease when files change. A value of 100% does not mean
the command has finished.
Some read methods cannot be measured. If no suitable input is available,
the display shows `I/O estimate (unknown)`. On macOS, the estimate always shows
unknown progress.

### Command output and exit status

The command's stdout goes to `zpg`'s stdout. Its stderr goes to `zpg`'s stderr.
The command's bytes and their order within each stream stay unchanged.
Progress controls are added only to the selected terminal stream.
The command inherits stdin when it is a pipe or a file:

```sh
zpg worker > output.txt
cat input.txt | zpg worker > output.txt
zpg worker < input.txt > output.txt
zpg worker 2> errors.log
zpg --progress-stream stderr worker > output.txt
```

When stdout goes to a file or a pipe, progress remains visible on terminal
stderr. When only stdout is a terminal, progress appears there instead.
To save both streams without progress, use `zpg worker > combined.log 2>&1`.
To combine them in a pipeline, use `zpg worker 2>&1 | consumer`.

Each command output stream gets a separate pseudo-terminal when the matching
`zpg` stream is a terminal. Otherwise, it gets a pipe. Programs can use their
normal TTY checks to enable colored logs. This also works with `--no-progress`
and nested `zpg` commands. `--no-progress` also hides progress in nested `zpg`
commands.

Programs can update a line with `\r` or draw a small footer with relative
cursor movement. `zpg` tracks carriage returns, line feeds, backspace, tabs,
relative cursor movement (`CSI A/B/C/D/E/F`), column selection (`CSI G`),
line erasure (`CSI K`), erasure to the end of the screen (`CSI J`), and cursor
save/restore (`ESC 7/8`, `CSI s/u`).
Its progress display stays below the rows used by the command. It waits while
a control sequence, UTF-8 character, or saved-cursor operation is incomplete.
It hides progress if there is not enough space below the command output.
After a cursor save, it also avoids scrolling that could change the saved screen
position, even after a restore. Progress can stay hidden until there is enough
known space to draw without scrolling.
Both renderers use this behavior. Child stdout and stderr bytes stay unchanged.

The pseudo-terminals use the initial size of their matching terminals, with
output conversion disabled. This is basic output support: absolute screen
positioning, scroll regions, alternate screens, and other complex terminal
operations are not supported.

When stdin is a terminal, the command receives an empty stdin instead.
`zpg` does not support interactive commands or full-screen applications.

`zpg` returns the command's exit code. If a signal kills the command, `zpg`
returns `128 + signal`. Invalid arguments return 2. Launch or I/O errors
return 1.
On Ctrl-C or SIGTERM, `zpg` asks the command's process group to stop.
If necessary, `zpg` forces the process group to stop after two seconds.
If a descendant keeps an output stream open after the command exits, `zpg`
stops reading after two seconds and warns that output was discarded.

## Reporting progress from workers

### Zig

Use `std.Progress` from the Zig standard library to report progress.
`std.Progress` automatically connects to the progress pipe that `zpg` supplies.
You do not need a `zpg` library or code to handle the protocol.
Save this Zig 0.17.0 example as `worker.zig`:

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

Build with `zig build-exe worker.zig`. Then run `zpg ./worker`.
Call `completeOne()` after each item completes, or use
`setCompletedItems(count)` to set an absolute count. If the total is unknown,
use an estimated total of `0`. When the total becomes known, call
`setEstimatedTotalItems(total)`. For subtasks, call
`root.start("task name", total)` and update the returned node.
Call `end()` on each node when its task ends.
The program also works without `zpg`. In this case, `std.Progress` controls
its own display.

### Scripts

Use `zpg --report COMPLETED TOTAL`.
Keep `zpg` on `PATH`. Save this script as `build.sh`, then run
`zpg --name build sh build.sh`:

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
sets absolute counts. If the total is unknown, use a total of `0`. Counts must be
decimal integers from 0 to 4294967294. For example,
`zpg --report 3 10 --name 'compile files'` also sets the task label.
Each call exits after sending the update. The supervisor keeps the last
update until the next report or until the script exits.
If progress is disabled or no supervisor is present, reports succeed without
output. The script therefore also works on its own.

Concurrent reports for one command replace each other. Use nested `zpg`
commands for separate tasks. Do not mix shell reports with other progress
reports that use the protocol in the same command.
See [the shell demo](examples/report-demo.sh) or run `just demo-report`.

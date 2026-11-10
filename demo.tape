Output zig-out/demo.gif

Require strace

Set Shell "bash"
Set FontFamily "Fira Code"
# At 13 px, Fira Code bar segments join cleanly in the VHS canvas renderer.
Set FontSize 13
# VHS adds 1 px between characters by default.
Set LetterSpacing 0
Set Width 780
Set Height 650
Set LoopOffset 20%

Env PS1 "$ "
Env UNICODE_PROGRESS_BAR "true"
Type "zpg zpg --mock"
Sleep 500ms
Enter
Sleep 10s

# Prepare 6 MiB of files and a cp wrapper that delays reads for this recording.
# The shell removes the temporary files when it exits.
Hide
Type "source scripts/demo-copy-setup.sh"
Enter
Sleep 1s
Type "clear"
Enter
Sleep 500ms
Show
Type "# Recursive copy (6 MiB; reads slowed for this demo)"
Enter
Type "zpg --guess cp -rv source/ copy/"
Sleep 500ms
Enter
Sleep 13s

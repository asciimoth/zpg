Output zig-out/demo.gif

Require strace
Require python3
Require cp
Require git
Require curl
Require ffmpeg

Set Shell "bash"
Set FontFamily "Fira Code"
# At 13 px, Fira Code bar segments join cleanly in the VHS canvas renderer.
Set FontSize 13
# VHS adds 1 px between characters by default.
Set LetterSpacing 0
Set Width 780
Set Height 650
# Start the GIF during the mock progress tree.
Set LoopOffset 10%
Set WaitTimeout 60s

Env PS1 "$ "
Env UNICODE_PROGRESS_BAR "true"
Hide
Type `cd "$ZPG_RECORDING_DIR"; clear`
Enter
Sleep 500ms
Show
Type "zpg zpg --mock"
Sleep 500ms
Enter
Sleep 10s

Hide
Type "clear"
Enter
Sleep 500ms
Show
Type `zpg --guess sh -c 'for f in input/*.bin; do cp -v "$f" copy/ & done; wait'`
Sleep 500ms
Enter
Sleep 1s
Wait+Line /^\$$/
Sleep 1s

Hide
Type "clear"
Enter
Sleep 500ms
Show
Type `zpg --guess git clone "$REPO_URL" cloned`
Sleep 500ms
Enter
Sleep 1s
Wait+Line /^\$$/
Sleep 1s

Hide
Type "clear"
Enter
Sleep 500ms
Show
Type "zpg --tasks tasks.json"
Sleep 500ms
Enter
Sleep 1s
Wait+Line /^\$$/
Sleep 500ms

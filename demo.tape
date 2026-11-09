Output zig-out/demo.gif

Set Shell "bash"
Set FontFamily "Fira Code"
# At 13 px, Fira Code bar segments join cleanly in the VHS canvas renderer.
Set FontSize 13
# VHS adds 1 px between characters by default.
Set LetterSpacing 0
Set Width 780
Set Height 650
Set LoopOffset 50%

Env PS1 "$ "
Env UNICODE_PROGRESS_BAR "true"
Type "zpg zpg --mock"
Sleep 500ms
Enter
Sleep 10s

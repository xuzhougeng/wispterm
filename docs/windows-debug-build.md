# WispTerm Windows diagnostic build

This is a **diagnostic** build of WispTerm: it shows a console window and writes
a debug log and crash reports so we can diagnose hard-to-reproduce issues
(e.g. a crash when opening the WeChat connection, or a freeze when ctrl+clicking
a remote file). It is built with runtime safety checks on (ReleaseSafe) and is
slightly slower than the normal release — use it only to reproduce a problem.

## How to use

1. Unzip `wispterm-windows-debug-<tag>.zip` anywhere and run `wispterm.exe`.
   A console window opens alongside the app — leave it open.
2. Reproduce the problem (open the WeChat connection, ctrl+click the remote
   file, etc.).
3. Send us:
   - `%APPDATA%\wispterm\wispterm-debug.log` (and `wispterm-debug.log.1` if present), and
   - any `%APPDATA%\wispterm\crash-*.txt` files, and
   - the text in the console window if the app crashed.

Open the folder quickly by pasting `%APPDATA%\wispterm` into the Explorer
address bar.

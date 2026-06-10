# SSH & Remote Development

*English · [中文](SSH-Remote-Development-zh)*

> Launch SSH profile sessions and unlock remote previews, downloads, working-directory uploads, and port forwarding.

## Launching an SSH session

Open the session launcher (`Ctrl+Shift+T`) and start an SSH session from
WispTerm's built-in **SSH launcher**. Launching this way attaches profile
metadata to the session, which is what unlocks remote file preview, remote
download, working-directory detection, and the automatic port forwarding
described below. Typing `ssh user@host` inside a local shell does **not** get
these features — see [[File-Explorer]].

## Reporting the working directory (OSC 7)

Drag-and-drop uploads in SSH profile sessions use the active remote working
directory when the shell reports it with OSC 7 (the same convention as Ghostty
shell integration). If the remote shell does not emit OSC 7, WispTerm falls back
to running `pwd` through a fresh `ssh.exe` helper, which usually returns the
login directory instead of the directory you `cd`'d into — and shows a clickable
setup prompt.

Add one of these snippets to the remote shell startup file, then start a new
WispTerm SSH session.

For **Bash** (`~/.bashrc`):

```bash
__wispterm_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"
}
PROMPT_COMMAND="__wispterm_report_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

For **Zsh** (`~/.zshrc`):

```zsh
__wispterm_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd __wispterm_report_cwd
add-zsh-hook precmd __wispterm_report_cwd
```

For **Fish** (`~/.config/fish/config.fish`):

```fish
function __wispterm_report_cwd --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url $PWD)
end
__wispterm_report_cwd
```

## Legacy SSH servers

For old bastions or servers that still require disabled OpenSSH algorithms, set:

```text
ssh-legacy-algorithms = true
```

This appends compatibility options for `ssh-rsa`, `ssh-dss`, older
Diffie-Hellman KEX, and CBC ciphers to WispTerm's SSH profile launches and its
helper `ssh.exe` / `scp.exe` commands.

## Web apps over SSH (port forwarding)

When a remote web app prints a loopback URL such as `http://127.0.0.1:4232` or
`http://localhost:43455`, WispTerm opens it through an automatic local SSH
tunnel. `Ctrl`/`Cmd`-click the URL to open it. The same tunnels are shared by
the embedded browser panel and the system browser, so setting
`url-open-mode = system-browser` lets the remote app open in your normal
browser. Each remote port keeps its own forward; WispTerm prefers the same
local port and only increments when that port is already occupied. Non-loopback
URLs (e.g. `https://10.10.x.x` or public sites) open directly. See
[[Browser-Jupyter-Panel]] for the panel itself. For tunnels you configure
yourself — such as sharing your local proxy with the server — see
[[Port-Forwarding]].

---
*See also: [[Port-Forwarding]] · [[File-Explorer]] · [[Browser-Jupyter-Panel]] · [[Configuration]]*

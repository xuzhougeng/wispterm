# Port Forwarding

*English · [中文](Port-Forwarding-zh)*

> Run silent SSH tunnels bound to a saved SSH profile. The headline use case is letting a remote dev server reach the HTTP/SOCKS proxy running on your own machine.

WispTerm keeps a global list of port-forwarding rules. Each rule attaches to one
of your saved SSH profiles (see [[SSH-Remote-Development]]) and starts an
independent OpenSSH helper that tunnels a single loopback port. These rules are
separate from the *automatic* URL tunnels in [[SSH-Remote-Development]] — those
open remote web apps on demand, while these are persistent forwards you define
yourself.

## Opening the manager

Open the command center and choose **Port Forwarding** ("Manage SSH port
forwarding rules"). The rules are global and keep running even after you close
the management tab — closing the tab does not stop the helpers.

The list shows each rule's name, direction, endpoints, and status. Press
**Enter** to start or stop the selected rule.

## Reverse proxy tunnel

This is the common proxy/VPN case: you already run a local proxy (Clash, V2Ray,
mihomo, …) on your workstation at `127.0.0.1:7890`, and you want a remote server
to route its traffic through it.

Press **n** to add a rule — it defaults to exactly this shape, named
**Local proxy**:

```text
Reverse: server 127.0.0.1:7890  ->  local 127.0.0.1:7890
```

Pick the SSH profile of the server, leave the ports at `7890` (or match your
proxy's port), and save. A reverse (`-R`) forward makes the server's loopback
`127.0.0.1:7890` reach the proxy on your machine.

Then, on the server, point the standard proxy variables at that port:

```sh
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
```

`curl`, `pip`, `apt`, `git`, and most tools now tunnel out through your local
proxy.

## Local forwarding

Local (`-L`) forwarding goes the other way: a service listening on the server's
loopback becomes reachable from your machine. Use it for a dashboard, database,
or notebook bound to `127.0.0.1` on the server:

```text
Local: local 127.0.0.1:8888  ->  server 127.0.0.1:8888
```

Open `http://127.0.0.1:8888` locally and you hit the server's service. (For
remote web apps that print their own URL, WispTerm already tunnels
automatically — see [[SSH-Remote-Development]].)

## Rule fields & shortcuts

Each rule has:

- **Profile** — which saved SSH profile carries the tunnel. Any `ProxyJump` set on that profile is honored.
- **Direction** — **reverse** (`-R`, server uses your local port) or **local** (`-L`, you use the server's port).
- **Local / remote host & port** — both ends of the tunnel. Hosts must be loopback (see below).
- **Enabled** — whether the rule is active.
- **Auto-start** — start the helper automatically when the rule's profile connects.

In the manager: **n** new, **e** edit, **d** delete, **Enter** start/stop,
**Space** enable/disable, **a** toggle auto-start, **r** restart, **Esc** close.
In the rule form, move between fields with **↑/↓** or **Tab**, type to edit a
field, **Space** toggles the direction or auto-start, **Enter** saves, **Esc**
cancels.

## Safety & SSH notes

- **Loopback only.** Hosts must be `127.0.0.1` or `localhost`; WispTerm refuses `0.0.0.0` and other non-loopback addresses, so a rule never exposes a port to your LAN.
- **Independent helpers.** Each rule runs its own OpenSSH process and does not use `ControlMaster`, `ControlPersist`, or `ControlPath`, so it won't collide with your SSH config's connection multiplexing.

---
*See also: [[SSH-Remote-Development]] · [[Browser-Jupyter-Panel]] · [[Configuration]]*

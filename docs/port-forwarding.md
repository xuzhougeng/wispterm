# Port Forwarding

Open **Port Forwarding** from the command center to manage silent SSH forwarding
rules. Rules are global and bind to saved SSH profiles. Closing the management
tab does not stop running forwarding helpers.

## Reverse Forwarding

Reverse forwarding lets a server use a local port on your workstation. The
common proxy/VPN rule is:

```text
Reverse: server 127.0.0.1:7890 -> local 127.0.0.1:7890
```

On the server:

```sh
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
```

## Local Forwarding

Local forwarding lets a local browser or service use a loopback service on the
server:

```text
Local: local 127.0.0.1:8888 -> server 127.0.0.1:8888
```

## Safety Boundary

v1 only supports loopback hosts (`127.0.0.1` and `localhost`). It does not bind
`0.0.0.0` or other non-loopback addresses.

## SSH Compatibility

WispTerm starts independent OpenSSH helper processes and does not use
ControlMaster, ControlPersist, or ControlPath for forwarding helpers.

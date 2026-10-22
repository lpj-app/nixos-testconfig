# Deployment Tool

A local web UI on top of this repo's `Makefile`: pick a host, fill in the
connection details, press a button, watch the log. It runs the same `make`
targets an operator runs by hand (`init`, `set-password`, `copy`, `switch`,
`copy-switch`), so the Makefile stays the single source of how a deployment
works. Python 3 standard library only, no build step, no dependencies.

How it is built (files, functions, API, flows): [STRUCTURE.md](STRUCTURE.md).

## Start

```bash
python deployment-tool/server.py              # --port 8765 by default
# → Deployment tool: http://127.0.0.1:8765/#token=...
```

Open the printed URL. Run it where `make`, `ssh` and `rsync` work — on Windows
the MSYS2 `make` on the PATH, exactly as for `make copy-switch` by hand
(override with `DEPLOY_MAKE=<path>`). Helper commands (disk probe, mesh key,
status) use the `ssh` next to that `make`, like the Makefile's `RSYNC_BINDIR`.

## What it does

| Area | Function |
|---|---|
| **Connection** | Host config (`hosts/*`, servers and desktops), address, port, SSH user, key from `.ssh/` or a password, disk, LUKS; optional jump host (`JUMP=user@host`, port, key, passphrase/password) for VMs behind a firewall, every ssh/rsync then goes through it via `ProxyCommand`. Profiles are the same `.machines/<name>.conf` files `scripts/menu.sh` uses |
| **Deploy** | `copy-switch`, `copy`, `switch`; `check` (dry-build on the target) and `test` (activate until reboot) |
| **Install VM** | Probe the target's disks (`lsblk`) and pick one; `init` only after typing the host name and only if LUKS matches `luksEnable`; `set-password` for `root` and `lpj`; generate an ed25519 key in `.ssh/` (passphrase goes to `ssh-keygen -N`, local only) and append its `.pub` to the host's `authorized_keys` by password; first `copy-switch` |
| **New host** | Writes `hosts/<name>/configuration.nix` from the template in the top-level README §7.7 (role checkboxes = modules, mesh ports, backup paths, Postgres databases) and adds the host to `topology.nix` with the next free mesh IP; shows the `git diff` |
| **Mesh & keys** | Per VM in `topology.nix`: fetch the `wg-mesh` public key and write it into `topology.nix`; derive the sops age recipient from the SSH host key (host key read over ssh, then `ssh-to-age`) |
| **Status** | NixOS version, current generation, failed units, mesh handshakes of the connected host |

**Mesh & keys and Status need `NIXUSER=root`**: `wg show` requires
`CAP_NET_ADMIN`, so fetching the mesh key or the handshakes as the `lpj`
user fails with `Unable to access interface: Operation not permitted`.
Switch the connection's SSH user to `root` for these two (root's key is the
same as `lpj`'s, mirrored by `server-base.nix`).
| **History** | Runs of this session with result; every run is also written to `.deploy-logs/` (git-ignored) |
| **Log** | Live output of the running `make`, an input line (masked) to answer remote prompts, cancel button |

Nothing is committed or pushed by the tool. After "New host" or "Fetch mesh
key", review the diff and commit by hand; the remaining steps for a new VM
(Caddy vhost, `.sops.yaml`, backup server) are in the top-level README §7.7.

## Two ways to connect

| Method | When | Fields |
|---|---|---|
| **Direct** | The VM is reachable from this machine (home lab, admin VPN) | Address, port, SSH user, key or password |
| **Jump host** | The VM sits behind firewalls and only a vServer reaches it (production) | as above, plus *Connection → Jump host*: `user@host`, port, key, key passphrase, password |

With a jump host every ssh and rsync, the make targets and the helpers alike,
runs through it with `ProxyCommand` (`ssh -W %h:%p <jump>`). No tunnel has to
be opened by hand, and *Address* is the VM's address **as the jump host sees
it** (e.g. its mesh IP), not the address from this machine. The same works
without the tool:

```bash
make copy-switch NIXNAME=k3s NIXADDR=10.101.0.2 SSH_KEY=.ssh/<vm-key> \
  JUMP=<user>@<vserver> JUMP_PORT=22 JUMP_KEY=.ssh/<vserver-key>
```

Which secret goes where (all optional, only for this run):

| ssh asks for | Field |
|---|---|
| Passphrase of the jump key | Jump key passphrase |
| Password of `<user>@<vserver>` | Jump password |
| Password or key passphrase for the VM | SSH password / key passphrase |

`askpass.sh` tells them apart by ssh's prompt, which names the key path or
`user@host`. Profiles store jump host, port and key, never a secret. The old
way, a manual `ssh -L 2222:<vm>:22 <vserver>` with address `127.0.0.1` and
port `2222`, still works as a direct connection.

## Files

| File | Role |
|---|---|
| `server.py` | HTTP server on 127.0.0.1: static files, JSON API, runs `make <target>` with an argument list, streams output, writes `.deploy-logs/` |
| `index.html`, `app.css`, `app.js` | The UI in English (plain HTML/CSS/JS, light and dark mode) |
| `askpass.sh` | Hands SSH password, key passphrase or jump host secrets to ssh/rsync via `SSH_ASKPASS`, picked by the prompt |
| `STRUCTURE.md` | How the tool is built, file by file |

## Security

The tool holds no secrets, but it **uses** the operator's root SSH access to
every host. Whoever controls it controls the platform, so:

- **Loopback only.** Binds `127.0.0.1`; requests with a foreign `Host` header
  are refused (DNS rebinding).
- **Token.** A random token per start travels in the URL fragment (never sent
  to the server or logged) and then as `X-Deploy-Token` header on every API
  call. Another web page cannot set that header, so it cannot trigger a run.
- **No shell strings.** `make` gets an argument list. Targets come from a fixed
  list, `NIXNAME` must be a directory in `hosts/`, the address an IP or
  hostname, the disk `/dev/...`, the key a file in `.ssh/`. Anything else is
  rejected before `make` starts.
- **Passwords.** SSH password, key passphrases and jump host password go to
  ssh only through the job's environment and `SSH_ASKPASS`; answers typed into
  the log's input line go to the process stdin. None of them is stored, put on
  a command line or written to the log.
- **Jump host.** `JUMP` must be `user@host` and `JUMP_KEY` a file in `.ssh/`,
  so nothing else can end up in the `ProxyCommand`. Host keys are not checked
  on either hop (`StrictHostKeyChecking=no`, like direct connections).
- **One job per target address** at a time; `init` needs the host name typed
  as confirmation.
- **Not on a server, not in Jenkins.** The ci VM must not hold root keys to the
  other VMs (architecture doc §3b). For a team: the same tool on a management
  VM behind the admin VPN, with SSO in front and short-lived SSH certificates.

## How a run works

1. The UI posts target and connection to `/api/run`; the server validates
   them and starts `make <target> NIXNAME=… NIXADDR=… …` in the repo.
2. stdout/stderr are read in chunks (prompts without a newline appear too)
   and streamed to the browser; the log file is written alongside.
3. Remote prompts (`sudo`, `mkpasswd` in `set-password`) are answered in the
   input line: the Makefile's `ssh -tt` forwards stdin to the remote pty, so
   no local pseudo-terminal is needed (none exists on Windows).
4. Cancel kills the process tree (`taskkill /T` on Windows, the process group
   elsewhere).

## Limits

- No `nix eval` before a run: there is no Nix on the Windows admin machine, so
  evaluation errors show up in the `switch` log.
- A local SSH password prompt without askpass cannot be answered (no local
  tty): use a key, or fill in the password field.
- Mesh & keys connects to each VM's LAN IP from `topology.nix`. Through a
  jump host that only works if the jump host reaches those IPs.
- The jump host path is tested for argument handling (ssh, rsync, askpass),
  not yet against the real vServer.
- Tested against a copy of the repo (API, validation, a real `make` run with
  streaming, profile/mesh-key/new-host writes). Not yet exercised against a
  real VM or visually in every browser.

## Open

- Retire `scripts/menu.sh` once the tool covers the daily path?
- "Deploy all" in the order of the architecture doc §3g, stop or continue on
  the first failed host?
- Proxmox API integration (create the VM, attach the ISO, set the VLAN tag),
  which would add a Proxmox API token to protect.

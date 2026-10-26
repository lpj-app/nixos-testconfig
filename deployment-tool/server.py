#!/usr/bin/env python3
"""Local web UI for this repo's Makefile. Stdlib only.

Usage: python deployment-tool/server.py [--port 8765]
Binds 127.0.0.1 only; every API call needs the token printed at start.
"""
import argparse
import datetime
import http.server
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import urllib.parse
from pathlib import Path

try:  # POSIX only; local-switch's sudo prompt needs a real pty to read from
    import fcntl
    import pty
    import termios
except ImportError:
    pty = None

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
HOSTS = REPO / "hosts"
MODULES = REPO / "modules" / "services"
MACHINES = REPO / ".machines"
KEYS = REPO / ".ssh"
LOGS = REPO / ".deploy-logs"
TOPOLOGY = MODULES / "topology.nix"
ASSET_DIR = REPO / "assets" / "deployment-tool"
LOGO = ASSET_DIR / "lpj.app.png"
FAVICON = ASSET_DIR / "favicon.png"

TARGETS = {"init", "set-password", "copy", "switch", "copy-switch", "check", "test",
           "local-copy", "local-switch", "local-copy-switch",
           "u2f-register", "u2f-register-backup", "u2f-check",
           "local-u2f-register", "local-u2f-register-backup", "local-u2f-check"}
# These run directly on this machine (no ssh/rsync-to-remote) — only meaningful
# when the deployment tool itself runs on the target host, e.g. a laptop you're
# sitting at. local-switch's `sudo nixos-rebuild switch` needs a real local tty
# to prompt for a password, which is why Job gives these their own pty below.
LOCAL_TARGETS = {"local-copy", "local-switch", "local-copy-switch",
                 "local-u2f-register", "local-u2f-register-backup", "local-u2f-check"}
PROFILE_KEYS = ["NIXNAME", "NIXADDR", "NIXPORT", "NIXUSER", "NIXHDD", "LUKS", "SSH_KEY", "JUMP", "JUMP_PORT", "JUMP_KEY"]
# Always imported by a new host; the rest of modules/services are role checkboxes.
BASE_MODULES = {"server-base", "topology", "secrets", "mesh", "monitoring-agent", "backup", "internal-dns"}

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
HOSTNAME_RE = re.compile(r"^[A-Za-z0-9.-]{1,253}$")
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
JUMP_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}@[A-Za-z0-9.-]{1,253}$")
HDD_RE = re.compile(r"^/dev/[a-z0-9/]+$")
PATH_RE = re.compile(r"^/[A-Za-z0-9._/-]+$")
WGKEY_RE = re.compile(r"^[A-Za-z0-9+/]{42,43}=$")

MAKE = os.environ.get("DEPLOY_MAKE", "make")
# Helpers use the ssh next to make (msys on Windows), like the Makefile's RSYNC_BINDIR.
_bindir = Path(shutil.which(MAKE) or "").parent
SSH = str(_bindir / "ssh") if shutil.which("ssh", path=str(_bindir)) else "ssh"
SSH_KEYGEN = str(_bindir / "ssh-keygen") if shutil.which("ssh-keygen", path=str(_bindir)) else "ssh-keygen"

TOKEN = secrets.token_urlsafe(24)
JOBS = {}
JOBS_LOCK = threading.Lock()


class BadRequest(Exception):
    pass


# ---------- repo inspection ----------

def host_info(name):
    text = (HOSTS / name / "configuration.nix").read_text(encoding="utf-8")
    luks = re.search(r"luksEnable\s*=\s*(true|false)", text)
    return {
        "name": name,
        "server": "server-base.nix" in text,
        "luks": luks.group(1) == "true" if luks else False,
    }


def list_hosts():
    return [host_info(p.name) for p in sorted(HOSTS.iterdir()) if (p / "configuration.nix").exists()]


def list_profiles():
    out = {}
    for f in sorted(MACHINES.glob("*.conf")):
        cfg = {}
        for line in f.read_text(encoding="utf-8").splitlines():
            k, _, v = line.partition("=")
            if k in PROFILE_KEYS:
                cfg[k] = v
        out[f.stem] = cfg
    return out


def list_keys():
    if not KEYS.is_dir():
        return []
    return [f".ssh/{p.name}" for p in sorted(KEYS.iterdir())
            if p.is_file() and not p.name.endswith(".pub") and not p.name.startswith("known_hosts")]


def list_role_modules():
    return sorted(p.stem for p in MODULES.glob("*.nix") if p.stem not in BASE_MODULES)


def topology_hosts():
    if not TOPOLOGY.exists():
        return []
    text = TOPOLOGY.read_text(encoding="utf-8")
    rx = re.compile(r'^\s*([a-z0-9-]+)\s*=\s*host\s+"([^"]+)"\s+"([^"]+)"(?:\s*//\s*\{\s*publicKey\s*=\s*"([^"]*)";\s*\})?;', re.M)
    return [{"name": m[1], "lanIp": m[2], "meshIp": m[3], "publicKey": m[4]} for m in rx.finditer(text)]


# ---------- validation ----------

def check_port(v):
    port = int(v or 22)
    if not 1 <= port <= 65535:
        raise BadRequest("invalid port")
    return str(port)


def check_key(v):
    key = str(v or "")
    if key and key not in list_keys():
        raise BadRequest("SSH key must be a file in .ssh/")
    return key


def check_conn(c):
    """Validated make variables for a connection; raises BadRequest."""
    name = str(c.get("NIXNAME", ""))
    if not NAME_RE.match(name) or not (HOSTS / name / "configuration.nix").exists():
        raise BadRequest("unknown host config")
    addr = str(c.get("NIXADDR", ""))
    try:
        ipaddress.ip_address(addr)
    except ValueError:
        if not HOSTNAME_RE.match(addr):
            raise BadRequest("invalid address")
    user = str(c.get("NIXUSER") or "root")
    if not USER_RE.match(user):
        raise BadRequest("invalid SSH user")
    hdd = str(c.get("NIXHDD") or "/dev/vda")
    if not HDD_RE.match(hdd):
        raise BadRequest("invalid disk")
    luks = "true" if str(c.get("LUKS")).lower() == "true" else "false"
    jump = str(c.get("JUMP") or "")
    if jump and not JUMP_RE.match(jump):
        raise BadRequest("jump host must be user@host")
    return {"NIXNAME": name, "NIXADDR": addr, "NIXPORT": check_port(c.get("NIXPORT")), "NIXUSER": user,
            "NIXHDD": hdd, "LUKS": luks, "SSH_KEY": check_key(c.get("SSH_KEY")),
            "JUMP": jump, "JUMP_PORT": check_port(c.get("JUMP_PORT")), "JUMP_KEY": check_key(c.get("JUMP_KEY"))}


def check_local_conn(c):
    """Validated make variables for a local-* target: no address/key/jump, this machine is the target."""
    name = str(c.get("NIXNAME", ""))
    if not NAME_RE.match(name) or not (HOSTS / name / "configuration.nix").exists():
        raise BadRequest("unknown host config")
    user = str(c.get("NIXUSER") or "lpj")
    if not USER_RE.match(user):
        raise BadRequest("invalid user")
    # synthetic NIXADDR="local" so Job/summary/busy-check need no special-casing
    # — and it keys the busy-check on "this machine", not a particular host.
    return {"NIXNAME": name, "NIXUSER": user, "NIXADDR": "local"}


def auth_of(conn, body):
    """Secrets for askpass from the request body; askpass.sh tells jump prompts apart by key path/user@host."""
    return {"DEPLOY_SSH_PASSWORD": body.get("password") or "",
            "DEPLOY_JUMP_PASSPHRASE": body.get("jumpPassphrase") or "",
            "DEPLOY_JUMP_PASSWORD": body.get("jumpPassword") or "",
            "DEPLOY_JUMP": conn["JUMP"], "DEPLOY_JUMP_KEY": conn["JUMP_KEY"]}


def ssh_env(auth=None):
    """Environment for ssh/rsync; secrets are handed over via SSH_ASKPASS, never argv."""
    env = dict(os.environ)
    # make recipes must resolve msys ssh too; Windows OpenSSH can't exec askpass.sh
    if str(_bindir) not in (".", ""):
        env["PATH"] = str(_bindir) + os.pathsep + env.get("PATH", "")
    if auth and any(auth[k] for k in ("DEPLOY_SSH_PASSWORD", "DEPLOY_JUMP_PASSPHRASE", "DEPLOY_JUMP_PASSWORD")):
        env.update(auth)
        env["SSH_ASKPASS"] = str(HERE / "askpass.sh").replace("\\", "/")
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env.setdefault("DISPLAY", "none")
    return env


def ssh_argv(conn, *remote):
    opts = ["-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10"]
    if conn["SSH_KEY"]:
        opts += ["-i", conn["SSH_KEY"], "-o", "IdentitiesOnly=yes"]
    else:
        opts += ["-o", "PubkeyAuthentication=no"]
    if conn["JUMP"]:
        # same ProxyCommand as SSH_JUMP in the Makefile
        jk = ["-i", conn["JUMP_KEY"], "-o", "IdentitiesOnly=yes"] if conn["JUMP_KEY"] else ["-o", "PubkeyAuthentication=no"]
        opts += ["-o", "ProxyCommand=" + " ".join(["ssh", "-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no",
                                                    *jk, "-p", conn["JUMP_PORT"], "-W", "%h:%p", conn["JUMP"]])]
    return [SSH, *opts, "-p", conn["NIXPORT"], f'{conn["NIXUSER"]}@{conn["NIXADDR"]}', *remote]


def run_quick(argv, auth=None, stdin=None, timeout=60):
    p = subprocess.run(argv, cwd=REPO, env=ssh_env(auth), input=stdin, capture_output=True,
                       text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


# ---------- jobs ----------

class Job:
    def __init__(self, target, conn, extra, auth, local=False):
        self.id = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(2)
        self.target, self.conn, self.extra = target, conn, extra
        self.started = datetime.datetime.now().isoformat(timespec="seconds")
        self.ended = None
        self.rc = None
        self.chunks = []
        self.cond = threading.Condition()
        argv = [MAKE, target] + [f"{k}={v}" for k, v in {**conn, **extra}.items()]
        self.cmdline = " ".join(argv)
        LOGS.mkdir(exist_ok=True)
        self.logfile = LOGS / f"{self.id}-{conn['NIXNAME']}-{target}.log"
        kwargs = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
        # local-switch's `sudo` only prompts when it sees a real tty — remote
        # targets get that for free from the Makefile's `ssh -tt` (the *remote*
        # side allocates the pty); here there is no ssh in between, so give the
        # child our own local pty instead of a plain pipe.
        self.master_fd = None
        if local and pty is not None:
            self.master_fd, slave_fd = pty.openpty()
            # start_new_session=True (setsid) runs before preexec_fn, but a
            # pty only becomes the *controlling* terminal of that new session
            # once something explicitly claims it — plain fd inheritance isn't
            # enough. Without this, sudo's own open("/dev/tty") fails with
            # ENXIO ("a terminal is required to read the password") even
            # though stdin is already a tty-type fd.
            self.proc = subprocess.Popen(argv, cwd=REPO, env=ssh_env(auth), stdin=slave_fd,
                                         stdout=slave_fd, stderr=slave_fd,
                                         preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0), **kwargs)
            os.close(slave_fd)
        else:
            self.proc = subprocess.Popen(argv, cwd=REPO, env=ssh_env(auth), stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0, **kwargs)
        self.append(f"+ {self.cmdline}\n")
        threading.Thread(target=self.pump, daemon=True).start()

    def append(self, text):
        with self.cond:
            self.chunks.append(text)
            self.cond.notify_all()
        with self.logfile.open("a", encoding="utf-8") as f:
            f.write(text)

    def pump(self):
        if self.master_fd is not None:
            while True:
                try:
                    data = os.read(self.master_fd, 4096)
                except OSError:  # pty raises EIO once the child side closes, not an empty read
                    break
                if not data:
                    break
                self.append(data.decode("utf-8", errors="replace"))
            os.close(self.master_fd)
        else:
            while True:
                data = self.proc.stdout.read(4096)
                if not data:
                    break
                self.append(data.decode("utf-8", errors="replace"))
        rc = self.proc.wait()
        self.ended = datetime.datetime.now().isoformat(timespec="seconds")
        self.append(f"\n[exit code {rc}]\n")
        with self.cond:  # rc last, so a stream sees every chunk before it stops
            self.rc = rc
            self.cond.notify_all()

    def send(self, text):
        if self.rc is None:
            try:
                if self.master_fd is not None:
                    os.write(self.master_fd, (text + "\n").encode())
                else:
                    self.proc.stdin.write((text + "\n").encode())
                    self.proc.stdin.flush()
            except OSError:
                pass

    def cancel(self):
        if self.rc is not None:
            return
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(self.proc.pid)], capture_output=True)
        else:
            os.killpg(self.proc.pid, signal.SIGTERM)

    def summary(self):
        return {"id": self.id, "target": self.target, "host": self.conn["NIXNAME"], "addr": self.conn["NIXADDR"],
                "started": self.started, "ended": self.ended, "rc": self.rc, "cmd": self.cmdline}


def start_job(body):
    target = body.get("target")
    if target not in TARGETS:
        raise BadRequest("target not allowed")
    local = target in LOCAL_TARGETS
    conn = check_local_conn(body.get("conn", {})) if local else check_conn(body.get("conn", {}))
    extra = {}
    if target == "set-password":
        user = str(body.get("user", ""))
        if not USER_RE.match(user):
            raise BadRequest("invalid user for set-password")
        extra["USER"] = user
    if target == "init":
        if body.get("confirm") != conn["NIXNAME"]:
            raise BadRequest("init wipes the disk: type the host name to confirm")
        if conn["LUKS"] != ("true" if host_info(conn["NIXNAME"])["luks"] else "false"):
            raise BadRequest("LUKS does not match luksEnable in the host config")
    with JOBS_LOCK:
        busy = [j for j in JOBS.values() if j.rc is None and j.conn["NIXADDR"] == conn["NIXADDR"]]
        if busy:
            raise BadRequest(f"a job for {conn['NIXADDR']} is still running ({busy[0].id})")
        auth = None if local else auth_of(conn, body)
        job = Job(target, conn, extra, auth, local=local)
        JOBS[job.id] = job
    return job.summary()


# ---------- helpers on the repo ----------

def save_profile(body):
    name = str(body.get("name", ""))
    if not NAME_RE.match(name):
        raise BadRequest("invalid profile name")
    conn = check_conn(body.get("conn", {}))
    MACHINES.mkdir(exist_ok=True)
    (MACHINES / f"{name}.conf").write_text("".join(f"{k}={conn[k]}\n" for k in PROFILE_KEYS), encoding="utf-8")
    return {"saved": name}


def git_diff(*paths):
    rc, out, err = run_quick(["git", "diff", "--", *paths])
    return out or err


def set_mesh_key(name, key):
    if not NAME_RE.match(name) or not WGKEY_RE.match(key):
        raise BadRequest("invalid host or key")
    if not TOPOLOGY.exists():
        raise BadRequest("topology.nix is missing; create the topology file first")
    text = TOPOLOGY.read_text(encoding="utf-8")
    rx = re.compile(rf'^(\s*{re.escape(name)}\s*=\s*host\s+"[^"]+"\s+"[^"]+")(?:\s*//\s*\{{\s*publicKey\s*=\s*"[^"]*";\s*\}})?;', re.M)
    new, n = rx.subn(lambda m: f'{m[1]} // {{ publicKey = "{key}"; }};', text, count=1)
    if n != 1:
        raise BadRequest(f"{name} not found in topology.nix")
    TOPOLOGY.write_text(new, encoding="utf-8", newline="\n")
    return {"diff": git_diff(str(TOPOLOGY.relative_to(REPO)))}


def keygen(name, passphrase):
    """ssh-keygen can't read a passphrase from a pipe, so it goes via -N (local, never logged)."""
    if not NAME_RE.match(name):
        raise BadRequest("invalid key name")
    path = KEYS / name
    if path.exists() or path.with_suffix(".pub").exists():
        raise BadRequest(f".ssh/{name} already exists")
    KEYS.mkdir(exist_ok=True)
    rc, out, err = run_quick([SSH_KEYGEN, "-q", "-t", "ed25519", "-C", name, "-N", passphrase, "-f", f".ssh/{name}"])
    if rc != 0:
        raise BadRequest(err.strip() or "ssh-keygen failed")
    return {"key": f".ssh/{name}", "pub": (KEYS / f"{name}.pub").read_text(encoding="utf-8").strip()}


def copy_id(conn, key, auth):
    """Append key's .pub to the target user's authorized_keys (ssh-copy-id), logging in by password."""
    if key not in list_keys():
        raise BadRequest("SSH key must be a file in .ssh/")
    pub = (REPO / f"{key}.pub").read_text(encoding="utf-8").strip()
    # text-mode stdin on Windows sends \r\n
    script = ('umask 077; mkdir -p ~/.ssh; read -r k; k=$(echo "$k" | tr -d "\\r"); '
              'grep -qxF "$k" ~/.ssh/authorized_keys 2>/dev/null && echo already present || '
              '{ echo "$k" >> ~/.ssh/authorized_keys && echo installed; }')
    rc, out, err = run_quick(ssh_argv({**conn, "SSH_KEY": ""}, script), auth, stdin=pub + "\n")
    if rc != 0:
        raise BadRequest(err.strip() or "copy failed")
    return {"output": f"{key}.pub on {conn['NIXUSER']}@{conn['NIXADDR']}: {out.strip()}", "pub": pub}


def helper(body):
    kind = body.get("kind")
    if kind == "keygen":
        return keygen(str(body.get("name", "")), str(body.get("passphrase") or ""))
    conn = check_conn(body.get("conn", {}))
    auth = auth_of(conn, body)
    if kind == "probe-disks":
        rc, out, err = run_quick(ssh_argv(conn, "lsblk -J -d -o NAME,SIZE,MODEL,TYPE"), auth)
        if rc != 0:
            raise BadRequest(err.strip() or "lsblk failed")
        disks = [d for d in json.loads(out)["blockdevices"] if d.get("type") == "disk"]
        return {"disks": [{"path": f"/dev/{d['name']}", "size": d.get("size"), "model": (d.get("model") or "").strip()} for d in disks]}
    if kind == "mesh-key":
        rc, out, err = run_quick(ssh_argv(conn, "wg show wg-mesh public-key"), auth)
        key = out.strip()
        if rc != 0 or not WGKEY_RE.match(key):
            raise BadRequest(err.strip() or "no wg-mesh key (deployed with mesh.nix yet?)")
        return {"key": key}
    if kind == "age-key":
        # over ssh instead of ssh-keyscan, which can't use a jump host
        rc, out, err = run_quick(ssh_argv(conn, "cat /etc/ssh/ssh_host_ed25519_key.pub"), auth)
        line = out.strip()
        if rc != 0 or not line.startswith("ssh-ed25519 "):
            raise BadRequest(err.strip() or "no ed25519 host key")
        if shutil.which("ssh-to-age"):
            rc, age, err = run_quick(["ssh-to-age"], stdin=line)
            return {"age": age.strip(), "hostKey": line}
        return {"hostKey": line, "hint": "ssh-to-age not installed: run `ssh-to-age` on this line (nix-shell -p ssh-to-age)"}
    if kind == "copy-id":
        return copy_id(conn, str(body.get("key", "")), auth)
    if kind == "status":
        script = ("nixos-version; readlink /nix/var/nix/profiles/system; "
                  "echo failed=$(systemctl --failed --no-legend | wc -l); "
                  "wg show wg-mesh latest-handshakes 2>/dev/null || true")
        rc, out, err = run_quick(ssh_argv(conn, script), auth, timeout=30)
        return {"rc": rc, "output": out + err}
    raise BadRequest("unknown helper")


def new_host(body):
    name = str(body.get("name", ""))
    if not NAME_RE.match(name) or (HOSTS / name).exists():
        raise BadRequest("invalid or existing host name")
    roles = [r for r in body.get("roles", []) if r in list_role_modules()]
    lan, mesh = str(body.get("lanIp", "")), str(body.get("meshIp", ""))
    for ip in (lan, mesh):
        ipaddress.ip_address(ip)
    if not mesh.startswith("10.101.0.") or any(h["meshIp"] == mesh for h in topology_hosts()):
        raise BadRequest("mesh IP must be a free address in 10.101.0.0/24")
    ports = [int(p) for p in body.get("ports", [])]
    if any(not 1 <= p <= 65535 for p in ports):
        raise BadRequest("invalid port")
    paths = [p for p in body.get("paths", []) if PATH_RE.match(p)]
    dbs = [d for d in body.get("postgres", []) if NAME_RE.match(d.replace("_", "-"))]
    purpose = re.sub(r"[^\w .,()/-]", "", str(body.get("purpose", "")))[:120] or "<why it is its own VM>"

    q = lambda xs: " ".join(f'"{x}"' for x in xs)
    imports = "\n".join(f"    ../../modules/services/{r}.nix" for r in roles)
    conf = f'''{{ config, lib, pkgs, inputs, ... }}:
let
  luksEnable = false;
in
{{
  # {name.capitalize()} VM: {purpose}. See docs/company-server-architecture.md §3a.
  imports = [
    /etc/nixos/hardware-configuration.nix
    ../../users/lpj/nixos.nix

    ../../modules/services/server-base.nix
    ../../modules/services/internal-dns.nix
{imports}
  ];

  networking.hostName = "lpj-{name}";
  lpj.topology.self   = "{name}";
  lpj.internalDns.address = config.lpj.topology.hosts.edge.meshIp;

  lpj.mesh.ports = [ {" ".join(map(str, ports))} ];

  lpj.backup = {{
    enable   = true;
    postgres = [ {q(dbs)} ];
    paths    = [ {q(paths)} ];
  }};

  system.stateVersion = "26.05";
}}
'''
    if not TOPOLOGY.exists():
        raise BadRequest("topology.nix is missing; create it before creating a new host")
    text = TOPOLOGY.read_text(encoding="utf-8")
    last = list(re.finditer(r'^(\s*)[a-z0-9-]+\s*=\s*host\s+"[^"]+"\s+"[^"]+".*;\n', text, re.M))
    if not last:
        raise BadRequest("could not find the hosts list in topology.nix")
    m = last[-1]
    line = f'{m[1]}{name} = host "{lan}" "{mesh}";\n'
    (HOSTS / name).mkdir()
    (HOSTS / name / "configuration.nix").write_text(conf, encoding="utf-8", newline="\n")
    TOPOLOGY.write_text(text[:m.end()] + line + text[m.end():], encoding="utf-8", newline="\n")
    return {"created": f"hosts/{name}/configuration.nix", "file": conf,
            "diff": git_diff(str(TOPOLOGY.relative_to(REPO))),
            "next": "Caddy vhost, .sops.yaml, backupServer.hosts: README §7.7"}


# ---------- HTTP ----------

STATIC = {"/": ("index.html", "text/html"), "/app.css": ("app.css", "text/css"),
          "/app.js": ("app.js", "application/javascript")}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "lpj-deploy"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def guard(self):
        # DNS rebinding: only our own origin; API: token header (a foreign page cannot set it).
        host = self.headers.get("Host", "")
        if host not in (f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"):
            self.send_error(403)
            return False
        if self.path.startswith("/api/") and not secrets.compare_digest(self.headers.get("X-Deploy-Token", ""), TOKEN):
            self.send_json({"error": "missing or wrong token"}, 401)
            return False
        return True

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        if not self.guard():
            return
        path = urllib.parse.urlparse(self.path).path
        if path in STATIC:
            name, ctype = STATIC[path]
            return self.send_file(HERE / name, ctype)
        if path in ("/logo.png", "/favicon.png", "/favicon.ico"):
            file = LOGO if path == "/logo.png" else FAVICON
            return self.send_file(file, "image/png")
        if path == "/api/meta":
            return self.send_json({"hosts": list_hosts(), "profiles": list_profiles(), "keys": list_keys(),
                                   "roles": list_role_modules(), "topology": topology_hosts(),
                                   "targets": sorted(TARGETS), "repo": str(REPO)})
        if path == "/api/jobs":
            with JOBS_LOCK:
                jobs = [j.summary() for j in JOBS.values()]
            logs = sorted((p.name for p in LOGS.glob("*.log")), reverse=True)[:50] if LOGS.is_dir() else []
            return self.send_json({"jobs": sorted(jobs, key=lambda j: j["id"], reverse=True), "logs": logs})
        m = re.match(r"^/api/jobs/([\w-]+)/stream$", path)
        if m and m[1] in JOBS:
            return self.stream(JOBS[m[1]])
        self.send_error(404)

    def do_POST(self):
        if not self.guard():
            return
        path = urllib.parse.urlparse(self.path).path
        try:
            body = self.body()
            if path == "/api/run":
                return self.send_json(start_job(body))
            if path == "/api/profile":
                return self.send_json(save_profile(body))
            if path == "/api/helper":
                return self.send_json(helper(body))
            if path == "/api/mesh-key":
                return self.send_json(set_mesh_key(str(body.get("name", "")), str(body.get("key", "")).strip()))
            if path == "/api/new-host":
                return self.send_json(new_host(body))
            m = re.match(r"^/api/jobs/([\w-]+)/(input|cancel)$", path)
            if m and m[1] in JOBS:
                job = JOBS[m[1]]
                job.send(str(body.get("data", ""))) if m[2] == "input" else job.cancel()
                return self.send_json({"ok": True})
            self.send_error(404)
        except (BadRequest, ValueError, subprocess.TimeoutExpired) as e:
            self.send_json({"error": str(e) or e.__class__.__name__}, 400)
        except OSError as e:
            self.send_json({"error": f"{e.__class__.__name__}: {e}"}, 500)

    def send_file(self, file, ctype):
        if not file.exists():
            self.send_error(404, "missing asset")
            return
        data = file.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def stream(self, job):
        # Plain streamed text (HTTP/1.0, close-delimited); fetch() can set the token header.
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        sent = 0
        try:
            while True:
                with job.cond:
                    while sent == len(job.chunks) and job.rc is None:
                        job.cond.wait(timeout=15)
                    new, sent, done = job.chunks[sent:], len(job.chunks), job.rc is not None
                if new:
                    self.wfile.write("".join(new).encode())
                    self.wfile.flush()
                if done:
                    break
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8765)
    port = ap.parse_args().port
    if not shutil.which(MAKE):
        print("warning: `make` not on PATH (set DEPLOY_MAKE)", file=sys.stderr)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"lpj.app Deployment tool: http://127.0.0.1:{port}/#token={TOKEN}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

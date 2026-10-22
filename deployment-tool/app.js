"use strict";

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => [...document.querySelectorAll(sel)];
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

let token = "";
let meta = null;
let currentJob = null;
let streamAbort = null;

// ---------- API ----------

async function api(path, body) {
  const res = await fetch(path, {
    method: body === undefined ? "GET" : "POST",
    headers: { "X-Deploy-Token": token, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

function toast(text, error = false) {
  const el = $("#toast");
  el.textContent = text;
  el.className = "toast" + (error ? " error" : "");
  el.hidden = false;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => (el.hidden = true), error ? 7000 : 3500);
}

async function guarded(fn) {
  try {
    return await fn();
  } catch (e) {
    toast(e.message, true);
  }
}

// ---------- token ----------

function readToken() {
  const fromHash = new URLSearchParams(location.hash.slice(1)).get("token");
  if (fromHash) history.replaceState(null, "", location.pathname);
  try {
    if (fromHash) sessionStorage.setItem("deploy-token", fromHash);
    token = sessionStorage.getItem("deploy-token") || "";
  } catch {
    token = fromHash || "";
  }
}

// ---------- connection form ----------

function conn() {
  const f = $("#conn");
  return {
    NIXNAME: f.NIXNAME.value,
    NIXADDR: f.NIXADDR.value.trim(),
    NIXPORT: f.NIXPORT.value,
    NIXUSER: f.NIXUSER.value.trim(),
    NIXHDD: f.NIXHDD.value.trim(),
    LUKS: f.LUKS.checked ? "true" : "false",
    SSH_KEY: f.SSH_KEY.value,
    JUMP: f.JUMP.value.trim(),
    JUMP_PORT: f.JUMP_PORT.value,
    JUMP_KEY: f.JUMP_KEY.value,
  };
}

function fillConn(cfg) {
  const f = $("#conn");
  for (const [k, v] of Object.entries(cfg)) {
    if (!f[k]) continue;
    if (f[k].type === "checkbox") f[k].checked = v === "true";
    else f[k].value = v;
  }
  showHostMeta();
}

function password() {
  return $("#password").value || null;
}

// every API call gets the secrets; askpass picks the one ssh prompts for
function secrets() {
  return { password: password(), jumpPassphrase: $("#jump-passphrase").value || null, jumpPassword: $("#jump-password").value || null };
}

function showHostMeta() {
  const h = meta.hosts.find((x) => x.name === $("#host").value);
  if (!h) return;
  $("#host-meta").textContent = `${h.server ? "Server" : "Desktop"} · luksEnable = ${h.luks}`;
  $("#init-confirm").placeholder = `Type “${h.name}” to confirm`;
}

function option(value, label = value) {
  const o = document.createElement("option");
  o.value = value;
  o.textContent = label;
  return o;
}

async function loadMeta() {
  meta = await api("/api/meta");
  $("#repo").textContent = meta.repo;

  const host = $("#host");
  const keep = host.value;
  host.replaceChildren(...meta.hosts.map((h) => option(h.name, h.server ? h.name : `${h.name} (Desktop)`)));
  if (keep) host.value = keep;

  const keys = $("#keys");
  const keepKey = keys.value;
  keys.replaceChildren(option("", "– password –"), ...meta.keys.map((k) => option(k)));
  keys.value = keepKey;
  const jkeys = $("#jump-keys");
  const keepJump = jkeys.value;
  jkeys.replaceChildren(option("", "– password –"), ...meta.keys.map((k) => option(k)));
  jkeys.value = keepJump;
  const cid = $("#cid-key");
  const keepCid = cid.value;
  cid.replaceChildren(...meta.keys.map((k) => option(k)));
  if (keepCid) cid.value = keepCid;

  const prof = $("#profile");
  const keepProf = prof.value;
  prof.replaceChildren(option("", "– new –"), ...Object.keys(meta.profiles).map((p) => option(p)));
  prof.value = keepProf;

  $("#roles").replaceChildren(...meta.roles.map((r) => {
    const l = document.createElement("label");
    l.innerHTML = `<input type="checkbox" name="roles" value="${esc(r)}"> ${esc(r)}`;
    return l;
  }));

  const used = new Set(meta.topology.map((t) => t.meshIp));
  let n = 2;
  while (used.has(`10.101.0.${n}`)) n++;
  $("#next-mesh").value = `10.101.0.${n}`;

  renderMesh();
  showHostMeta();
}

// ---------- jobs and log ----------

const ANSI = /\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r(?!\n)/g;

async function attach(job) {
  if (streamAbort) streamAbort.abort();
  streamAbort = new AbortController();
  currentJob = job;
  const log = $("#log");
  log.textContent = "";
  $("#job-title").textContent = `${job.target} · ${job.host} · ${job.addr}`;
  $("#cancel").disabled = job.rc !== null && job.rc !== undefined;

  try {
    const res = await fetch(`/api/jobs/${job.id}/stream`, {
      headers: { "X-Deploy-Token": token },
      signal: streamAbort.signal,
    });
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      const stick = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
      log.textContent += dec.decode(value, { stream: true }).replace(ANSI, "");
      if (stick) log.scrollTop = log.scrollHeight;
    }
  } catch (e) {
    if (e.name !== "AbortError") toast(e.message, true);
  }
  if (currentJob === job) $("#cancel").disabled = true;
  loadJobs();
}

async function run(target, extra = {}) {
  const job = await guarded(() => api("/api/run", { target, conn: conn(), ...secrets(), ...extra }));
  if (job) {
    toast(`${target} started`);
    attach(job);
  }
}

async function loadJobs() {
  const data = await guarded(() => api("/api/jobs"));
  if (!data) return;
  $("#jobs tbody").replaceChildren(...data.jobs.map((j) => {
    const tr = document.createElement("tr");
    const result = j.rc === null ? "running" : j.rc === 0 ? "ok" : `failed (${j.rc})`;
    const cls = j.rc === null ? "" : j.rc === 0 ? "ok" : "bad";
    tr.innerHTML = `<td>${esc(j.started.replace("T", " "))}</td><td>${esc(j.target)}</td><td>${esc(j.host)}</td>
      <td>${esc(j.addr)}</td><td class="${cls}">${result}</td><td><button class="btn small">Log</button></td>`;
    tr.querySelector("button").onclick = () => attach(j);
    return tr;
  }));
}

// ---------- mesh ----------

function renderMesh() {
  $("#mesh-table tbody").replaceChildren(...meta.topology.map((t) => {
    const tr = document.createElement("tr");
    const key = t.publicKey ? `<span class="ok">${esc(t.publicKey.slice(0, 10))}…</span>` : `<span class="bad">missing</span>`;
    tr.innerHTML = `<td>${esc(t.name)}</td><td>${esc(t.lanIp)}</td><td>${esc(t.meshIp)}</td><td>${key}</td>
      <td><button class="btn small" data-a="mesh">Fetch mesh key</button>
          <button class="btn small" data-a="age">age key</button></td>`;
    const c = () => ({ ...conn(), NIXNAME: t.name, NIXADDR: t.lanIp });
    tr.querySelector('[data-a="mesh"]').onclick = () => guarded(async () => {
      const { key: k } = await api("/api/helper", { kind: "mesh-key", conn: c(), ...secrets() });
      const { diff } = await api("/api/mesh-key", { name: t.name, key: k });
      showOut("#mesh-out", `${t.name}: ${k}\n\n${diff || "(no change)"}`);
      toast(`Key of ${t.name} written to topology.nix`);
      loadMeta();
    });
    tr.querySelector('[data-a="age"]').onclick = () => guarded(async () => {
      const r = await api("/api/helper", { kind: "age-key", conn: c(), ...secrets() });
      showOut("#mesh-out", r.age
        ? `.sops.yaml, anchor for lpj-${t.name}:\n  - &${t.name} ${r.age}`
        : `${r.hint}\n\n${r.hostKey}`);
    });
    return tr;
  }));
}

function showOut(sel, text) {
  const el = $(sel);
  el.textContent = text;
  el.hidden = false;
}

// ---------- wiring ----------

function csv(value) {
  return value.split(",").map((s) => s.trim()).filter(Boolean);
}

function wire() {
  $$(".tab").forEach((b) => (b.onclick = () => {
    $$(".tab").forEach((x) => x.classList.toggle("active", x === b));
    $$(".panel").forEach((p) => (p.hidden = p.id !== `tab-${b.dataset.tab}`));
    if (b.dataset.tab === "history") loadJobs();
  }));

  $("#host").onchange = showHostMeta;
  $("#profile").onchange = (e) => {
    const p = meta.profiles[e.target.value];
    if (p) fillConn(p);
    $("#profile-name").value = e.target.value;
  };
  $("#save-profile").onclick = () => guarded(async () => {
    const name = $("#profile-name").value.trim();
    await api("/api/profile", { name, conn: conn() });
    await loadMeta();
    $("#profile").value = name;
    toast(`Profile ${name} saved (.machines/${name}.conf)`);
  });

  $$("[data-run]").forEach((b) => (b.onclick = () => run(b.dataset.run)));

  $("#probe").onclick = () => guarded(async () => {
    const { disks } = await api("/api/helper", { kind: "probe-disks", conn: conn(), ...secrets() });
    const table = $("#disk-table");
    table.hidden = false;
    table.querySelector("tbody").replaceChildren(...disks.map((d) => {
      const tr = document.createElement("tr");
      tr.innerHTML = `<td><code>${esc(d.path)}</code></td><td>${esc(d.size)}</td><td>${esc(d.model)}</td>
        <td><button class="btn small">select</button></td>`;
      tr.querySelector("button").onclick = () => {
        $("#conn").NIXHDD.value = d.path;
        toast(`Disk ${d.path} selected`);
      };
      return tr;
    }));
    $("#disks").replaceChildren(...disks.map((d) => option(d.path)));
  });

  $("#run-init").onclick = () => run("init", { confirm: $("#init-confirm").value.trim() });
  $("#run-setpw").onclick = () => run("set-password", { user: $("#pw-user").value });

  $("#tab-newhost").onsubmit = (e) => {
    e.preventDefault();
    const f = e.target;
    guarded(async () => {
      const r = await api("/api/new-host", {
        name: f.name.value.trim(),
        purpose: f.purpose.value.trim(),
        lanIp: f.lanIp.value.trim(),
        meshIp: f.meshIp.value.trim(),
        ports: csv(f.ports.value).map(Number),
        postgres: csv(f.postgres.value),
        paths: csv(f.paths.value),
        roles: $$('#roles input:checked').map((i) => i.value),
      });
      showOut("#newhost-out", `${r.created}\n\n${r.file}\n${r.diff}\nNext steps: ${r.next}`);
      toast(`${r.created} created`);
      loadMeta();
    });
  };

  $("#kg-run").onclick = () => guarded(async () => {
    const r = await api("/api/helper", { kind: "keygen", name: $("#kg-name").value.trim(), passphrase: $("#kg-pass").value });
    $("#kg-pass").value = "";
    showOut("#keys-out", `${r.key} created. Public key:\n\n${r.pub}`);
    toast(`${r.key} created`);
    await loadMeta();
    $("#cid-key").value = r.key;
  });
  $("#cid-run").onclick = () => guarded(async () => {
    const r = await api("/api/helper", { kind: "copy-id", key: $("#cid-key").value, conn: conn(), ...secrets() });
    showOut("#keys-out", `${r.output}\n\nFor users/lpj/nixos.nix (openssh.authorizedKeys.keys):\n"${r.pub}"`);
  });

  $("#status-btn").onclick = () => guarded(async () => {
    const r = await api("/api/helper", { kind: "status", conn: conn(), ...secrets() });
    showOut("#status-out", r.output || `(exit ${r.rc})`);
  });

  $("#cancel").onclick = () => currentJob && guarded(() => api(`/api/jobs/${currentJob.id}/cancel`, {}));

  $("#send-show").onchange = (e) => ($("#send-text").type = e.target.checked ? "text" : "password");
  $("#send").onsubmit = (e) => {
    e.preventDefault();
    if (!currentJob) return toast("No running process", true);
    const input = $("#send-text");
    guarded(() => api(`/api/jobs/${currentJob.id}/input`, { data: input.value }));
    input.value = "";
  };

  $("#token-save").onclick = () => {
    token = $("#token-input").value.trim();
    try { sessionStorage.setItem("deploy-token", token); } catch {}
    start();
  };
}

async function start() {
  try {
    await loadMeta();
    $("#token-box").hidden = true;
    loadJobs();
  } catch (e) {
    $("#token-box").hidden = false;
    toast(`No connection: ${e.message}`, true);
  }
}

$("#year").textContent = new Date().getFullYear();
readToken();
wire();
start();

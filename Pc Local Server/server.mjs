import { createServer } from "node:http";
import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { hostname, networkInterfaces, platform, homedir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";

export const APP_NAME = "NFC Instant Action PC Server";
export const DEFAULT_PORT = 8765;

const SERVER_DIR = dirname(fileURLToPath(import.meta.url));
export const CONFIG_PATH = join(SERVER_DIR, "config.json");
const DEFAULT_INBOX = join(SERVER_DIR, "inbox");
const DEFAULT_OUTBOX = join(SERVER_DIR, "outbox");
const MAX_LOGS = 80;

let server = null;
let serverStartedAt = null;
let requestLog = [];

function nowMs() {
  return Date.now();
}

function saveConfig() {
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2), "utf8");
}

function loadOrCreateConfig() {
  if (existsSync(CONFIG_PATH)) {
    const existing = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
    let changed = false;

    if (!existing.pc_id) {
      existing.pc_id = randomUUID();
      changed = true;
    }
    if (!existing.pairing_token) {
      existing.pairing_token = existing.device_token ?? randomUUID().replaceAll("-", "");
      changed = true;
    }
    if (!existing.trusted_devices) {
      existing.trusted_devices = {};
      changed = true;
    }
    if (!existing.outbox_dir) {
      existing.outbox_dir = DEFAULT_OUTBOX;
      changed = true;
    }

    if (changed) writeFileSync(CONFIG_PATH, JSON.stringify(existing, null, 2), "utf8");
    return existing;
  }

  const created = {
    pc_id: randomUUID(),
    host: "0.0.0.0",
    port: DEFAULT_PORT,
    pairing_token: randomUUID().replaceAll("-", ""),
    trusted_devices: {},
    inbox_dir: DEFAULT_INBOX,
    outbox_dir: DEFAULT_OUTBOX,
    allowed_commands: {
      open_inbox: { type: "open_path", path: DEFAULT_INBOX },
      open_downloads: { type: "open_path", path: join(homedir(), "Downloads") }
    }
  };

  writeFileSync(CONFIG_PATH, JSON.stringify(created, null, 2), "utf8");
  return created;
}

const config = loadOrCreateConfig();
export const inboxDir = resolve(config.inbox_dir ?? DEFAULT_INBOX);
export const outboxDir = resolve(config.outbox_dir ?? DEFAULT_OUTBOX);
mkdirSync(inboxDir, { recursive: true });
mkdirSync(outboxDir, { recursive: true });

export function localIps() {
  const ips = [];
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === "IPv4" && !entry.internal) {
        ips.push(entry.address);
      }
    }
  }
  return [...new Set(ips)].sort();
}

function logEvent(type, detail = {}) {
  requestLog.unshift({
    time: new Date().toISOString(),
    type,
    ...detail
  });
  requestLog = requestLog.slice(0, MAX_LOGS);
}

function sendJson(res, status, body) {
  const data = Buffer.from(JSON.stringify(body), "utf8");
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": data.length,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, X-Device-Id, X-Device-Token, X-Pairing-Token",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
  });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolveBody(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function safeFilename(name) {
  const cleaned = String(name)
    .split("")
    .filter((ch) => /[a-zA-Z0-9 ._\-()[\]]/.test(ch))
    .join("")
    .trim();
  return cleaned || `file-${nowMs()}`;
}

function uniquePath(directory, filename) {
  const clean = safeFilename(filename);
  const dot = clean.lastIndexOf(".");
  const stem = dot > 0 ? clean.slice(0, dot) : clean;
  const suffix = dot > 0 ? clean.slice(dot) : "";
  let target = join(directory, clean);
  let index = 1;

  while (existsSync(target)) {
    target = join(directory, `${stem}-${index}${suffix}`);
    index += 1;
  }

  return target;
}

function safeOutboxPath(filename) {
  const target = resolve(outboxDir, safeFilename(filename));
  const distance = relative(outboxDir, target);
  if (distance.startsWith("..") || resolve(distance) === distance) {
    throw new Error("Invalid filename");
  }
  return target;
}

function listOutboxFiles() {
  return readdirSync(outboxDir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => {
      const target = join(outboxDir, entry.name);
      const stats = statSync(target);
      return {
        name: entry.name,
        bytes: stats.size,
        modified_at: stats.mtime.toISOString()
      };
    })
    .sort((a, b) => b.modified_at.localeCompare(a.modified_at));
}

function run(command, args, options = {}) {
  return new Promise((resolveRun, reject) => {
    execFile(command, args, options, (error) => {
      if (error) reject(error);
      else resolveRun();
    });
  });
}

async function lockPc() {
  if (platform() !== "win32") {
    throw new Error("Lock PC is only implemented for Windows right now.");
  }

  await run("rundll32.exe", ["user32.dll,LockWorkStation"], { windowsHide: true });
}

async function sleepPc() {
  if (platform() !== "win32") {
    throw new Error("Sleep PC is only implemented for Windows right now.");
  }

  await run(
    "powershell",
    [
      "-NoProfile",
      "-Command",
      "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)"
    ],
    { windowsHide: true }
  );
}

async function openChrome() {
  if (platform() !== "win32") {
    throw new Error("Open Chrome is only implemented for Windows right now.");
  }

  const candidates = [
    join(process.env.PROGRAMFILES ?? "", "Google", "Chrome", "Application", "chrome.exe"),
    join(process.env["PROGRAMFILES(X86)"] ?? "", "Google", "Chrome", "Application", "chrome.exe"),
    join(process.env.LOCALAPPDATA ?? "", "Google", "Chrome", "Application", "chrome.exe")
  ];
  const chromePath = candidates.find((candidate) => candidate && existsSync(candidate));

  if (chromePath) {
    await run(chromePath, [], { windowsHide: true });
    return;
  }

  await run("cmd", ["/c", "start", "", "chrome"], { windowsHide: true });
}

async function setClipboard(text) {
  if (platform() !== "win32") {
    throw new Error("Clipboard write is only implemented for Windows right now.");
  }

  await new Promise((resolveClipboard, reject) => {
    const child = spawn(
      "powershell",
      ["-NoProfile", "-Command", "Set-Clipboard -Value $input"],
      { windowsHide: true }
    );
    child.stdin.end(String(text));
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) resolveClipboard();
      else reject(new Error(`Set-Clipboard exited with code ${code}`));
    });
  });
}

export async function openTarget(target) {
  if (platform() === "win32") {
    await run("cmd", ["/c", "start", "", String(target)], { windowsHide: true });
    return;
  }
  throw new Error("Opening targets is only implemented for Windows right now.");
}

async function runAllowedCommand(commandId) {
  if (commandId === "lock_pc") {
    await lockPc();
    return { command_id: commandId, result: "locked" };
  }

  if (commandId === "sleep_pc") {
    setTimeout(() => {
      sleepPc().catch((error) => logEvent("command_error", { action: commandId, error: error.message }));
    }, 600);
    return { command_id: commandId, result: "sleep_requested" };
  }

  if (commandId === "open_chrome") {
    await openChrome();
    return { command_id: commandId, result: "opened" };
  }

  const command = config.allowed_commands?.[commandId];
  if (!command) {
    throw new Error(`Command is not allowed: ${commandId}`);
  }

  if (command.type === "open_path") {
    await openTarget(resolve(command.path));
    return { command_id: commandId, result: "opened" };
  }

  throw new Error(`Unsupported command type: ${command.type}`);
}

async function handleIntent(intent) {
  const type = intent?.type;
  const payload = intent?.payload ?? {};

  if (type === "url") {
    const url = String(payload.url ?? "").trim();
    if (!url) throw new Error("Missing payload.url");
    await openTarget(url);
    return { action: "url", opened: url };
  }

  if (type === "clipboard") {
    const text = String(payload.text ?? "");
    await setClipboard(text);
    return { action: "clipboard", length: text.length };
  }

  if (type === "file") {
    const filename = String(payload.filename ?? `file-${nowMs()}`);
    if (!payload.content_base64) throw new Error("Missing payload.content_base64");
    const data = Buffer.from(String(payload.content_base64), "base64");
    const target = uniquePath(inboxDir, filename);
    writeFileSync(target, data);
    return { action: "file", saved_to: target, bytes: data.length };
  }

  if (type === "command") {
    const commandId = String(payload.command_id ?? "");
    return { action: "command", ...(await runAllowedCommand(commandId)) };
  }

  if (type === "continue") {
    if (payload.url) return handleIntent({ type: "url", payload: { url: payload.url } });
    if (payload.text) return handleIntent({ type: "clipboard", payload: { text: payload.text } });
    throw new Error("Continue intent has no supported payload");
  }

  throw new Error(`Unsupported intent type: ${type}`);
}

function isAuthorized(req) {
  const deviceId = req.headers["x-device-id"];
  const deviceToken = req.headers["x-device-token"];
  const trustedDevice = config.trusted_devices?.[deviceId];
  if (!trustedDevice || trustedDevice.token !== deviceToken) return false;

  trustedDevice.last_seen_at = new Date().toISOString();
  saveConfig();
  return true;
}

function isPairingAuthorized(req) {
  return req.headers["x-pairing-token"] === config.pairing_token;
}

async function handleRequest(req, res) {
  const requestUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  const route = requestUrl.pathname;

  if (req.method === "OPTIONS") {
    sendJson(res, 200, { ok: true });
    return;
  }

  if (req.method === "GET" && route === "/health") {
    sendJson(res, 200, {
      ok: true,
      app: APP_NAME,
      pc_id: config.pc_id,
      pc_name: hostname(),
      time_ms: nowMs(),
      inbox_dir: inboxDir
    });
    return;
  }

  if (req.method === "GET" && route === "/pair") {
    const ips = localIps();
    const port = Number(config.port ?? DEFAULT_PORT);
    sendJson(res, 200, {
      app: APP_NAME,
      pc_id: config.pc_id,
      pc_name: hostname(),
      port,
      ips,
      base_urls: ips.map((ip) => `http://${ip}:${port}`)
    });
    return;
  }

  if (req.method === "POST" && route === "/api/devices/register") {
    if (!isPairingAuthorized(req)) {
      logEvent("register_denied", { device: "unknown" });
      sendJson(res, 401, { ok: false, error: "Invalid pairing token" });
      return;
    }

    try {
      const body = await readBody(req);
      const registration = JSON.parse(body.toString("utf8"));
      const deviceId = String(registration.device_id ?? "").trim();
      const deviceName = String(registration.device_name ?? "Android device").trim();
      if (!deviceId) throw new Error("Missing device_id");

      const deviceToken = randomUUID().replaceAll("-", "");
      config.trusted_devices[deviceId] = {
        name: deviceName,
        token: deviceToken,
        trusted_at: new Date().toISOString(),
        last_seen_at: null
      };
      saveConfig();
      logEvent("device_registered", { device: deviceName });

      sendJson(res, 200, {
        ok: true,
        pc_id: config.pc_id,
        device_id: deviceId,
        device_token: deviceToken
      });
    } catch (error) {
      sendJson(res, 400, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && !isAuthorized(req)) {
    logEvent("unauthorized", { route });
    sendJson(res, 401, { ok: false, error: "Unauthorized" });
    return;
  }

  if (req.method === "GET" && route.startsWith("/api/request-files") && !isAuthorized(req)) {
    logEvent("unauthorized", { route });
    sendJson(res, 401, { ok: false, error: "Unauthorized" });
    return;
  }

  if (req.method === "GET" && route === "/api/request-files") {
    try {
      sendJson(res, 200, { ok: true, files: listOutboxFiles() });
    } catch (error) {
      sendJson(res, 400, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "GET" && route === "/api/request-files/download") {
    try {
      const filename = requestUrl.searchParams.get("filename") ?? "";
      const target = safeOutboxPath(filename);
      if (!existsSync(target) || !statSync(target).isFile()) {
        sendJson(res, 404, { ok: false, error: "File not found" });
        return;
      }

      const data = readFileSync(target);
      logEvent("file_requested", { filename, bytes: data.length });
      res.writeHead(200, {
        "Content-Type": "application/octet-stream",
        "Content-Length": data.length,
        "Content-Disposition": `attachment; filename="${safeFilename(filename)}"`,
        "Access-Control-Allow-Origin": "*"
      });
      res.end(data);
    } catch (error) {
      sendJson(res, 400, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && route === "/api/intent") {
    try {
      const body = await readBody(req);
      const intent = JSON.parse(body.toString("utf8"));
      const result = await handleIntent(intent);
      logEvent("intent", {
        action: result.command_id ?? result.action ?? intent.type
      });
      sendJson(res, 200, { ok: true, result });
    } catch (error) {
      sendJson(res, 400, { ok: false, error: error.message });
    }
    return;
  }

  if (req.method === "POST" && route === "/api/files") {
    try {
      const filename = requestUrl.searchParams.get("filename") ?? `upload-${nowMs()}.bin`;
      const body = await readBody(req);
      const target = uniquePath(inboxDir, filename);
      writeFileSync(target, body);
      logEvent("file", { filename, bytes: body.length });
      sendJson(res, 200, { ok: true, saved_to: target, bytes: body.length });
    } catch (error) {
      sendJson(res, 400, { ok: false, error: error.message });
    }
    return;
  }

  sendJson(res, 404, { ok: false, error: "Not found" });
}

export function getServerState() {
  const port = Number(config.port ?? DEFAULT_PORT);
  return {
    app: APP_NAME,
    running: Boolean(server),
    started_at: serverStartedAt,
    pc_id: config.pc_id,
    pc_name: hostname(),
    port,
    ips: localIps(),
    base_urls: localIps().map((ip) => `http://${ip}:${port}`),
    pairing_token: config.pairing_token,
    inbox_dir: inboxDir,
    outbox_dir: outboxDir,
    outbox_files: listOutboxFiles(),
    trusted_devices: Object.entries(config.trusted_devices ?? {}).map(([id, device]) => ({
      id,
      name: device.name,
      trusted_at: device.trusted_at,
      last_seen_at: device.last_seen_at
    })),
    request_log: requestLog
  };
}

export function startServer() {
  if (server) return Promise.resolve(getServerState());

  const host = config.host ?? "0.0.0.0";
  const port = Number(config.port ?? DEFAULT_PORT);
  server = createServer((req, res) => {
    handleRequest(req, res).catch((error) => {
      sendJson(res, 500, { ok: false, error: error.message });
    });
  });

  return new Promise((resolveStart, reject) => {
    server.once("error", (error) => {
      server = null;
      serverStartedAt = null;
      reject(error);
    });
    server.listen(port, host, () => {
      serverStartedAt = new Date().toISOString();
      logEvent("server_started", { port });
      resolveStart(getServerState());
    });
  });
}

export function stopServer() {
  if (!server) return Promise.resolve(getServerState());

  return new Promise((resolveStop, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      server = null;
      serverStartedAt = null;
      logEvent("server_stopped");
      resolveStop(getServerState());
    });
  });
}

export function revokeDevice(deviceId) {
  const device = config.trusted_devices?.[deviceId];
  if (!device) return getServerState();

  delete config.trusted_devices[deviceId];
  saveConfig();
  logEvent("device_revoked", { device: device.name ?? deviceId });
  return getServerState();
}

export function printStartupInfo() {
  const state = getServerState();
  console.log(APP_NAME);
  console.log(`Config: ${CONFIG_PATH}`);
  console.log(`Inbox : ${inboxDir}`);
  console.log(`Outbox: ${outboxDir}`);
  console.log(`Pairing token : ${state.pairing_token}`);
  console.log(`Trusted devices: ${state.trusted_devices.length}`);
  for (const url of state.base_urls) console.log(`URL   : ${url}`);
  console.log("Health: /health");
  console.log("Pair  : /pair");
}

const isDirectRun = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isDirectRun) {
  startServer()
    .then(() => printStartupInfo())
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

import { createServer } from "node:http";
import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { hostname, networkInterfaces, platform, homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";

const APP_NAME = "NFC Instant Action PC Server";
const DEFAULT_PORT = 8765;
const SERVER_DIR = dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = join(SERVER_DIR, "config.json");
const DEFAULT_INBOX = join(SERVER_DIR, "inbox");

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

    if (changed) writeFileSync(CONFIG_PATH, JSON.stringify(existing, null, 2), "utf8");
    return existing;
  }

  const config = {
    pc_id: randomUUID(),
    host: "0.0.0.0",
    port: DEFAULT_PORT,
    pairing_token: randomUUID().replaceAll("-", ""),
    trusted_devices: {},
    inbox_dir: DEFAULT_INBOX,
    allowed_commands: {
      open_inbox: { type: "open_path", path: DEFAULT_INBOX },
      open_downloads: { type: "open_path", path: join(homedir(), "Downloads") }
    }
  };

  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2), "utf8");
  return config;
}

const config = loadOrCreateConfig();
const inboxDir = resolve(config.inbox_dir ?? DEFAULT_INBOX);
mkdirSync(inboxDir, { recursive: true });

function nowMs() {
  return Date.now();
}

function localIps() {
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

function run(command, args, options = {}) {
  return new Promise((resolveRun, reject) => {
    execFile(command, args, options, (error) => {
      if (error) reject(error);
      else resolveRun();
    });
  });
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

async function openTarget(target) {
  if (platform() === "win32") {
    await run("cmd", ["/c", "start", "", String(target)], { windowsHide: true });
    return;
  }
  throw new Error("Opening targets is only implemented for Windows right now.");
}

async function runAllowedCommand(commandId) {
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
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2), "utf8");
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
      writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2), "utf8");

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
    sendJson(res, 401, { ok: false, error: "Unauthorized" });
    return;
  }

  if (req.method === "POST" && route === "/api/intent") {
    try {
      const body = await readBody(req);
      const intent = JSON.parse(body.toString("utf8"));
      const result = await handleIntent(intent);
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
      sendJson(res, 200, { ok: true, saved_to: target, bytes: body.length });
    } catch (error) {
      sendJson(res, 400, { ok: false, error: error.message });
    }
    return;
  }

  sendJson(res, 404, { ok: false, error: "Not found" });
}

const host = config.host ?? "0.0.0.0";
const port = Number(config.port ?? DEFAULT_PORT);
const server = createServer((req, res) => {
  handleRequest(req, res).catch((error) => {
    sendJson(res, 500, { ok: false, error: error.message });
  });
});

server.listen(port, host, () => {
  console.log(APP_NAME);
  console.log(`Config: ${CONFIG_PATH}`);
  console.log(`Inbox : ${inboxDir}`);
  console.log(`Pairing token : ${config.pairing_token}`);
  console.log(`Trusted devices: ${Object.keys(config.trusted_devices ?? {}).length}`);
  for (const ip of localIps()) console.log(`URL   : http://${ip}:${port}`);
  console.log("Health: /health");
  console.log("Pair  : /pair");
});

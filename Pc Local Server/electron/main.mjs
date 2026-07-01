import { app, BrowserWindow, clipboard, dialog, ipcMain, shell } from "electron";
import { copyFileSync, existsSync } from "node:fs";
import { basename, dirname, join, parse } from "node:path";
import { fileURLToPath } from "node:url";
import {
  getServerState,
  inboxDir,
  openTarget,
  outboxDir,
  revokeDevice,
  startServer,
  stopServer
} from "../server.mjs";

const APP_TITLE = "Instant Action PC";
const __dirname = dirname(fileURLToPath(import.meta.url));

let mainWindow = null;

function uniqueOutboxPath(filename) {
  const cleanName = basename(String(filename || "file")).replace(/[\\/:*?"<>|]/g, "_") || "file";
  const parsed = parse(cleanName);
  let target = join(outboxDir, cleanName);
  let index = 1;

  while (existsSync(target)) {
    target = join(outboxDir, `${parsed.name}-${index}${parsed.ext}`);
    index += 1;
  }

  return target;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1040,
    height: 720,
    minWidth: 880,
    minHeight: 620,
    title: APP_TITLE,
    backgroundColor: "#0d1117",
    webPreferences: {
      preload: join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadFile(join(__dirname, "renderer", "index.html"));
}

app.whenReady().then(async () => {
  await startServer();
  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", async () => {
  await stopServer();
  if (process.platform !== "darwin") app.quit();
});

ipcMain.handle("server:getState", () => getServerState());
ipcMain.handle("server:start", () => startServer());
ipcMain.handle("server:stop", () => stopServer());
ipcMain.handle("server:revokeDevice", (_event, deviceId) => revokeDevice(deviceId));

ipcMain.handle("ui:copy", (_event, text) => {
  clipboard.writeText(String(text ?? ""));
  return true;
});

ipcMain.handle("ui:openInbox", async () => {
  await openTarget(inboxDir);
  return true;
});

ipcMain.handle("ui:openOutbox", async () => {
  await openTarget(outboxDir);
  return true;
});

ipcMain.handle("ui:addFilesToOutbox", async () => {
  const selection = await dialog.showOpenDialog(mainWindow, {
    title: "Add files to Outbox",
    properties: ["openFile", "multiSelections"]
  });
  if (selection.canceled) return { copied: 0 };

  let copied = 0;
  for (const source of selection.filePaths) {
    copyFileSync(source, uniqueOutboxPath(source));
    copied += 1;
  }
  return { copied };
});

ipcMain.handle("ui:openExternal", async (_event, url) => {
  await shell.openExternal(String(url));
  return true;
});

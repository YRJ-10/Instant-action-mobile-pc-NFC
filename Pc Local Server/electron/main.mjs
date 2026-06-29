import { app, BrowserWindow, clipboard, ipcMain, shell } from "electron";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  getServerState,
  inboxDir,
  openTarget,
  revokeDevice,
  startServer,
  stopServer
} from "../server.mjs";

const APP_TITLE = "Instant Action PC";
const __dirname = dirname(fileURLToPath(import.meta.url));

let mainWindow = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1040,
    height: 720,
    minWidth: 880,
    minHeight: 620,
    title: APP_TITLE,
    backgroundColor: "#f6f7f9",
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

ipcMain.handle("ui:openExternal", async (_event, url) => {
  await shell.openExternal(String(url));
  return true;
});

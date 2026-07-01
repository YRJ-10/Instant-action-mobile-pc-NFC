const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("instantAction", {
  getState: () => ipcRenderer.invoke("server:getState"),
  startServer: () => ipcRenderer.invoke("server:start"),
  stopServer: () => ipcRenderer.invoke("server:stop"),
  revokeDevice: (deviceId) => ipcRenderer.invoke("server:revokeDevice", deviceId),
  copy: (text) => ipcRenderer.invoke("ui:copy", text),
  openInbox: () => ipcRenderer.invoke("ui:openInbox"),
  openOutbox: () => ipcRenderer.invoke("ui:openOutbox"),
  addFilesToOutbox: () => ipcRenderer.invoke("ui:addFilesToOutbox"),
  openExternal: (url) => ipcRenderer.invoke("ui:openExternal", url)
});

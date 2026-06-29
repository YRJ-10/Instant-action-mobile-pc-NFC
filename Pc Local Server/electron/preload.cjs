const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("instantAction", {
  getState: () => ipcRenderer.invoke("server:getState"),
  startServer: () => ipcRenderer.invoke("server:start"),
  stopServer: () => ipcRenderer.invoke("server:stop"),
  revokeDevice: (deviceId) => ipcRenderer.invoke("server:revokeDevice", deviceId),
  copy: (text) => ipcRenderer.invoke("ui:copy", text),
  openInbox: () => ipcRenderer.invoke("ui:openInbox"),
  openExternal: (url) => ipcRenderer.invoke("ui:openExternal", url)
});

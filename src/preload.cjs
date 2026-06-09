const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("rekordboxHistory", {
  getHistory: (options) => ipcRenderer.invoke("rekordbox-history:get", options),
  refreshHistory: () => ipcRenderer.invoke("rekordbox-history:get", { force: true }),
  copyText: (text) => ipcRenderer.invoke("clipboard:write", text),
  enterFullscreen: () => ipcRenderer.invoke("enter-fullscreen"),
  exitFullscreen: () => ipcRenderer.invoke("exit-fullscreen"),
  toggleFullscreen: () => ipcRenderer.invoke("toggle-fullscreen")
});

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("rekordboxHistory", {
  getHistory: (options) => ipcRenderer.invoke("rekordbox-history:get", options),
  refreshHistory: () => ipcRenderer.invoke("rekordbox-history:get", { force: true }),
  enterFullscreen: () => ipcRenderer.invoke("enter-fullscreen"),
  exitFullscreen: () => ipcRenderer.invoke("exit-fullscreen"),
  toggleFullscreen: () => ipcRenderer.invoke("toggle-fullscreen")
});

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("rekordboxHistory", {
  getHistory: (options) => ipcRenderer.invoke("rekordbox-history:get", options),
  refreshHistory: () => ipcRenderer.invoke("rekordbox-history:get", { force: true }),
  getSettings: () => ipcRenderer.invoke("rekordbox-history:settings"),
  chooseDatabase: () => ipcRenderer.invoke("rekordbox-history:choose-database"),
  setDatabase: (path) => ipcRenderer.invoke("rekordbox-history:set-database", path),
  useDefaultDatabase: () => ipcRenderer.invoke("rekordbox-history:use-default-database"),
  clearDatabase: () => ipcRenderer.invoke("rekordbox-history:clear-database"),
  copyText: (text) => ipcRenderer.invoke("clipboard:write", text),
  enterFullscreen: () => ipcRenderer.invoke("enter-fullscreen"),
  exitFullscreen: () => ipcRenderer.invoke("exit-fullscreen"),
  toggleFullscreen: () => ipcRenderer.invoke("toggle-fullscreen")
});

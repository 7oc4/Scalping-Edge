const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("scalpingDesktop", {
  submitApiKey: (key) => ipcRenderer.send("desktop:api-key-submit", key),
  cancelApiKey: () => ipcRenderer.send("desktop:api-key-cancel"),
  onApiKeyError: (callback) => {
    const listener = (_event, message) => callback(message);
    ipcRenderer.on("desktop:api-key-error", listener);
    return () => ipcRenderer.removeListener("desktop:api-key-error", listener);
  },
});

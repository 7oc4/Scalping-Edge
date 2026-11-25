const { app, BrowserWindow, dialog, ipcMain, shell } = require("electron");
const { spawn } = require("node:child_process");
const http = require("node:http");
const net = require("node:net");
const path = require("node:path");
const fs = require("node:fs");

const isWindows = process.platform === "win32";
let serverProcess;
let mainWindow;
let keyWindow;
let appOrigin;

function getRuntimeRoot() {
  return app.isPackaged
    ? path.join(process.resourcesPath, "app-runtime")
    : path.resolve(__dirname, "..");
}

function createKeyWindow() {
  return new Promise((resolve, reject) => {
    let settled = false;
    keyWindow = new BrowserWindow({
      width: 540,
      height: 600,
      minWidth: 460,
      minHeight: 540,
      resizable: true,
      minimizable: false,
      maximizable: false,
      autoHideMenuBar: true,
      backgroundColor: "#07140b",
      title: "Scalping Edge — Configuração",
      webPreferences: {
        preload: path.join(__dirname, "preload.cjs"),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
      },
    });

    const currentWindow = keyWindow;
    const cleanup = () => {
      ipcMain.removeListener("desktop:api-key-submit", onSubmit);
      ipcMain.removeListener("desktop:api-key-cancel", onCancel);
      currentWindow.removeListener("closed", onClosed);
    };
    const finish = (callback, value) => {
      if (settled) return;
      settled = true;
      cleanup();
      if (keyWindow === currentWindow) keyWindow = null;
      callback(value);
    };
    const onSubmit = (event, submittedKey) => {
      if (event.sender !== currentWindow.webContents) return;
      const key = typeof submittedKey === "string" ? submittedKey.trim() : "";
      if (!key) {
        currentWindow.webContents.send("desktop:api-key-error", "Informe uma chave válida para continuar.");
        return;
      }
      finish(resolve, key);
      currentWindow.close();
    };
    const onCancel = (event) => {
      if (event.sender !== currentWindow.webContents) return;
      finish(reject, new Error("A configuração da chave foi cancelada."));
      app.quit();
    };
    const onClosed = () => finish(reject, new Error("A janela de configuração foi fechada."));

    ipcMain.on("desktop:api-key-submit", onSubmit);
    ipcMain.on("desktop:api-key-cancel", onCancel);
    currentWindow.once("closed", onClosed);
    currentWindow.loadFile(path.join(__dirname, "key.html"));
  });
}

function findFreePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      probe.close((error) => {
        if (error) reject(error);
        else resolve(address.port);
      });
    });
  });
}

function checkServer(port) {
  return new Promise((resolve) => {
    const request = http.get(
      { hostname: "127.0.0.1", port, path: "/", timeout: 1000 },
      (response) => {
        response.resume();
        response.once("end", () => resolve(response.statusCode === 200));
      },
    );
    request.once("timeout", () => request.destroy());
    request.once("error", () => resolve(false));
  });
}

async function waitForServer(port, processState, output) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (processState.exited) {
      throw new Error(
        `O servidor local encerrou antes de iniciar.${output.value ? `\n\n${output.value}` : ""}`,
      );
    }
    if (await checkServer(port)) return;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(
    `O servidor local não respondeu em 30 segundos.${output.value ? `\n\n${output.value}` : ""}`,
  );
}

function startServer(apiKey, port) {
  const runtimeRoot = getRuntimeRoot();
  const startScript = path.join(runtimeRoot, "src", "start.ps1");
  if (!fs.existsSync(startScript)) {
    throw new Error(`Não foi encontrado o servidor do aplicativo em:\n${startScript}`);
  }

  const userData = app.getPath("userData");
  const logDirectory = path.join(userData, "logs");
  const dataDirectory = path.join(userData, "data");
  fs.mkdirSync(logDirectory, { recursive: true });
  fs.mkdirSync(dataDirectory, { recursive: true });

  const childEnv = {
    ...process.env,
    OPENAI_API_KEY: apiKey,
    ZNX_PORT: String(port),
    ZNX_NO_BROWSER: "1",
    ZNX_LOG_DIR: logDirectory,
    ZNX_OUTCOMES_PATH: path.join(dataDirectory, "outcomes.jsonl"),
  };
  const child = spawn(
    "powershell.exe",
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      startScript,
    ],
    {
      cwd: runtimeRoot,
      env: childEnv,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );
  delete childEnv.OPENAI_API_KEY;

  const processState = { exited: false };
  const output = { value: "" };
  const collectOutput = (chunk) => {
    output.value = `${output.value}${chunk.toString()}`.slice(-8000);
  };
  child.stdout.on("data", collectOutput);
  child.stderr.on("data", collectOutput);
  child.once("error", (error) => {
    processState.exited = true;
    output.value += `\n${error.message}`;
  });
  child.once("exit", (code) => {
    processState.exited = true;
    processState.exitCode = code;
  });

  serverProcess = child;
  return { processState, output };
}

function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 940,
    minWidth: 800,
    minHeight: 620,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: "#07140b",
    title: "Scalping Edge",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    try {
      const target = new URL(url);
      if (target.protocol === "https:" || target.protocol === "http:") {
        shell.openExternal(target.href);
      }
    } catch (error) {
      console.error("Link externo inválido bloqueado.", error);
    }
    return { action: "deny" };
  });
  mainWindow.webContents.on("will-navigate", (event, url) => {
    if (new URL(url).origin === appOrigin) return;
    event.preventDefault();
    try {
      const target = new URL(url);
      if (target.protocol === "https:" || target.protocol === "http:") {
        shell.openExternal(target.href);
      }
    } catch (error) {
      console.error("Navegação externa inválida bloqueada.", error);
    }
  });
  mainWindow.once("ready-to-show", () => mainWindow.show());
  mainWindow.maximize();
  mainWindow.loadURL(`${appOrigin}/`);
}

async function launchApp() {
  if (!isWindows) {
    throw new Error("Esta versão desktop está preparada para Windows.");
  }

  const apiKey = process.env.OPENAI_API_KEY || (await createKeyWindow());
  const port = await findFreePort();
  appOrigin = `http://127.0.0.1:${port}`;
  const { processState, output } = startServer(apiKey, port);
  await waitForServer(port, processState, output);
  createMainWindow();
}

app.whenReady().then(async () => {
  try {
    await launchApp();
  } catch (error) {
    if (error.message !== "A configuração da chave foi cancelada.") {
      await dialog.showMessageBox({
        type: "error",
        title: "Não foi possível iniciar o Scalping Edge",
        message: "O aplicativo não conseguiu iniciar o servidor local.",
        detail: error.message,
      });
    }
    app.quit();
  }
});

app.on("before-quit", () => {
  if (serverProcess && !serverProcess.killed) serverProcess.kill();
});

app.on("window-all-closed", () => {
  if (mainWindow && mainWindow.isDestroyed()) app.quit();
});

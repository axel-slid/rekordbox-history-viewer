const { app, BrowserWindow, clipboard, ipcMain, session } = require("electron");
const { spawn } = require("node:child_process");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");

const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);
const devServerUrl = process.env.VITE_DEV_SERVER_URL || "http://127.0.0.1:5173";
let historyCache = null;

function getProjectRoot() {
  return path.resolve(__dirname, "..");
}

async function pathExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function pythonBinForEnv(envDir) {
  return process.platform === "win32"
    ? path.join(envDir, "Scripts", "python.exe")
    : path.join(envDir, "bin", "python");
}

function runProcess(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      ...options,
      env: {
        ...process.env,
        PYTHONUNBUFFERED: "1",
        ...(options.env || {})
      }
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
        return;
      }
      reject(new Error(stderr || stdout || `${command} exited with code ${code}`));
    });
  });
}

async function findPython() {
  const root = getProjectRoot();
  const appEnv = app.isReady() ? pythonBinForEnv(path.join(app.getPath("userData"), "python-env")) : "";
  const candidates = [
    appEnv,
    path.join(root, ".venv-rekordbox", "bin", "python"),
    path.join(root, ".venv", "bin", "python"),
    "python3",
    "python"
  ];

  for (const candidate of candidates) {
    if (!candidate) continue;
    if (candidate.includes(path.sep) && !(await pathExists(candidate))) continue;
    return candidate;
  }

  return "python3";
}

async function pythonHasRekordbox(pythonPath) {
  try {
    await runProcess(pythonPath, ["-c", "import pyrekordbox"], { cwd: getProjectRoot() });
    return true;
  } catch {
    return false;
  }
}

async function ensurePythonEnvironment() {
  const root = getProjectRoot();
  const requirementsPath = path.join(root, "requirements.txt");
  const pythonPath = await findPython();
  if (await pythonHasRekordbox(pythonPath)) return pythonPath;

  const envDir = path.join(app.getPath("userData"), "python-env");
  const envPython = pythonBinForEnv(envDir);
  const basePython = pythonPath.includes(path.sep) && pythonPath === envPython ? "python3" : pythonPath;

  if (!(await pathExists(envPython))) {
    await fs.mkdir(envDir, { recursive: true });
    await runProcess(basePython, ["-m", "venv", envDir], { cwd: root });
  }

  await runProcess(envPython, ["-m", "pip", "install", "--upgrade", "pip"], { cwd: root });
  await runProcess(envPython, ["-m", "pip", "install", "-r", requirementsPath], { cwd: root });

  if (!(await pythonHasRekordbox(envPython))) {
    throw new Error("Python setup finished, but pyrekordbox could not be imported.");
  }

  return envPython;
}

async function readRekordboxHistory({ force = false } = {}) {
  if (historyCache && !force) return historyCache;

  const scriptPath = path.join(getProjectRoot(), "scripts", "extract_rekordbox_history.py");
  const pythonPath = await ensurePythonEnvironment();

  return new Promise((resolve, reject) => {
    const child = spawn(pythonPath, [scriptPath], {
      cwd: getProjectRoot(),
      env: {
        ...process.env,
        PYTHONUNBUFFERED: "1",
        REKORDBOX_HISTORY_HOME: os.homedir(),
        REKORDBOX_HISTORY_SKIP_SPOTIFY_LOOKUP: force ? "0" : "1"
      }
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(stderr || `Extractor exited with code ${code}`));
        return;
      }

      try {
        historyCache = JSON.parse(stdout);
        resolve(historyCache);
      } catch (error) {
        reject(new Error(`Extractor returned invalid JSON: ${error.message}\n${stderr}`));
      }
    });
  });
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 960,
    minHeight: 600,
    backgroundColor: "#05050a",
    title: "Rekordbox Played Track History",
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });

  win.once("ready-to-show", () => win.show());

  if (isDev) {
    win.loadURL(devServerUrl);
  } else {
    win.loadFile(path.join(__dirname, "../dist/index.html"));
  }
}

app.whenReady().then(() => {
  session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback) => {
    callback(permission === "media");
  });

  ipcMain.handle("toggle-fullscreen", (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return false;
    win.setFullScreen(!win.isFullScreen());
    return win.isFullScreen();
  });

  ipcMain.handle("enter-fullscreen", (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return false;
    win.setFullScreen(true);
    return true;
  });

  ipcMain.handle("exit-fullscreen", (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return false;
    win.setFullScreen(false);
    return false;
  });

  ipcMain.handle("rekordbox-history:get", (_event, options = {}) => readRekordboxHistory(options));
  ipcMain.handle("clipboard:write", (_event, text) => {
    clipboard.writeText(String(text || ""));
    return true;
  });

  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

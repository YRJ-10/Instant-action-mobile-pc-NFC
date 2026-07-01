const api = window.instantAction;

const powerButton = document.querySelector("#powerButton");
const statusPill = document.querySelector("#statusPill");
const pcName = document.querySelector("#pcName");
const port = document.querySelector("#port");
const pairingToken = document.querySelector("#pairingToken");
const copyTokenButton = document.querySelector("#copyTokenButton");
const openInboxButton = document.querySelector("#openInboxButton");
const openOutboxButton = document.querySelector("#openOutboxButton");
const addOutboxButton = document.querySelector("#addOutboxButton");
const urlList = document.querySelector("#urlList");
const deviceList = document.querySelector("#deviceList");
const deviceCount = document.querySelector("#deviceCount");
const logList = document.querySelector("#logList");

let state = null;
let busy = false;

function formatDate(value) {
  if (!value) return "-";
  return new Date(value).toLocaleString();
}

function setBusy(nextBusy) {
  busy = nextBusy;
  powerButton.disabled = busy;
}

async function refresh() {
  state = await api.getState();
  render();
}

function render() {
  const running = Boolean(state.running);
  statusPill.textContent = running ? "Running" : "Stopped";
  statusPill.classList.toggle("running", running);
  powerButton.textContent = running ? "Stop Server" : "Start Server";
  powerButton.classList.toggle("off", !running);

  pcName.textContent = state.pc_name ?? "-";
  port.textContent = String(state.port ?? "-");
  pairingToken.textContent = state.pairing_token ?? "-";

  urlList.innerHTML = "";
  for (const url of state.base_urls ?? []) {
    const row = document.createElement("div");
    row.className = "url-row";
    row.innerHTML = `<code>${url}</code><button class="small-button" type="button">Copy</button>`;
    row.querySelector("button").addEventListener("click", () => api.copy(url));
    urlList.append(row);
  }
  if (!urlList.children.length) {
    urlList.innerHTML = `<div class="empty">No active network URL</div>`;
  }

  renderDevices();
  renderLogs();
}

function renderDevices() {
  const devices = state.trusted_devices ?? [];
  deviceCount.textContent = `${devices.length} device${devices.length === 1 ? "" : "s"}`;
  deviceList.innerHTML = "";

  for (const device of devices) {
    const row = document.createElement("div");
    row.className = "device-row";
    row.innerHTML = `
      <div>
        <div class="device-name">${device.name || "Android device"}</div>
        <div class="muted">${device.id}</div>
      </div>
      <div>
        <div class="muted">Trusted</div>
        <div>${formatDate(device.trusted_at)}</div>
      </div>
      <div>
        <div class="muted">Last seen</div>
        <div>${formatDate(device.last_seen_at)}</div>
      </div>
      <button class="revoke-button" type="button">Revoke</button>
    `;
    row.querySelector("button").addEventListener("click", async () => {
      const confirmed = confirm(`Revoke ${device.name || device.id}?`);
      if (!confirmed) return;
      state = await api.revokeDevice(device.id);
      render();
    });
    deviceList.append(row);
  }

  if (!devices.length) {
    deviceList.innerHTML = `<div class="empty">No trusted devices yet</div>`;
  }
}

function renderLogs() {
  const logs = state.request_log ?? [];
  logList.innerHTML = "";

  for (const log of logs) {
    const detail = log.device || log.action || log.filename || log.route || log.port || "";
    const row = document.createElement("div");
    row.className = "log-row";
    row.innerHTML = `
      <div class="muted">${formatDate(log.time)}</div>
      <strong>${log.type}</strong>
      <div class="log-detail">${detail}</div>
    `;
    logList.append(row);
  }

  if (!logs.length) {
    logList.innerHTML = `<div class="empty">No activity yet</div>`;
  }
}

powerButton.addEventListener("click", async () => {
  if (busy) return;
  setBusy(true);
  try {
    state = state.running ? await api.stopServer() : await api.startServer();
    render();
  } finally {
    setBusy(false);
  }
});

copyTokenButton.addEventListener("click", () => api.copy(state?.pairing_token ?? ""));
openInboxButton.addEventListener("click", () => api.openInbox());
openOutboxButton.addEventListener("click", () => api.openOutbox());
addOutboxButton.addEventListener("click", async () => {
  await api.addFilesToOutbox();
  await refresh();
});

refresh();
setInterval(refresh, 2500);

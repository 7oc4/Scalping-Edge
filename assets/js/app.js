"use strict";
/* Painel do Scalping Edge. Fonte TypeScript compilada para assets/js/app.js. */
const MAX_FILE_SIZE = 12 * 1024 * 1024;
const ACCEPTED_TYPES = new Set(["image/png", "image/jpeg", "image/webp"]);
const HISTORY_LIMIT = 25;
const HISTORY_DB_NAME = "chartly-local-history";
const HISTORY_STORE_NAME = "analyses";
const { normalizeAnalysisPayload, getAnalysisPresentation } = window.AnalysisFormat;
function requiredElement(root, selector) {
    const element = root.querySelector(selector);
    if (!element) {
        throw new Error(`Elemento obrigatório não encontrado: ${selector}`);
    }
    return element;
}
function $(selector) {
    return requiredElement(document, selector);
}
function errorMessage(error) {
    return error instanceof Error ? error.message : "Ocorreu um erro inesperado.";
}
const startupLoader = $("#startup-loader");
window.setTimeout(() => {
    startupLoader.hidden = true;
}, 6500);
const imageInput = $("#image-input");
const dropZone = $("#drop-zone");
const previewCard = $("#preview-card");
const previewFrame = $("#preview-frame");
const levelOverlay = $("#level-overlay");
const levelToggle = $("#level-toggle");
const levelOverlayNote = $("#level-overlay-note");
const imagePreview = $("#image-preview");
const fileName = $("#file-name");
const fileSize = $("#file-size");
const removeImageButton = $("#remove-image");
const uploadMessage = $("#upload-message");
const analyzeButton = $("#analyze-button");
const analysisForm = $("#analysis-form");
const marketType = $("#market-type");
const assetInput = $("#asset");
const forexAssetSelect = $("#forex-asset");
const cryptoAssetSelect = $("#crypto-asset");
const commodityAssetSelect = $("#commodity-asset");
const stockAssetSelect = $("#stock-asset");
const assetLabel = $("#asset-label");
const timeframe = $("#timeframe");
const analysisResult = $("#analysis-result");
const resultEyebrow = $("#result-eyebrow");
const resultTitle = $("#result-title");
const resultDirection = $("#result-direction");
const resultDescription = $("#result-description");
const resultDetails = $(".result-details");
const resultTrend = $("#result-trend");
const resultPriceAction = $("#result-price-action");
const resultLevels = $("#result-levels");
const resultEvidence = $("#result-evidence");
const resultReasons = $("#result-reasons");
const resultRisk = $("#result-risk");
const resultContext = $("#result-context");
const feedbackPanel = $("#result-feedback");
const feedbackStatus = $("#feedback-status");
const apiStatus = $("#api-status");
const apiStatusText = $("#api-status-text");
const fullscreenToggle = $("#fullscreen-toggle");
const fullscreenStatus = $("#fullscreen-status");
const analysisProgress = $("#analysis-progress");
const navList = $(".navigation");
const historyList = document.querySelector("#history-list");
const historyEmpty = document.querySelector("#history-empty");
const historyStatus = document.querySelector("#history-status");
const historyCount = $("#history-count");
const clearHistoryButton = document.querySelector("#clear-history");
const analysisOverlay = $("#analysis-overlay");
const overlayElapsed = $("#overlay-elapsed");
let previewUrl = null;
let selectedFile = null;
let currentAnalysisId = null;
let historyDatabasePromise = null;
let historyObjectUrls = [];
let overlayStartedAt = 0;
let overlayTicker = null;
let overlayCloseTimer = null;
let levelMarksVisible = true;
let analysisDiagnostics = { preprocess: "", reread: "" };
let calibrationBuckets = [];
function openAnalysisOverlay() {
    if (overlayCloseTimer) {
        clearTimeout(overlayCloseTimer);
        overlayCloseTimer = null;
    }
    overlayStartedAt = Date.now();
    overlayElapsed.textContent = "0s";
    analysisOverlay.hidden = false;
    document.body.classList.add("overlay-active");
    requestAnimationFrame(() => analysisOverlay.classList.add("is-visible"));
    overlayTicker = window.setInterval(() => {
        const elapsed = Math.max(1, Math.round((Date.now() - overlayStartedAt) / 1000));
        overlayElapsed.textContent = `${elapsed}s`;
    }, 1000);
}
function closeAnalysisOverlay() {
    if (overlayTicker) {
        clearInterval(overlayTicker);
        overlayTicker = null;
    }
    analysisOverlay.classList.remove("is-visible");
    overlayCloseTimer = window.setTimeout(() => {
        analysisOverlay.hidden = true;
        document.body.classList.remove("overlay-active");
        overlayCloseTimer = null;
    }, 260);
}
function playResultReveal() {
    analysisResult.classList.remove("is-revealing");
    void analysisResult.offsetWidth;
    analysisResult.classList.add("is-revealing");
    resultReasons.querySelectorAll("li").forEach((item, index) => {
        item.style.setProperty("--i", String(index));
    });
}
function updateFullscreenControl() {
    const isFullscreen = document.fullscreenElement === document.documentElement;
    const label = isFullscreen ? "Sair da tela cheia" : "Entrar em tela cheia";
    fullscreenToggle.setAttribute("aria-label", label);
    fullscreenToggle.setAttribute("title", label);
    fullscreenToggle.setAttribute("aria-pressed", String(isFullscreen));
    requiredElement(fullscreenToggle, "span").textContent = isFullscreen
        ? "Sair da tela cheia"
        : "Tela cheia";
}
fullscreenToggle.addEventListener("click", async () => {
    fullscreenStatus.textContent = "";
    try {
        if (document.fullscreenElement) {
            await document.exitFullscreen();
            return;
        }
        if (!document.documentElement.requestFullscreen) {
            throw new Error("Este navegador não oferece suporte à tela cheia.");
        }
        await document.documentElement.requestFullscreen();
    }
    catch (error) {
        fullscreenStatus.textContent = `Não foi possível alternar para tela cheia: ${errorMessage(error)}`;
        console.error(fullscreenStatus.textContent, error);
    }
});
document.addEventListener("fullscreenchange", updateFullscreenControl);
updateFullscreenControl();
document.querySelectorAll(".panel").forEach((panel) => {
    panel.addEventListener("mousemove", (event) => {
        const bounds = panel.getBoundingClientRect();
        panel.style.setProperty("--mouse-x", `${event.clientX - bounds.left}px`);
        panel.style.setProperty("--mouse-y", `${event.clientY - bounds.top}px`);
    });
    panel.addEventListener("mouseleave", () => {
        panel.style.setProperty("--mouse-x", "50%");
        panel.style.setProperty("--mouse-y", "50%");
    });
});
async function readJsonResponse(response) {
    const responseText = await response.text();
    if (response.status === 405) {
        throw new Error("Este endereço está sendo atendido por outro servidor. Feche esta aba e abra exatamente http://127.0.0.1:8765/ (o endereço mostrado no PowerShell).");
    }
    if (!responseText.trim()) {
        throw new Error(`O servidor respondeu sem conteúdo (HTTP ${response.status}). Feche a janela antiga do servidor e inicie novamente com start.bat.`);
    }
    let payload;
    try {
        payload = JSON.parse(responseText);
    }
    catch {
        throw new Error(`O servidor retornou uma resposta inválida (HTTP ${response.status}). Feche a janela antiga do servidor e inicie novamente com start.bat.`);
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        throw new Error("O servidor retornou dados em um formato inesperado.");
    }
    return payload;
}
function openHistoryDatabase() {
    if (!("indexedDB" in window)) {
        return Promise.reject(new Error("Este navegador não oferece armazenamento local para o histórico."));
    }
    if (!historyDatabasePromise) {
        historyDatabasePromise = new Promise((resolve, reject) => {
            const request = indexedDB.open(HISTORY_DB_NAME, 1);
            request.addEventListener("upgradeneeded", () => {
                const database = request.result;
                if (!database.objectStoreNames.contains(HISTORY_STORE_NAME)) {
                    const store = database.createObjectStore(HISTORY_STORE_NAME, { keyPath: "id" });
                    store.createIndex("createdAt", "createdAt");
                }
            });
            request.addEventListener("success", () => {
                const database = request.result;
                database.addEventListener("versionchange", () => database.close());
                resolve(database);
            });
            request.addEventListener("error", () => {
                reject(request.error || new Error("Não foi possível abrir o histórico local."));
            });
            request.addEventListener("blocked", () => {
                reject(new Error("Feche outras abas do Chartly para atualizar o histórico."));
            });
        }).catch((error) => {
            historyDatabasePromise = null;
            throw error;
        });
    }
    return historyDatabasePromise;
}
async function getHistoryEntries() {
    const database = await openHistoryDatabase();
    return new Promise((resolve, reject) => {
        const transaction = database.transaction(HISTORY_STORE_NAME, "readonly");
        const request = transaction.objectStore(HISTORY_STORE_NAME).getAll();
        request.addEventListener("success", () => resolve(request.result));
        request.addEventListener("error", () => {
            reject(request.error || new Error("Não foi possível carregar o histórico."));
        });
    });
}
async function saveHistoryEntry(entry) {
    const database = await openHistoryDatabase();
    return new Promise((resolve, reject) => {
        const transaction = database.transaction(HISTORY_STORE_NAME, "readwrite");
        const store = transaction.objectStore(HISTORY_STORE_NAME);
        const entriesRequest = store.getAll();
        entriesRequest.addEventListener("success", () => {
            const entries = entriesRequest.result;
            entries.push(entry);
            entries.sort((first, second) => second.createdAt - first.createdAt);
            for (const expiredEntry of entries.slice(HISTORY_LIMIT)) {
                store.delete(expiredEntry.id);
            }
            store.put(entry);
        });
        entriesRequest.addEventListener("error", () => {
            transaction.abort();
            reject(entriesRequest.error || new Error("Não foi possível salvar o histórico."));
        });
        transaction.addEventListener("complete", () => resolve());
        transaction.addEventListener("abort", () => {
            reject(transaction.error || new Error("O navegador não conseguiu salvar esta imagem no histórico."));
        });
        transaction.addEventListener("error", () => {
            reject(transaction.error || new Error("O navegador não conseguiu salvar esta imagem no histórico."));
        });
    });
}
async function deleteHistoryEntry(id) {
    const database = await openHistoryDatabase();
    return new Promise((resolve, reject) => {
        const transaction = database.transaction(HISTORY_STORE_NAME, "readwrite");
        transaction.objectStore(HISTORY_STORE_NAME).delete(id);
        transaction.addEventListener("complete", () => resolve());
        transaction.addEventListener("abort", () => {
            reject(transaction.error || new Error("Não foi possível remover este item."));
        });
        transaction.addEventListener("error", () => {
            reject(transaction.error || new Error("Não foi possível remover este item."));
        });
    });
}
async function clearHistoryEntries() {
    const database = await openHistoryDatabase();
    return new Promise((resolve, reject) => {
        const transaction = database.transaction(HISTORY_STORE_NAME, "readwrite");
        transaction.objectStore(HISTORY_STORE_NAME).clear();
        transaction.addEventListener("complete", () => resolve());
        transaction.addEventListener("abort", () => {
            reject(transaction.error || new Error("Não foi possível limpar o histórico."));
        });
        transaction.addEventListener("error", () => {
            reject(transaction.error || new Error("Não foi possível limpar o histórico."));
        });
    });
}
function renderHistoryEntry(entry) {
    const directionLabels = {
        BUY: "Viés comprador",
        SELL: "Viés vendedor",
        NEUTRAL: "Sem viés claro",
    };
    const card = document.createElement("article");
    card.className = "history-card";
    const image = document.createElement("img");
    image.className = "history-image";
    image.src = URL.createObjectURL(entry.image);
    image.alt = `Print analisado: ${entry.fileName}`;
    image.loading = "lazy";
    historyObjectUrls.push(image.src);
    const body = document.createElement("div");
    body.className = "history-card-body";
    const meta = document.createElement("div");
    meta.className = "history-card-meta";
    const date = document.createElement("time");
    date.dateTime = new Date(entry.createdAt).toISOString();
    date.textContent = new Date(entry.createdAt).toLocaleString("pt-BR", {
        dateStyle: "short",
        timeStyle: "short",
    });
    const badge = document.createElement("span");
    badge.className = `direction-badge direction-${entry.result.direction.toLowerCase()}`;
    badge.textContent = directionLabels[entry.result.direction];
    meta.append(date, badge);
    const title = document.createElement("h3");
    title.textContent = entry.asset || "Ativo não informado";
    const context = document.createElement("p");
    context.className = "history-context";
    context.textContent = `${entry.market} · ${entry.timeframe}`;
    const summary = document.createElement("p");
    summary.className = "history-summary";
    summary.textContent = entry.result.summary;
    const evidence = document.createElement("details");
    evidence.className = "history-evidence";
    const evidenceLabel = document.createElement("summary");
    evidenceLabel.textContent = "Ver price action, níveis, evidências e limitações";
    const evidenceList = document.createElement("ul");
    const trend = document.createElement("p");
    trend.textContent = `Tendência: ${entry.result.trend || "não informada"}`;
    const priceAction = document.createElement("p");
    priceAction.textContent = `Price action: ${entry.result.price_action || "não informada"}`;
    const levels = document.createElement("p");
    levels.textContent = `Níveis visíveis: ${(entry.result.levels || []).join(" · ") || "não identificados"}`;
    const diagnostics = document.createElement("p");
    const diagnosticDetails = [
        Number.isInteger(entry.result.visual_quality)
            ? `Qualidade visual: ${entry.result.visual_quality}/100`
            : "",
        Number.isInteger(entry.result.analysis_coverage)
            ? `Cobertura: ${entry.result.analysis_coverage}%`
            : "",
        entry.result.last_candle_status
            ? `Última vela: ${entry.result.last_candle_status}`
            : "",
        entry.result.signal_timing_text || "",
    ].filter(Boolean);
    diagnostics.textContent = diagnosticDetails.join(" · ");
    for (const reason of entry.result.reasons || []) {
        const item = document.createElement("li");
        item.textContent = reason;
        evidenceList.append(item);
    }
    const risk = document.createElement("p");
    risk.textContent = `Risco: ${entry.result.risk}${entry.result.conflict_notes ? ` Conflito: ${entry.result.conflict_notes}` : ""}`;
    evidence.append(evidenceLabel, trend, priceAction, levels);
    if (diagnosticDetails.length > 0) {
        evidence.append(diagnostics);
    }
    evidence.append(evidenceList, risk);
    const footer = document.createElement("div");
    footer.className = "history-card-footer";
    const confidence = document.createElement("span");
    confidence.textContent = `Qualidade do cenário: ${entry.result.confidence}/100 (não é probabilidade de acerto)`;
    const removeButton = document.createElement("button");
    removeButton.className = "history-delete-button";
    removeButton.type = "button";
    removeButton.textContent = "Excluir";
    removeButton.addEventListener("click", async () => {
        removeButton.disabled = true;
        try {
            await deleteHistoryEntry(entry.id);
            await refreshHistory();
            if (historyStatus) {
                historyStatus.textContent = "Análise removida do histórico.";
            }
        }
        catch (error) {
            if (historyStatus) {
                historyStatus.textContent = errorMessage(error);
            }
            removeButton.disabled = false;
        }
    });
    footer.append(confidence, removeButton);
    body.append(meta, title, context, summary, evidence, footer);
    card.append(image, body);
    return card;
}
async function refreshHistory() {
    const entries = await getHistoryEntries();
    entries.sort((first, second) => second.createdAt - first.createdAt);
    for (const objectUrl of historyObjectUrls) {
        URL.revokeObjectURL(objectUrl);
    }
    historyObjectUrls = [];
    // index.html nao tem a grade do historico (ela vive em historico.html), mas
    // carrega o mesmo app.js. Sem estas checagens o erro parava a inicializacao
    // e o formulario de analise nunca recebia o listener de submit.
    if (historyList) {
        historyList.replaceChildren(...entries.map(renderHistoryEntry));
    }
    if (historyCount) {
        historyCount.textContent = String(entries.length);
    }
    if (historyEmpty) {
        historyEmpty.hidden = entries.length > 0;
    }
    if (clearHistoryButton) {
        clearHistoryButton.hidden = entries.length === 0;
    }
}
function createResizedImage(blob, maxDimension, quality, forceJpeg = false) {
    return createImageBitmap(blob).then((bitmap) => {
        const scale = Math.min(1, maxDimension / Math.max(bitmap.width, bitmap.height));
        if (scale === 1 && !forceJpeg) {
            bitmap.close();
            return blob;
        }
        const canvas = document.createElement("canvas");
        canvas.width = Math.max(1, Math.round(bitmap.width * scale));
        canvas.height = Math.max(1, Math.round(bitmap.height * scale));
        const context = canvas.getContext("2d");
        if (!context) {
            bitmap.close();
            throw new Error("O navegador não conseguiu preparar a imagem.");
        }
        context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
        bitmap.close();
        return new Promise((resolve, reject) => {
            canvas.toBlob((resizedBlob) => {
                if (resizedBlob) {
                    resolve(resizedBlob);
                }
                else {
                    reject(new Error("O navegador não conseguiu reduzir o tamanho da imagem."));
                }
            }, "image/jpeg", quality);
        });
    });
}
function readImageAsBase64(blob) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.addEventListener("load", () => {
            const dataUrl = reader.result;
            if (typeof dataUrl !== "string" || !dataUrl.includes(",")) {
                reject(new Error("Não foi possível ler o arquivo de imagem."));
                return;
            }
            resolve(dataUrl.slice(dataUrl.indexOf(",") + 1));
        });
        reader.addEventListener("error", () => {
            reject(new Error("Não foi possível ler o arquivo de imagem."));
        });
        reader.readAsDataURL(blob);
    });
}
async function initializeHistory() {
    try {
        await refreshHistory();
    }
    catch (error) {
        if (historyStatus) {
            historyStatus.textContent = `O histórico local não pôde ser carregado: ${errorMessage(error)}`;
        }
        if (historyEmpty) {
            historyEmpty.hidden = true;
        }
    }
}
async function updateApiStatus() {
    try {
        const response = await fetch("/api/status", { cache: "no-store" });
        if (!response.ok) {
            throw new Error("Servidor indisponível.");
        }
        const status = await readJsonResponse(response);
        const connectionState = status.running
            ? status.connectionState || (status.modelAvailable ? "connected" : "disconnected")
            : "disconnected";
        apiStatus.classList.remove("api-ready", "api-unstable", "api-missing");
        apiStatus.classList.add(connectionState === "connected"
            ? "api-ready"
            : connectionState === "unstable"
                ? "api-unstable"
                : "api-missing");
        apiStatusText.textContent = connectionState === "connected"
            ? "Conectado"
            : connectionState === "unstable"
                ? "Instável"
                : status.modelAvailable
                    ? "Desconectado"
                    : "Configure a chave";
        apiStatus.title = status.connectionMessage || "Estado da conexão com a API";
        apiStatus.setAttribute("aria-label", apiStatus.title);
    }
    catch {
        apiStatus.classList.remove("api-ready", "api-unstable");
        apiStatus.classList.add("api-missing");
        apiStatusText.textContent = "Desconectado";
        apiStatus.title = window.location.protocol === "file:"
            ? "Abra o site pelo servidor local"
            : "Servidor local desconectado";
        apiStatus.setAttribute("aria-label", apiStatus.title);
    }
    finally {
        window.setTimeout(updateApiStatus, 5000);
    }
}
updateApiStatus();
initializeHistory();
void loadCalibration();
// Calibracao real: cruza o confidence devolvido pela IA com o feedback do
// usuario e o desfecho registrado no projeto. Sem amostra, nao aparece taxa.
async function loadCalibration() {
    try {
        const response = await fetch("/api/calibration", { cache: "no-store" });
        if (!response.ok) {
            return;
        }
        const payload = await response.json();
        calibrationBuckets = Array.isArray(payload.buckets) ? payload.buckets : [];
    }
    catch {
        calibrationBuckets = [];
    }
}
function calibrationText(confidence) {
    const bucket = calibrationBuckets.find((item) => {
        const [min, max] = String(item.bucket || "")
            .split("-")
            .map((part) => Number(part));
        return (Number.isFinite(min) &&
            Number.isFinite(max) &&
            confidence >= min &&
            confidence <= max);
    });
    if (!bucket) {
        return "";
    }
    if (Number(bucket.graded) > 0 && bucket.hitRate !== null) {
        return `Calibração local: ${bucket.hitRate}% de acertos em ${bucket.graded} feedback(s) desta faixa (${bucket.bucket}).`;
    }
    if (Number(bucket.outcomeSamples) > 0 && bucket.outcomeRate !== null) {
        return `Calibração por desfecho real: ${bucket.outcomeRate}% favoráveis em ${bucket.outcomeSamples} leitura(s) desta faixa (${bucket.bucket}).`;
    }
    return `Calibração local: ainda sem amostra suficiente para a faixa ${bucket.bucket}.`;
}
function diagnosticsText() {
    const parts = [];
    parts.push(analysisDiagnostics.preprocess
        ? `imagem preparada (${analysisDiagnostics.preprocess})`
        : "imagem enviada sem ajuste");
    if (analysisDiagnostics.reread === "improved") {
        parts.push("releitura mudou a classe da imagem");
    }
    else if (analysisDiagnostics.reread === "kept") {
        parts.push("releitura confirmou a classe");
    }
    else if (analysisDiagnostics.reread === "failed") {
        parts.push("releitura não concluiu");
    }
    return `${parts.join(" · ")}.`;
}
function formatFileSize(bytes) {
    return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}
function clearPreview() {
    if (previewUrl) {
        URL.revokeObjectURL(previewUrl);
        previewUrl = null;
    }
    imageInput.value = "";
    selectedFile = null;
    imagePreview.removeAttribute("src");
    previewCard.hidden = true;
    dropZone.hidden = false;
    analyzeButton.disabled = true;
    analysisResult.hidden = true;
    uploadMessage.textContent = "";
    clearLevelOverlay();
}
function loadImage(file) {
    uploadMessage.textContent = "";
    analysisResult.hidden = true;
    if (!file) {
        return;
    }
    if (!ACCEPTED_TYPES.has(file.type)) {
        uploadMessage.textContent = "Formato não suportado. Escolha um arquivo PNG, JPG ou WEBP.";
        imageInput.value = "";
        return;
    }
    if (file.size > MAX_FILE_SIZE) {
        uploadMessage.textContent = "A imagem excede o limite de 12 MB. Escolha um arquivo menor.";
        imageInput.value = "";
        return;
    }
    if (previewUrl) {
        URL.revokeObjectURL(previewUrl);
    }
    previewUrl = URL.createObjectURL(file);
    selectedFile = file;
    imagePreview.src = previewUrl;
    fileName.textContent = file.name;
    fileSize.textContent = formatFileSize(file.size);
    dropZone.hidden = true;
    previewCard.hidden = false;
    analyzeButton.disabled = false;
    clearLevelOverlay();
}
dropZone.addEventListener("click", () => imageInput.click());
imageInput.addEventListener("change", () => loadImage(imageInput.files?.[0] ?? null));
removeImageButton.addEventListener("click", clearPreview);
for (const eventName of ["dragenter", "dragover"]) {
    dropZone.addEventListener(eventName, (event) => {
        event.preventDefault();
        dropZone.classList.add("dragging");
    });
}
for (const eventName of ["dragleave", "drop"]) {
    dropZone.addEventListener(eventName, (event) => {
        event.preventDefault();
        dropZone.classList.remove("dragging");
    });
}
dropZone.addEventListener("drop", (event) => {
    const file = event.dataTransfer?.files[0];
    if (file) {
        loadImage(file);
    }
});
navList.addEventListener("click", (event) => {
    const link = event.target.closest("a.nav-link");
    if (!link) {
        return;
    }
    navList.querySelectorAll("a.nav-link").forEach((navLink) => {
        navLink.classList.toggle("active", navLink === link);
        if (navLink === link) {
            navLink.setAttribute("aria-current", "page");
        }
        else {
            navLink.removeAttribute("aria-current");
        }
    });
});
marketType.addEventListener("change", () => {
    const isForex = marketType.value === "forex";
    const isCrypto = marketType.value === "crypto";
    const isBinary = marketType.value === "binary";
    const isCommodities = marketType.value === "commodities";
    const isStocks = marketType.value === "stocks";
    assetInput.hidden = isForex || isCrypto || isCommodities || isStocks;
    assetInput.disabled = isForex || isCrypto || isCommodities || isStocks;
    forexAssetSelect.hidden = !isForex;
    forexAssetSelect.disabled = !isForex;
    cryptoAssetSelect.hidden = !isCrypto;
    cryptoAssetSelect.disabled = !isCrypto;
    commodityAssetSelect.hidden = !isCommodities;
    commodityAssetSelect.disabled = !isCommodities;
    stockAssetSelect.hidden = !isStocks;
    stockAssetSelect.disabled = !isStocks;
    assetLabel.textContent = isCrypto
        ? "Criptomoeda"
        : isBinary
            ? "Ativo (opcional)"
            : isCommodities
                ? "Commodity"
                : isStocks
                    ? "Ação"
                    : "Par de moedas";
    assetInput.placeholder = "Ex.: EUR/USD";
    assetInput.value = isBinary ? "" : "EUR/USD";
});
function setLoading(isLoading) {
    analyzeButton.disabled = isLoading || !selectedFile;
    removeImageButton.disabled = isLoading;
    analysisForm.querySelectorAll("input, select").forEach((field) => {
        field.disabled = isLoading || Boolean(field.hidden);
    });
    requiredElement(analyzeButton, "span").textContent = isLoading
        ? "Analisando imagem..."
        : "Analisar gráfico com IA";
    analysisProgress.hidden = !isLoading;
    if (isLoading) {
        analysisProgress.textContent = "Análise em andamento; o progresso detalhado não é fornecido.";
        openAnalysisOverlay();
    }
    else {
        closeAnalysisOverlay();
        analysisProgress.textContent = "";
    }
}
function resetFeedback(analysisId) {
    // O id vem do servidor no cabecalho da resposta. Sem id nao ha o que avaliar,
    // entao o bloco de feedback fica escondido em vez de gravar um evento orfao.
    currentAnalysisId = analysisId;
    feedbackPanel.hidden = analysisId === null;
    feedbackStatus.textContent = "";
    feedbackPanel.querySelectorAll("button[data-feedback]").forEach((button) => {
        button.disabled = false;
        button.classList.remove("is-selected");
    });
}
function showError(message) {
    resetFeedback(null);
    analysisResult.classList.remove("result-buy", "result-sell", "result-neutral");
    analysisResult.classList.add("result-error");
    resultEyebrow.textContent = "NÃO FOI POSSÍVEL ANALISAR";
    resultTitle.textContent = "A análise não foi concluída";
    resultDirection.hidden = true;
    resultDescription.textContent = message;
    resultDetails.hidden = true;
    resultTrend.textContent = "";
    resultPriceAction.textContent = "";
    resultLevels.textContent = "";
    resultEvidence.hidden = true;
    resultRisk.textContent = "";
    analysisResult.hidden = false;
    clearLevelOverlay();
    playResultReveal();
}
function setTextWithUncertainty(target, text) {
    const marker = "possível:";
    const parts = [];
    let rest = text;
    let index = rest.indexOf(marker);
    while (index !== -1) {
        if (index > 0) {
            parts.push(rest.slice(0, index));
        }
        const flag = document.createElement("em");
        flag.className = "uncertainty-flag";
        flag.textContent = marker;
        parts.push(flag);
        rest = rest.slice(index + marker.length);
        index = rest.indexOf(marker);
    }
    if (rest) {
        parts.push(rest);
    }
    target.replaceChildren(...parts);
}
function formatLevelValue(value) {
    // 5 casas nos precos pequenos: 1.30995 e 1.311 nao podem virar o mesmo texto.
    const digits = Math.abs(value) >= 1000 ? 2 : Math.abs(value) >= 10 ? 3 : 5;
    return new Intl.NumberFormat("pt-BR", { maximumFractionDigits: digits }).format(value);
}
function clearLevelOverlay() {
    levelMarksVisible = true;
    if (levelOverlay) {
        levelOverlay.replaceChildren();
        levelOverlay.hidden = true;
    }
    if (levelToggle) {
        levelToggle.hidden = true;
        levelToggle.setAttribute("aria-pressed", "true");
        levelToggle.classList.remove("is-active");
    }
    if (levelOverlayNote) {
        levelOverlayNote.hidden = true;
        levelOverlayNote.textContent = "";
        levelOverlayNote.dataset.mode = "";
    }
}
function setLevelOverlayVisibility(visible) {
    levelMarksVisible = visible;
    if (levelToggle) {
        levelToggle.setAttribute("aria-pressed", String(visible));
        levelToggle.classList.toggle("is-active", visible);
    }
    if (!levelOverlay) {
        return;
    }
    const hasLines = levelOverlay.childElementCount > 0;
    levelOverlay.hidden = !visible || !hasLines;
    if (levelOverlayNote) {
        if (levelOverlayNote.dataset.mode === "hint") {
            levelOverlayNote.hidden = false;
        }
        else {
            levelOverlayNote.hidden = !visible || !hasLines;
        }
    }
}
// Desenha os niveis lidos pela IA sobre o print usando a escala de preco que a
// propria leitura informou. Se o eixo nao foi legivel, o overlay fica desligado
// em vez de chutar uma posicao.
function renderLevelOverlay(result) {
    clearLevelOverlay();
    if (!levelOverlay) {
        return;
    }
    const axisMin = result.price_axis_min;
    const axisMax = result.price_axis_max;
    const readable = result.price_axis_readable &&
        typeof axisMin === "number" &&
        typeof axisMax === "number" &&
        axisMax > axisMin;
    const marks = (Array.isArray(result.level_marks) ? result.level_marks : []).filter((mark) => typeof mark.value === "number" && Number.isFinite(mark.value));
    if (!readable) {
        if (levelOverlayNote) {
            levelOverlayNote.dataset.mode = "hint";
            levelOverlayNote.textContent =
                "Overlay de níveis desativado: a IA não conseguiu ler a escala de preço deste print. Os níveis continuam descritos no resultado abaixo.";
            levelOverlayNote.hidden = false;
        }
        return;
    }
    const inRange = marks
        .filter((mark) => {
        const value = mark.value;
        return value >= axisMin && value <= axisMax;
    })
        .sort((first, second) => second.value - first.value)
        .slice(0, 6);
    if (inRange.length === 0) {
        if (levelOverlayNote) {
            levelOverlayNote.dataset.mode = "hint";
            levelOverlayNote.textContent =
                "Nenhum nível com preço numérico dentro da escala lida. O overlay não desenha posição aproximada sem um valor real.";
            levelOverlayNote.hidden = false;
        }
        return;
    }
    const span = axisMax - axisMin;
    for (const mark of inRange) {
        const value = mark.value;
        const percent = (axisMax - value) / span * 100;
        const line = document.createElement("div");
        line.className = `level-line level-line--${mark.type}`;
        line.style.top = `${percent}%`;
        const label = document.createElement("span");
        label.className = "level-line-label";
        label.textContent = `${mark.typeLabel} ${formatLevelValue(value)}`;
        line.append(label);
        levelOverlay.append(line);
    }
    levelOverlay.hidden = !levelMarksVisible;
    if (levelToggle) {
        levelToggle.hidden = false;
        levelToggle.setAttribute("aria-pressed", String(levelMarksVisible));
        levelToggle.classList.toggle("is-active", levelMarksVisible);
    }
    if (levelOverlayNote) {
        levelOverlayNote.dataset.mode = "lines";
        levelOverlayNote.textContent =
            "Posição aproximada: as linhas usam a escala de preço lida pela IA no print, não o pixel exato da sua plataforma.";
        levelOverlayNote.hidden = !levelMarksVisible;
    }
}
levelToggle?.addEventListener("click", () => {
    setLevelOverlayVisibility(!levelMarksVisible);
});
function showAnalysis(result, context) {
    analysisResult.classList.remove("result-error", "result-buy", "result-sell", "result-neutral");
    analysisResult.classList.add(`result-${result.direction.toLowerCase()}`);
    resultEyebrow.textContent = "ANÁLISE VISUAL · OPENAI";
    const { title, badge } = getAnalysisPresentation(result);
    resultTitle.textContent = title;
    resultDirection.textContent = badge;
    resultDirection.className = `direction-badge direction-${result.direction.toLowerCase()}`;
    resultDirection.hidden = false;
    setTextWithUncertainty(resultDescription, result.summary);
    resultDetails.hidden = false;
    setTextWithUncertainty(resultTrend, result.trend);
    setTextWithUncertainty(resultPriceAction, result.price_action);
    setTextWithUncertainty(resultLevels, result.levels.length > 0 ? result.levels.join(" · ") : "Nenhuma região registrada na leitura.");
    resultReasons.replaceChildren();
    for (const reason of result.reasons) {
        const item = document.createElement("li");
        setTextWithUncertainty(item, reason);
        resultReasons.append(item);
    }
    resultEvidence.hidden = result.reasons.length === 0;
    setTextWithUncertainty(resultRisk, `Risco e limitações: ${result.risk}${result.conflict_notes ? ` Conflito: ${result.conflict_notes}` : ""}`);
    const assumedContext = [
        result.asset_assumed ? `Ativo identificado: ${result.asset_assumed}` : "",
        result.timeframe_assumed ? `Timeframe identificado: ${result.timeframe_assumed}` : "",
    ].filter(Boolean);
    const visualDetails = [
        result.chart_type ? `Gráfico: ${result.chart_type}` : "",
        `Última vela: ${{
            closed: "fechada visualmente",
            possibly_open: "possivelmente em formação",
            unknown: "não foi possível determinar",
        }[result.last_candle_status]}`,
        result.price_axis_readable && result.price_axis_min !== null && result.price_axis_max !== null
            ? `Escala lida: ${result.price_axis_min} a ${result.price_axis_max}`
            : "Escala de preços não legível",
        `Qualidade visual: ${result.visual_quality ?? "—"}/100`,
        `Cobertura: ${result.analysis_coverage ?? "—"}%`,
        result.signal_timing_text,
    ].filter(Boolean);
    const calibration = calibrationText(result.confidence);
    resultContext.textContent = `Contexto informado: ${context.market} · ${context.asset || "não informado"} · ${context.timeframe || "não informado"}. Classe da imagem: ${result.image_class}.${assumedContext.length ? ` ${assumedContext.join(" · ")}.` : ""} Qualidade do cenário: ${result.confidence}/100 (não é probabilidade de acerto). ${visualDetails.join(" · ")}. ${diagnosticsText()}${calibration ? ` ${calibration}` : ""}`;
    renderLevelOverlay(result);
    analysisResult.hidden = false;
    playResultReveal();
}
feedbackPanel.addEventListener("click", async (event) => {
    const target = event.target;
    const button = target.closest("button[data-feedback]");
    if (!button || !currentAnalysisId) {
        return;
    }
    const verdict = button.dataset.feedback;
    if (!verdict) {
        return;
    }
    // Reanima o botao a cada clique mesmo que ele ja tenha sido usado antes.
    button.classList.remove("is-pressed");
    void button.offsetWidth;
    button.classList.add("is-pressed");
    const buttons = feedbackPanel.querySelectorAll("button[data-feedback]");
    buttons.forEach((item) => {
        item.disabled = true;
    });
    try {
        const response = await fetch("/api/feedback", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ analysisId: currentAnalysisId, verdict }),
        });
        const payload = await readJsonResponse(response);
        if (!response.ok) {
            throw new Error(payload.error || "O feedback não pôde ser registrado.");
        }
        buttons.forEach((item) => {
            item.classList.toggle("is-selected", item === button);
        });
        feedbackStatus.textContent = "Feedback registrado. Ele entra nas métricas de calibração do projeto.";
        void loadCalibration();
    }
    catch (error) {
        buttons.forEach((item) => {
            item.disabled = false;
        });
        feedbackStatus.textContent = errorMessage(error);
    }
});
// O botao so existe em historico.html; o app.js roda em index.html tambem.
clearHistoryButton?.addEventListener("click", async () => {
    if (!window.confirm("Excluir todas as imagens e análises salvas neste navegador?")) {
        return;
    }
    clearHistoryButton.disabled = true;
    try {
        await clearHistoryEntries();
        await refreshHistory();
        if (historyStatus) {
            historyStatus.textContent = "Histórico apagado.";
        }
    }
    catch (error) {
        if (historyStatus) {
            historyStatus.textContent = errorMessage(error);
        }
    }
    finally {
        clearHistoryButton.disabled = false;
    }
});
analysisForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!selectedFile) {
        return;
    }
    const file = selectedFile;
    const marketValue = marketType.value;
    const assetSelector = marketValue === "crypto"
        ? cryptoAssetSelect
        : marketValue === "forex"
            ? forexAssetSelect
            : marketValue === "commodities"
                ? commodityAssetSelect
                : marketValue === "stocks"
                    ? stockAssetSelect
                    : assetInput;
    const assetValue = assetSelector.value.trim();
    const timeframeValue = timeframe.value;
    const analysisContext = {
        market: marketType.options[marketType.selectedIndex].text,
        asset: assetValue,
        timeframe: timeframeValue
            ? timeframe.options[timeframe.selectedIndex].text
            : "",
    };
    analysisResult.hidden = true;
    uploadMessage.textContent = "";
    if (historyStatus) {
        historyStatus.textContent = "";
    }
    resetFeedback(null);
    setLoading(true);
    try {
        const analysisImage = await createResizedImage(file, 1600, 0.88);
        const imageBase64 = await readImageAsBase64(analysisImage);
        const response = await fetch("/api/analyze", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                image: imageBase64,
                mimeType: analysisImage.type,
                market: marketValue,
                asset: assetValue,
                timeframe: timeframeValue,
            }),
        });
        if (response.status === 405) {
            throw new Error("Este endereço está sendo atendido por outro servidor. Feche esta aba e abra exatamente http://127.0.0.1:8765/ (o endereço mostrado no PowerShell).");
        }
        const payload = await readJsonResponse(response);
        if (!response.ok) {
            throw new Error(payload.error || "O servidor não conseguiu analisar a imagem.");
        }
        const analysis = normalizeAnalysisPayload(payload);
        analysisDiagnostics = {
            preprocess: response.headers.get("X-ZNX-Preprocess") || "",
            reread: response.headers.get("X-ZNX-Reread") || "",
        };
        setLoading(false);
        showAnalysis(analysis, analysisContext);
        resetFeedback(response.headers.get("X-ZNX-Analysis-Id"));
        try {
            const thumbnail = await createResizedImage(file, 560, 0.76);
            await saveHistoryEntry({
                id: `${Date.now()}-${crypto.randomUUID()}`,
                createdAt: Date.now(),
                fileName: file.name,
                image: thumbnail,
                market: analysisContext.market,
                asset: analysisContext.asset,
                timeframe: analysisContext.timeframe,
                result: {
                    direction: analysis.direction,
                    trend: analysis.trend,
                    price_action: analysis.price_action,
                    levels: analysis.levels,
                    confidence: analysis.confidence,
                    summary: analysis.summary,
                    reasons: analysis.reasons,
                    asset_assumed: analysis.asset_assumed,
                    timeframe_assumed: analysis.timeframe_assumed,
                    conflict_notes: analysis.conflict_notes,
                    image_class: analysis.image_class,
                    risk: analysis.risk,
                    visual_quality: analysis.visual_quality,
                    analysis_coverage: analysis.analysis_coverage,
                    last_candle_status: analysis.last_candle_status,
                    signal_timing_text: analysis.signal_timing_text,
                },
            });
            await refreshHistory();
            if (historyStatus) {
                historyStatus.textContent = "Análise e imagem salvas no histórico deste navegador.";
            }
        }
        catch (error) {
            if (historyStatus) {
                historyStatus.textContent = `A análise foi concluída, mas não foi possível salvar no histórico: ${errorMessage(error)}`;
            }
        }
    }
    catch (error) {
        setLoading(false);
        showError(error instanceof TypeError
            ? `Não foi possível conectar ao servidor local. O endereço desta página é ${window.location.origin}. Abra http://127.0.0.1:8765/ pelo servidor iniciado no PowerShell e mantenha essa janela aberta.`
            : errorMessage(error));
    }
    finally {
        setLoading(false);
        analysisResult.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
});

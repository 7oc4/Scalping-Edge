// Pagina de historico: le o mesmo IndexedDB (chartly-local-history) que a
// pagina de analise grava, e mostra os prints com o resultado de cada leitura.
(() => {
  "use strict";

  const HISTORY_DB_NAME = "chartly-local-history";
  const HISTORY_STORE_NAME = "analyses";

  const historyList = document.getElementById("history-list");
  if (!historyList) {
    return;
  }

  const historyEmpty = document.getElementById("history-empty");
  const historyStatus = document.getElementById("history-status");
  const clearHistoryButton = document.getElementById("clear-history");
  const historyCount = document.getElementById("history-count");

  let databasePromise = null;
  const objectUrls = [];

  function setStatus(message) {
    if (historyStatus) {
      historyStatus.textContent = message;
    }
  }

  function rawOpen() {
    return new Promise((resolve, reject) => {
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
        reject(new Error("Feche outras abas do painel para atualizar o histórico."));
      });
    });
  }

  function deleteDatabase() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.deleteDatabase(HISTORY_DB_NAME);
      request.addEventListener("success", () => resolve());
      request.addEventListener("error", () => reject(request.error || new Error("Não foi possível preparar o histórico.")));
      request.addEventListener("blocked", () => resolve());
    });
  }

  function openDatabase() {
    if (!("indexedDB" in window)) {
      return Promise.reject(new Error("Este navegador não oferece armazenamento local para o histórico."));
    }
    if (!databasePromise) {
      databasePromise = (async () => {
        let database = await rawOpen();
        if (!database.objectStoreNames.contains(HISTORY_STORE_NAME)) {
          // Banco vazio criado por uma versao anterior do menu: recria com o store.
          database.close();
          await deleteDatabase();
          database = await rawOpen();
        }
        return database;
      })().catch((error) => {
        databasePromise = null;
        throw error;
      });
    }
    return databasePromise;
  }

  async function getEntries() {
    const database = await openDatabase();
    return new Promise((resolve, reject) => {
      const transaction = database.transaction(HISTORY_STORE_NAME, "readonly");
      const request = transaction.objectStore(HISTORY_STORE_NAME).getAll();
      request.addEventListener("success", () => resolve(request.result));
      request.addEventListener("error", () => {
        reject(request.error || new Error("Não foi possível carregar o histórico."));
      });
    });
  }

  async function deleteEntry(id) {
    const database = await openDatabase();
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

  async function clearEntries() {
    const database = await openDatabase();
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

  function renderEntry(entry) {
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
    objectUrls.push(image.src);

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
      Number.isInteger(entry.result.visual_quality) ? `Qualidade visual: ${entry.result.visual_quality}/100` : "",
      Number.isInteger(entry.result.analysis_coverage) ? `Cobertura: ${entry.result.analysis_coverage}%` : "",
      entry.result.last_candle_status ? `Última vela: ${entry.result.last_candle_status}` : "",
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
        await deleteEntry(entry.id);
        await refresh();
        setStatus("Análise removida do histórico.");
      } catch (error) {
        setStatus(error.message);
        removeButton.disabled = false;
      }
    });
    footer.append(confidence, removeButton);

    body.append(meta, title, context, summary, evidence, footer);
    card.append(image, body);
    return card;
  }

  async function refresh() {
    const entries = await getEntries();
    entries.sort((first, second) => second.createdAt - first.createdAt);
    for (const url of objectUrls) {
      URL.revokeObjectURL(url);
    }
    objectUrls.length = 0;
    historyList.replaceChildren(...entries.map(renderEntry));
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

  if (clearHistoryButton) {
    clearHistoryButton.addEventListener("click", async () => {
      if (!window.confirm("Excluir todas as imagens e análises salvas neste navegador?")) {
        return;
      }
      clearHistoryButton.disabled = true;
      try {
        await clearEntries();
        await refresh();
        setStatus("Histórico apagado.");
      } catch (error) {
        setStatus(error.message);
      } finally {
        clearHistoryButton.disabled = false;
      }
    });
  }

  refresh().catch((error) => {
    setStatus(`O histórico local não pôde ser carregado: ${error.message}`);
    if (historyEmpty) {
      historyEmpty.hidden = true;
    }
  });
})();

// Utilidades compartilhadas pelas paginas Radar, Noticias e Historico:
// esconde o loader, mantem o estado da API, a tela cheia e o contador do menu.
(() => {
  "use strict";

  const loader = document.getElementById("startup-loader");
  if (loader) {
    window.setTimeout(() => {
      loader.hidden = true;
    }, 500);
  }

  const apiStatus = document.getElementById("api-status");
  const apiStatusText = document.getElementById("api-status-text");
  const fullscreenToggle = document.getElementById("fullscreen-toggle");
  const fullscreenStatus = document.getElementById("fullscreen-status");
  const historyCount = document.getElementById("history-count");

  async function updateApiStatus() {
    if (!apiStatus) {
      return;
    }
    try {
      const response = await fetch("/api/status", { cache: "no-store" });
      if (!response.ok) {
        throw new Error("Servidor indisponível.");
      }
      const status = await response.json();
      const connectionState = status.running
        ? status.connectionState || (status.modelAvailable ? "connected" : "disconnected")
        : "disconnected";
      apiStatus.classList.remove("api-ready", "api-unstable", "api-missing");
      apiStatus.classList.add(
        connectionState === "connected"
          ? "api-ready"
          : connectionState === "unstable"
            ? "api-unstable"
            : "api-missing",
      );
      apiStatusText.textContent =
        connectionState === "connected"
          ? "Conectado"
          : connectionState === "unstable"
            ? "Instável"
            : status.modelAvailable
              ? "Desconectado"
              : "Configure a chave";
      apiStatus.title = status.connectionMessage || "Estado da conexão com a API";
      apiStatus.setAttribute("aria-label", apiStatus.title);
    } catch {
      apiStatus.classList.remove("api-ready", "api-unstable");
      apiStatus.classList.add("api-missing");
      apiStatusText.textContent = "Desconectado";
      apiStatus.title = "Servidor local desconectado";
      apiStatus.setAttribute("aria-label", apiStatus.title);
    } finally {
      window.setTimeout(updateApiStatus, 10000);
    }
  }

  function updateFullscreenControl() {
    if (!fullscreenToggle) {
      return;
    }
    const isFullscreen = document.fullscreenElement === document.documentElement;
    const label = isFullscreen ? "Sair da tela cheia" : "Entrar em tela cheia";
    fullscreenToggle.setAttribute("aria-label", label);
    fullscreenToggle.setAttribute("title", label);
    fullscreenToggle.setAttribute("aria-pressed", String(isFullscreen));
    const text = fullscreenToggle.querySelector("span");
    if (text) {
      text.textContent = isFullscreen ? "Sair da tela cheia" : "Tela cheia";
    }
  }

  if (fullscreenToggle) {
    fullscreenToggle.addEventListener("click", async () => {
      if (fullscreenStatus) {
        fullscreenStatus.textContent = "";
      }
      try {
        if (document.fullscreenElement) {
          await document.exitFullscreen();
          return;
        }
        await document.documentElement.requestFullscreen();
      } catch (error) {
        if (fullscreenStatus) {
          fullscreenStatus.textContent = `Não foi possível alternar para tela cheia: ${error.message}`;
        }
      }
    });
    document.addEventListener("fullscreenchange", updateFullscreenControl);
    updateFullscreenControl();
  }

  // Contador do menu: nunca cria o banco, so le se ele ja existir (quem cria
  // e a pagina de analise, com o object store "analyses").
  function updateHistoryCount() {
    if (!historyCount || !("indexedDB" in window) || typeof indexedDB.databases !== "function") {
      return;
    }
    indexedDB.databases()
      .then((databases) => {
        if (!databases.some((database) => database.name === "chartly-local-history")) {
          return;
        }
        const request = indexedDB.open("chartly-local-history");
        request.addEventListener("error", () => {});
        request.addEventListener("success", () => {
          const database = request.result;
          if (!database.objectStoreNames.contains("analyses")) {
            database.close();
            return;
          }
          const transaction = database.transaction("analyses", "readonly");
          const countRequest = transaction.objectStore("analyses").count();
          countRequest.addEventListener("success", () => {
            historyCount.textContent = String(countRequest.result);
          });
          transaction.addEventListener("complete", () => database.close());
        });
      })
      .catch(() => {});
  }

  updateApiStatus();
  updateHistoryCount();
})();

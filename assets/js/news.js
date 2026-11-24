// Pagina de noticias: busca o feed agregado do servidor (/api/news),
// filtra por tema, pesquisa por texto e verifica o feed a cada 1 minuto.
// O servidor tem cache curto: quando nao ha manchete nova, a pagina mantem a
// ultima leitura real com o horario dela — nunca inventa atualizacao.
(() => {
  "use strict";

  const PAGE_SIZE = 40;
  const REFRESH_MS = 60 * 1000;
  const MAX_ITEMS = 900;

  const list = document.getElementById("news-list");
  if (!list) {
    return;
  }

  const statusNode = document.getElementById("news-status");
  const statsNode = document.getElementById("news-stats");
  const filtersNode = document.getElementById("news-filters");
  const searchNode = document.getElementById("news-search");
  const moreButton = document.getElementById("news-more");
  const emptyNode = document.getElementById("news-empty");
  const footNode = document.getElementById("news-foot");
  const refreshButton = document.getElementById("news-refresh");

  let items = [];
  let activeTag = "Todas";
  let query = "";
  let visible = PAGE_SIZE;
  let loading = false;
  let updatedAt = null;
  let nextRefreshAt = 0;
  let sources = [];
  let total = 0;
  let nextUpdateNode = null;

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) {
      node.className = className;
    }
    if (text !== undefined && text !== null) {
      node.textContent = String(text);
    }
    return node;
  }

  function setStatus(message, kind) {
    if (!statusNode) {
      return;
    }
    statusNode.textContent = message || "";
    statusNode.classList.toggle("is-error", kind === "error");
    statusNode.classList.toggle("is-ok", kind === "ok");
  }

  function formatTime(value) {
    if (!value) {
      return "";
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return "";
    }
    return new Intl.DateTimeFormat("pt-BR", {
      day: "2-digit",
      month: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    }).format(date);
  }

  function formatClock(value) {
    if (!value) {
      return "";
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return "";
    }
    return new Intl.DateTimeFormat("pt-BR", {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }).format(date);
  }

  function formatRelative(value) {
    if (!value) {
      return "";
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return "";
    }
    const minutes = Math.round((Date.now() - date.getTime()) / 60000);
    if (minutes < 1) {
      return "agora";
    }
    if (minutes < 60) {
      return `há ${minutes} min`;
    }
    const hours = Math.round(minutes / 60);
    if (hours < 24) {
      return `há ${hours} h`;
    }
    const days = Math.round(hours / 24);
    if (days < 30) {
      return `há ${days} d`;
    }
    return "";
  }

  function matches(item) {
    if (activeTag !== "Todas" && !(item.tags || []).includes(activeTag)) {
      return false;
    }
    if (!query) {
      return true;
    }
    const haystack = `${item.title || ""} ${item.source || ""} ${(item.tags || []).join(" ")}`.toLowerCase();
    return haystack.includes(query);
  }

  function filteredItems() {
    return items.filter(matches);
  }

  function renderFilters() {
    if (!filtersNode) {
      return;
    }
    const counts = new Map();
    for (const item of items) {
      for (const tag of item.tags || []) {
        counts.set(tag, (counts.get(tag) || 0) + 1);
      }
    }
    const ordered = Array.from(counts.entries())
      .sort((first, second) => second[1] - first[1])
      .slice(0, 8);

    filtersNode.replaceChildren();
    const makeChip = (label, count) => {
      const chip = el("button", "news-chip", `${label} · ${count}`);
      chip.type = "button";
      chip.dataset.tag = label;
      chip.setAttribute("aria-pressed", String(activeTag === label));
      chip.classList.toggle("is-active", activeTag === label);
      chip.addEventListener("click", () => {
        activeTag = label;
        visible = PAGE_SIZE;
        renderFilters();
        renderList();
      });
      return chip;
    };

    filtersNode.append(makeChip("Todas", items.length));
    for (const [tag, count] of ordered) {
      filtersNode.append(makeChip(tag, count));
    }
  }

  function renderStats() {
    if (!statsNode) {
      return;
    }
    statsNode.replaceChildren();
    const add = (label, value) => {
      const stat = el("div", "news-stat");
      stat.append(el("strong", null, value), el("span", null, label));
      statsNode.append(stat);
    };
    add("manchetes no feed", String(total || items.length));
    add("veículos", String(sources.length));
    add("última atualização", formatClock(updatedAt) || "—");

    const next = el("div", "news-stat");
    nextUpdateNode = el("strong", null, "—");
    next.append(nextUpdateNode, el("span", null, "próxima verificação"));
    statsNode.append(next);
  }

  function renderCountdown() {
    if (!nextUpdateNode) {
      return;
    }
    if (!nextRefreshAt) {
      nextUpdateNode.textContent = "—";
      return;
    }
    const seconds = Math.max(0, Math.round((nextRefreshAt - Date.now()) / 1000));
    if (seconds === 0) {
      nextUpdateNode.textContent = "agora";
      return;
    }
    nextUpdateNode.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
  }

  function renderList() {
    const filtered = filteredItems();
    const slice = filtered.slice(0, visible);

    list.replaceChildren();
    for (const [index, item] of slice.entries()) {
      const li = el("li", "news-item");
      li.style.setProperty("--i", String(index % 12));

      const head = el("div", "news-head");
      const title = el("a", "news-title", item.titlePt || item.title || "Notícia sem título");
      title.href = item.link || "#";
      title.target = "_blank";
      title.rel = "noopener noreferrer";
      head.append(title);
      li.append(head);

      const meta = el("div", "news-meta");
      for (const tag of item.tags || []) {
        meta.append(el("span", "news-tag", tag));
      }
      const when = formatRelative(item.publishedAt) || formatTime(item.publishedAt);
      if (when) {
        meta.append(el("span", "news-time", when));
      }
      meta.append(el("span", "news-source", item.source || "Notícias"));
      li.append(meta);
      list.append(li);
    }

    if (emptyNode) {
      emptyNode.hidden = filtered.length > 0;
    }
    if (moreButton) {
      moreButton.hidden = filtered.length <= visible;
      moreButton.textContent = `Carregar mais manchetes (${Math.max(0, filtered.length - visible)})`;
    }

    renderFoot();
  }

  // Rodape sempre recalculado a partir do filtro atual (antes ficava preso
  // ao texto do primeiro carregamento).
  function renderFoot() {
    if (!footNode) {
      return;
    }
    const filtered = filteredItems();
    const shown = Math.min(visible, filtered.length);
    const base = filtered.length
      ? `Mostrando ${shown} de ${filtered.length} manchetes filtradas · ${items.length} no feed.`
      : "";
    let suffix = "";
    if (nextRefreshAt) {
      const seconds = Math.max(0, Math.round((nextRefreshAt - Date.now()) / 1000));
      suffix = `Próxima atualização automática em ${Math.floor(seconds / 60)}:${String(
        seconds % 60,
      ).padStart(2, "0")}.`;
    }
    footNode.textContent = [base, suffix].filter(Boolean).join(" ");
  }

  async function loadNews(force) {
    if (loading) {
      return;
    }
    loading = true;
    if (refreshButton) {
      refreshButton.disabled = true;
    }
    setStatus(force ? "Buscando manchetes novas…" : "Carregando manchetes…");

    try {
      const response = await fetch(`/api/news?limit=${MAX_ITEMS}`, {
        headers: { Accept: "application/json" },
        cache: "no-store",
      });
      const text = await response.text();
      let payload;
      try {
        payload = text ? JSON.parse(text) : null;
      } catch {
        throw new Error(`O servidor respondeu algo inesperado (HTTP ${response.status}).`);
      }
      if (!response.ok) {
        throw new Error((payload && payload.error) || `Falha na requisição (HTTP ${response.status}).`);
      }

      items = Array.isArray(payload.items) ? payload.items : [];
      total = Number(payload.total) || items.length;
      sources = Array.isArray(payload.sources) ? payload.sources : [];
      updatedAt = payload.at || null;
      nextRefreshAt = Date.now() + REFRESH_MS;

      renderFilters();
      renderStats();
      renderList();

      const failed = Number(payload.failedFeeds) || 0;
      setStatus(
        `${items.length} manchetes carregadas${failed ? ` · ${failed} feed(s) fora do ar agora` : ""}.`,
        "ok",
      );
    } catch (error) {
      // A lista anterior continua na tela com o horario dela: nao existe
      // manchete nova nem "atualizada agora" quando a fonte falha.
      const stale = updatedAt ? ` Última leitura real: ${formatClock(updatedAt)}.` : "";
      setStatus(`${error.message}${stale}`, "error");
    } finally {
      loading = false;
      if (refreshButton) {
        refreshButton.disabled = false;
      }
      renderFoot();
    }
  }

  if (searchNode) {
    let debounce = null;
    searchNode.addEventListener("input", () => {
      window.clearTimeout(debounce);
      debounce = window.setTimeout(() => {
        query = searchNode.value.trim().toLowerCase();
        visible = PAGE_SIZE;
        renderList();
      }, 160);
    });
  }

  if (moreButton) {
    moreButton.addEventListener("click", () => {
      visible += PAGE_SIZE;
      renderList();
    });
  }

  if (refreshButton) {
    refreshButton.addEventListener("click", () => loadNews(true));
  }

  window.setInterval(() => loadNews(true), REFRESH_MS);
  window.setInterval(() => {
    renderCountdown();
    renderFoot();
  }, 1000);

  loadNews(false);
})();

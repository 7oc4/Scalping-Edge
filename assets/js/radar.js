// Radar de mercado: cotacoes, noticias, varredor, maquina do tempo,
// entrada/saida e calculo de risco. Toda a matematica pesada roda no
// servidor local (market.psm1); aqui so renderizamos o JSON.
(() => {
  "use strict";

  // So ativos com feed em tempo real na fonte publica (Binance + FX).
  // Indices, acoes e commodities ficam de fora porque vem com 10/15 min de
  // atraso no TradingView sem login, e o projeto nao aceita dado atrasado.
  const SYMBOLS = [
    { symbol: "BTC-USD", label: "Bitcoin" },
    { symbol: "ETH-USD", label: "Ethereum" },
    { symbol: "SOL-USD", label: "Solana" },
    { symbol: "XRP-USD", label: "XRP" },
    { symbol: "DOGE-USD", label: "Dogecoin" },
    { symbol: "EURUSD=X", label: "EUR/USD" },
    { symbol: "GBPUSD=X", label: "GBP/USD" },
    { symbol: "USDJPY=X", label: "USD/JPY" },
  ];

  const GROUP_META = {
    forex: { label: "Moedas", tone: "amber" },
    crypto: { label: "Cripto", tone: "violet" },
  };

  const section = document.getElementById("radar");
  if (!section) {
    return;
  }

  const marketGroups = document.getElementById("market-groups");
  const radarStatus = document.getElementById("radar-status");
  const refreshButton = document.getElementById("radar-refresh");
  const tapeTrack = document.getElementById("live-tape-track");
  const radarLive = document.getElementById("radar-live");
  const radarLiveLabel = document.getElementById("radar-live-label");
  const radarLiveMeta = document.getElementById("radar-live-meta");
  const scannerLive = document.getElementById("scanner-live");
  const scannerLiveLabel = document.getElementById("scanner-live-label");
  const scannerLiveMeta = document.getElementById("scanner-live-meta");
  const backtestTimeline = document.getElementById("backtest-timeline");
  const backtestPhase = document.getElementById("backtest-phase");
  const backtestElapsed = document.getElementById("backtest-elapsed");
  const backtestCounter = document.getElementById("backtest-counter");
  const backtestCounterLabel = document.getElementById("backtest-counter-label");
  const backtestTrades = document.getElementById("backtest-trades");
  const backtestPhaseTag = document.getElementById("backtest-phase-tag");
  const backtestProgress = document.getElementById("backtest-progress");
  const backtestProgressFill = document.getElementById("backtest-progress-fill");
  const tabs = Array.from(section.querySelectorAll("[data-radar-tab]"));
  const panels = Array.from(section.querySelectorAll("[data-radar-panel]"));

  const scannerRun = document.getElementById("scanner-run");
  const scannerStatus = document.getElementById("scanner-status");
  const scannerList = document.getElementById("scanner-list");

  const backtestSymbol = document.getElementById("backtest-symbol");
  const backtestRun = document.getElementById("backtest-run");
  const backtestStatus = document.getElementById("backtest-status");
  const backtestResult = document.getElementById("backtest-result");

  const planSymbol = document.getElementById("plan-symbol");
  const planRun = document.getElementById("plan-run");
  const planStatus = document.getElementById("plan-status");
  const planResult = document.getElementById("plan-result");

  const riskForm = document.getElementById("risk-form");
  const riskStatus = document.getElementById("risk-status");
  const riskResult = document.getElementById("risk-result");

  let marketLoaded = false;
  let marketLoading = false;
  let marketRefreshQueued = false;
  let scannerLoading = false;
  let backtestLoading = false;
  let planLoading = false;
  let marketNodeMap = new Map();
  let marketSignature = "";
  let marketTapeSignature = "";
  let marketLiveCount = 0;
  let marketFailures = 0;
  let marketReceivedAt = 0;
  let marketPollTimer = null;
  let backtestToken = 0;
  let backtestLastProgress = null;

  // Estado visual da varredura: so gira enquanto existe requisicao real
  // em andamento. Terminada a busca, fica "live" (tempo real) ou "error".
  // A classe e o data-state contam a mesma verdade: o CSS anima o estado,
  // nunca um trabalho que nao existe.
  function setLiveState(root, labelNode, metaNode, state, label, meta) {
    if (!root) {
      return;
    }
    root.dataset.state = state;
    for (const name of ["idle", "scanning", "refreshing", "live", "ok", "error"]) {
      root.classList.toggle(`is-${name}`, state === name);
    }
    if (labelNode && label !== undefined) {
      labelNode.textContent = label;
    }
    if (metaNode && meta !== undefined) {
      metaNode.textContent = meta;
    }
  }

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

  function setStatus(node, message, kind) {
    if (!node) {
      return;
    }
    node.textContent = message || "";
    node.classList.toggle("is-error", kind === "error");
    node.classList.toggle("is-ok", kind === "ok");
  }

  function formatPrice(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) {
      return "—";
    }
    let digits = 5;
    if (Math.abs(number) >= 1000) {
      digits = 2;
    } else if (Math.abs(number) >= 100) {
      digits = 2;
    } else if (Math.abs(number) >= 10) {
      digits = 3;
    } else if (Math.abs(number) >= 1) {
      digits = 4;
    }
    return new Intl.NumberFormat("pt-BR", {
      minimumFractionDigits: 0,
      maximumFractionDigits: digits,
    }).format(number);
  }

  function formatPercent(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) {
      return "—";
    }
    const sign = number > 0 ? "+" : "";
    return `${sign}${number.toFixed(2)}%`;
  }

  function formatDate(value) {
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
    if (days < 7) {
      return `há ${days} d`;
    }
    return "";
  }

  async function fetchJson(url) {
    // Teto de espera: com o servidor local preso, o ciclo de 1 s nao pode
    // ficar pendurado para sempre e parecer que esta atualizando.
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), 12000);
    let response;
    try {
      response = await fetch(url, {
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
    } catch (error) {
      if (error && error.name === "AbortError") {
        throw new Error("O servidor local não respondeu em 12 s.");
      }
      throw error;
    } finally {
      window.clearTimeout(timer);
    }
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
    if (!payload || typeof payload !== "object") {
      throw new Error("O servidor respondeu sem dados de mercado.");
    }
    return payload;
  }

  function sparkline(values, positive) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 100 28");
    svg.setAttribute("class", `sparkline ${positive ? "is-up" : "is-down"}`);
    svg.setAttribute("aria-hidden", "true");
    const points = (Array.isArray(values) ? values : [])
      .map((item) => Number(item))
      .filter((item) => Number.isFinite(item));
    if (points.length < 2) {
      return svg;
    }
    let min = Math.min(...points);
    let max = Math.max(...points);
    if (max - min === 0) {
      max = min + 1;
      min = min - 1;
    }
    const step = 100 / (points.length - 1);
    const path = points
      .map((point, index) => {
        const x = index * step;
        const y = 26 - ((point - min) / (max - min)) * 24;
        return `${x.toFixed(1)},${y.toFixed(1)}`;
      })
      .join(" ");
    const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
    line.setAttribute("points", path);
    line.setAttribute("fill", "none");
    line.setAttribute("stroke-width", "1.6");
    line.setAttribute("stroke-linecap", "round");
    line.setAttribute("stroke-linejoin", "round");
    svg.append(line);
    return svg;
  }

  function feedLabel(quote) {
    if (quote.live) {
      return "tempo real";
    }
    const delay = Number(quote.delaySeconds);
    if (delay > 0) {
      return `${Math.round(delay / 60)} min`;
    }
    return "atraso";
  }

  function buildMarket(groups, data) {
    marketGroups.replaceChildren();
    const cryptoSource =
      data.cryptoSource && data.cryptoSource.name ? data.cryptoSource : null;
    let rowIndex = 0;
    for (const group of groups) {
      const items = Array.isArray(group.items) ? group.items : [];
      if (items.length === 0) {
        continue;
      }
      const meta = GROUP_META[group.key] || {};
      const card = el("div", "market-group");
      if (group.key) {
        card.dataset.group = group.key;
      }

      const heading = el("div", "market-group-head");
      const titleWrap = el("div", "market-group-title");
      const dot = el("span", "market-group-dot");
      dot.dataset.tone = meta.tone || "blue";
      dot.setAttribute("aria-hidden", "true");
      titleWrap.append(dot, el("h3", null, group.label || meta.label || "Mercado"));
      heading.append(titleWrap, el("span", "market-group-count", `${items.length} ativos`));
      card.append(heading);

      // A referencia em R$/24h continua declarada, mas sem uma linha extra
      // dentro do cartao: cripto e moedas precisam ter a mesma estrutura. A
      // atribuicao so entra quando alguma linha realmente usa essa fonte.
      const usesCryptoReference = items.some(
        (quote) => String(quote.source) === "Investidor10",
      );
      if (group.key === "crypto" && cryptoSource && usesCryptoReference) {
        card.title = `${cryptoSource.name} · cotação em R$ e variação 24h`;
      }

      const rows = el("div", "market-rows");
      for (const quote of items) {
        const isCrypto = Boolean(quote.url && quote.source === "Investidor10");
        const has24h =
          isCrypto && quote.change24h !== null && quote.change24h !== undefined;
        const changeValue = has24h ? Number(quote.change24h) : Number(quote.changePercent);
        const positive = Number.isFinite(changeValue)
          ? changeValue >= 0
          : Number(quote.changePercent) >= 0;

        const row = document.createElement(isCrypto ? "a" : "div");
        row.className = `market-row${isCrypto ? " market-row--link" : ""}`;
        row.style.setProperty("--i", String(rowIndex));
        rowIndex += 1;
        if (isCrypto) {
          row.href = quote.url;
          row.target = "_blank";
          row.rel = "noopener noreferrer";
          row.title = `${quote.label || quote.symbol} no Investidor10`;
        }

        const name = el("div", "market-name");
        const nameLabel = el("strong", null, quote.label || quote.symbol);
        if (isCrypto) {
          nameLabel.append(el("span", "market-external", "↗"));
        }
        name.append(nameLabel, el("span", null, quote.symbol));

        const chart = sparkline(quote.spark, positive);
        const price = el("div", "market-price");
        price.append(el("strong", null, formatPrice(quote.price)));
        const change = el(
          "span",
          `market-change ${positive ? "is-up" : "is-down"}`,
          formatPercent(changeValue),
        );
        change.append(el("small", "market-change-window", has24h ? "24h" : "dia"));
        price.append(change);
        if (isCrypto && Number.isFinite(Number(quote.brl))) {
          price.append(el("span", "market-brl", `R$ ${formatPrice(quote.brl)}`));
        }
        if (String(quote.source) === "TradingView") {
          const live = quote.live === true;
          price.append(
            el("span", `market-feed ${live ? "is-live" : "is-delayed"}`, feedLabel(quote)),
          );
        }

        row.append(name, chart, price);
        rows.append(row);
      }
      card.append(rows);
      marketGroups.append(card);
    }

    if (marketGroups.childElementCount === 0) {
      marketGroups.append(el("p", "radar-placeholder", "Nenhuma cotação disponível agora."));
    }

    // Guarda as referencias de cada linha para o proximo ciclo so trocar o
    // texto. Reconstruir a lista a cada segundo reiniciava as animacoes e
    // fazia a tela piscar.
    marketNodeMap = new Map();
    const rowNodes = marketGroups.querySelectorAll(".market-row");
    let rowCursor = 0;
    for (const group of groups) {
      for (const quote of Array.isArray(group.items) ? group.items : []) {
        const row = rowNodes[rowCursor];
        rowCursor += 1;
        if (!row) {
          continue;
        }
        marketNodeMap.set(quote.symbol, {
          row,
          priceStrong: row.querySelector(".market-price > strong"),
          change: row.querySelector(".market-change"),
          windowLabel: row.querySelector(".market-change-window"),
          brl: row.querySelector(".market-brl"),
          feed: row.querySelector(".market-feed"),
          prevPrice: Number(quote.price),
        });
      }
    }
  }

  function patchMarket(groups) {
    // Devolve false quando aparece um ativo sem linha montada: o chamador
    // reconstroi a lista uma vez. Ativo que sumiu e apenas escondido, para
    // uma falha isolada nao reiniciar todas as animacoes da tela.
    let complete = true;
    const present = new Set();
    for (const group of Array.isArray(groups) ? groups : []) {
      for (const quote of Array.isArray(group.items) ? group.items : []) {
        const nodes = marketNodeMap.get(quote.symbol);
        if (!nodes) {
          complete = false;
          continue;
        }
        present.add(quote.symbol);
        if (nodes.row.hidden) {
          nodes.row.hidden = false;
        }
        const isCrypto = Boolean(quote.url && quote.source === "Investidor10");
        const has24h =
          isCrypto && quote.change24h !== null && quote.change24h !== undefined;
        const changeValue = has24h ? Number(quote.change24h) : Number(quote.changePercent);
        const positive = Number.isFinite(changeValue)
          ? changeValue >= 0
          : Number(quote.changePercent) >= 0;

        const priceText = formatPrice(quote.price);
        if (nodes.priceStrong && nodes.priceStrong.textContent !== priceText) {
          const nextPrice = Number(quote.price);
          const previousPrice = Number(nodes.prevPrice);
          nodes.priceStrong.textContent = priceText;
          if (Number.isFinite(nextPrice) && Number.isFinite(previousPrice) && nextPrice !== previousPrice) {
            const up = nextPrice > previousPrice;
            nodes.row.classList.remove("is-tick-up", "is-tick-down");
            void nodes.row.offsetWidth;
            nodes.row.classList.add(up ? "is-tick-up" : "is-tick-down");
          }
          nodes.prevPrice = nextPrice;
        }
        if (nodes.change) {
          nodes.change.textContent = "";
          nodes.change.append(document.createTextNode(formatPercent(changeValue)));
          nodes.change.className = `market-change ${positive ? "is-up" : "is-down"}`;
          if (nodes.windowLabel) {
            nodes.windowLabel.textContent = has24h ? "24h" : "dia";
            nodes.change.append(nodes.windowLabel);
          }
        }
        if (nodes.brl) {
          nodes.brl.textContent = `R$ ${formatPrice(quote.brl)}`;
        }
        if (nodes.feed) {
          const live = quote.live === true;
          nodes.feed.textContent = feedLabel(quote);
          nodes.feed.className = `market-feed ${live ? "is-live" : "is-delayed"}`;
        }
      }
    }
    marketNodeMap.forEach((nodes, symbol) => {
      if (!present.has(symbol)) {
        nodes.row.hidden = true;
      }
    });
    return complete;
  }

  function renderMarket(data) {
    const groups = Array.isArray(data.groups) ? data.groups : [];
    const signature = groups.map((group) => String(group.key || "")).join("|");
    if (signature !== marketSignature || marketNodeMap.size === 0) {
      marketSignature = signature;
      buildMarket(groups, data);
    } else if (!patchMarket(groups)) {
      buildMarket(groups, data);
    }
    // O letreiro so e remendado quando a lista de ativos e a mesma; se algum
    // ativo sai, os itens mudam de posicao e remendar por indice trocaria
    // preco de ativo. Nesse caso ele e remontado.
    const tapeSignature = groups
      .map((group) =>
        (Array.isArray(group.items) ? group.items : [])
          .map((item) => item.symbol)
          .join(","),
      )
      .join("|");
    if (tapeSignature !== marketTapeSignature) {
      marketTapeSignature = tapeSignature;
      renderTape(groups);
    } else {
      patchTape(groups);
    }
    updateMarketStatus(data);
  }

  function updateMarketStatus(data) {
    const feed = data.quotes && data.quotes.source ? data.quotes : null;
    const failed = Array.isArray(data.failed) ? data.failed : [];
    const live = feed ? Number(feed.live) || 0 : 0;
    const stamp = formatClock(data.at);
    if (live === 0) {
      // Zero ativo em tempo real e o unico caso de erro global; quem chama
      // ja pintou o estado e o texto.
      return;
    }
    const base = `TradingView: ${live} ativo(s) em tempo real · lido ${stamp}.`;
    if (failed.length === 0) {
      setStatus(radarStatus, base, "ok");
      return;
    }
    // Falha por ativo: ele fica fora da lista e a tela segue normal. Isso nao
    // e erro do painel, entao a cor de erro nao aparece.
    const outside =
      failed.length === 1
        ? "1 ativo sem preço em tempo real ficou fora agora"
        : `${failed.length} ativos sem preço em tempo real ficaram fora agora`;
    setStatus(radarStatus, `${base} ${outside}.`, "");
  }

  // Faixa propria (sem iframe do TradingView): mesmo dado do scanner,
  // montado com o nosso visual. Duplicamos a lista para o loop nao ter buraco.
  function renderTape(groups) {
    if (!tapeTrack) {
      return;
    }
    tapeTrack.replaceChildren();
    const quotes = [];
    for (const group of Array.isArray(groups) ? groups : []) {
      for (const quote of Array.isArray(group.items) ? group.items : []) {
        quotes.push(quote);
      }
    }
    if (quotes.length === 0) {
      tapeTrack.append(el("p", "live-tape-empty", "Sem cotações agora."));
      return;
    }

    const buildItems = (duplicate) => {
      const fragment = document.createDocumentFragment();
      for (const quote of quotes) {
        const item = el("span", "live-tape-item");
        if (duplicate) {
          item.setAttribute("aria-hidden", "true");
        }
        const change = Number(quote.changePercent);
        const positive = Number.isFinite(change) ? change >= 0 : true;
        item.append(
          el("span", `live-tape-dot ${quote.live === true ? "is-live" : "is-delayed"}`),
          el("span", "live-tape-symbol", String(quote.label || quote.symbol || "").toUpperCase()),
          el("span", "live-tape-price", formatPrice(quote.price)),
          el(
            "span",
            `live-tape-change ${positive ? "is-up" : "is-down"}`,
            formatPercent(change),
          ),
        );
        fragment.append(item);
      }
      return fragment;
    };

    tapeTrack.append(buildItems(false), buildItems(true));
    tapeTrack.style.setProperty("--tape-duration", `${Math.max(30, quotes.length * 4)}s`);
  }

  // Atualiza a faixa sem reiniciar a animacao do letreiro.
  function patchTape(groups) {
    if (!tapeTrack) {
      return;
    }
    const quotes = [];
    for (const group of Array.isArray(groups) ? groups : []) {
      for (const quote of Array.isArray(group.items) ? group.items : []) {
        quotes.push(quote);
      }
    }
    if (quotes.length === 0) {
      return;
    }
    tapeTrack.querySelectorAll(".live-tape-item").forEach((item, index) => {
      const quote = quotes[index % quotes.length];
      if (!quote) {
        return;
      }
      const change = Number(quote.changePercent);
      const positive = Number.isFinite(change) ? change >= 0 : true;
      const symbolNode = item.querySelector(".live-tape-symbol");
      const priceNode = item.querySelector(".live-tape-price");
      const changeNode = item.querySelector(".live-tape-change");
      const dotNode = item.querySelector(".live-tape-dot");
      if (symbolNode) {
        symbolNode.textContent = String(quote.label || quote.symbol || "").toUpperCase();
      }
      if (priceNode) {
        priceNode.textContent = formatPrice(quote.price);
      }
      if (changeNode) {
        changeNode.textContent = formatPercent(change);
        changeNode.className = `live-tape-change ${positive ? "is-up" : "is-down"}`;
      }
      if (dotNode) {
        dotNode.className = `live-tape-dot ${quote.live === true ? "is-live" : "is-delayed"}`;
      }
    });
  }

  async function loadMarket(force, silent) {
    if (marketLoading) {
      // Clique que caiu no meio de uma leitura do ciclo automatico: guarda o
      // pedido e atende assim que ela terminar, em vez de engolir o toque.
      if (force && !silent) {
        marketRefreshQueued = true;
        setStatus(radarStatus, "Atualização pedida; lendo as cotações agora…");
      }
      return;
    }
    if (marketLoaded && !force) {
      return;
    }
    marketLoading = true;
    // O ciclo automatico NAO desabilita o botao: alternar `disabled` a cada
    // ~500 ms fazia o botao piscar e perder cliques (o "toque fantasma").
    // Requisicao empilhada continua barrada pelo guarda marketLoading.
    if (!silent) {
      refreshButton.disabled = true;
    }
    // A varredura so aparece em busca de verdade: primeira carga ou clique em
    // "Atualizar". O ciclo automatico de 1 s nao pode piscar o texto a cada
    // segundo (era o que fazia o rotulo alternar sozinho).
    const scanning = !silent || !marketReceivedAt;
    if (!silent) {
      setStatus(radarStatus, "Buscando cotações no TradingView…");
      if (!marketLoaded) {
        marketGroups.replaceChildren(el("p", "radar-placeholder", "Carregando cotações…"));
      }
    }
    if (scanning) {
      setLiveState(
        radarLive,
        radarLiveLabel,
        radarLiveMeta,
        "scanning",
        "Varrendo o mercado",
        "lendo cotações em tempo real",
      );
      marketGroups.classList.add("is-scanning");
    } else if (radarLive) {
      radarLive.classList.add("is-refreshing");
    }
    try {
      const data = await fetchJson("/api/market");
      const live = data.quotes ? Number(data.quotes.live) || 0 : 0;
      marketFailures = 0;
      if (live > 0) {
        renderMarket(data);
        marketLoaded = true;
        marketReceivedAt = Date.now();
        marketLiveCount = live;
        setLiveState(
          radarLive,
          radarLiveLabel,
          radarLiveMeta,
          "live",
          "Tempo real",
          `${live} ativos · atualizado agora`,
        );
      } else {
        // Zero ativos em tempo real: erro global, painel vazio. Nada de
        // reaproveitar preco antigo como se fosse cotacao de agora.
        marketNodeMap = new Map();
        marketSignature = "";
        marketTapeSignature = "";
        marketGroups.replaceChildren(
          el(
            "p",
            "radar-placeholder",
            "Nenhum ativo com preço em tempo real neste instante. O painel fica vazio até a fonte responder.",
          ),
        );
        setStatus(
          radarStatus,
          "Nenhum ativo em tempo real agora. Nada é preenchido com preço antigo; nova tentativa em instantes.",
          "error",
        );
        setLiveState(
          radarLive,
          radarLiveLabel,
          radarLiveMeta,
          "error",
          "Sem ativos em tempo real",
          `lido ${formatClock(data.at) || "agora"}`,
        );
      }
    } catch (error) {
      marketFailures += 1;
      // Uma falha isolada nao derruba o painel: o ciclo seguinte tenta de
      // novo. Depois de tres seguidas a fonte e declarada fora do ar.
      if (marketFailures >= 3 || !marketReceivedAt) {
        if (!marketReceivedAt) {
          marketGroups.replaceChildren(
            el(
              "p",
              "radar-placeholder",
              "A fonte não respondeu. O painel fica vazio até a próxima leitura real.",
            ),
          );
        }
        setStatus(
          radarStatus,
          marketReceivedAt
            ? `Fonte sem resposta há ${marketFailures} tentativas. Última leitura real às ${formatClock(marketReceivedAt)} — os preços na tela são dessa hora.`
            : error.message,
          "error",
        );
        const age = marketReceivedAt
          ? Math.round((Date.now() - marketReceivedAt) / 1000)
          : 0;
        setLiveState(
          radarLive,
          radarLiveLabel,
          radarLiveMeta,
          "error",
          "Fonte sem resposta",
          marketReceivedAt ? `última leitura há ${age}s` : "nenhuma leitura ainda",
        );
      } else {
        setStatus(
          radarStatus,
          `Leitura falhou agora; tentando de novo. Última leitura real às ${formatClock(marketReceivedAt)}.`,
          "",
        );
      }
    } finally {
      marketLoading = false;
      refreshButton.disabled = false;
      marketGroups.classList.remove("is-scanning");
      radarLive?.classList.remove("is-refreshing");
      if (marketRefreshQueued) {
        marketRefreshQueued = false;
        window.setTimeout(() => loadMarket(true, false), 0);
      }
    }
  }

  function selectTab(key) {
    tabs.forEach((tab) => {
      const active = tab.dataset.radarTab === key;
      tab.setAttribute("aria-selected", String(active));
      tab.classList.toggle("is-active", active);
    });
    panels.forEach((panel) => {
      panel.hidden = panel.dataset.radarPanel !== key;
    });
    if (key === "mercado") {
      loadMarket(false);
    }
    if (key === "grafico") {
      loadChart(false);
    }
  }

  tabs.forEach((tab) => {
    tab.addEventListener("click", () => selectTab(tab.dataset.radarTab));
  });

  refreshButton.addEventListener("click", () => loadMarket(true, false));

  // Ritmo de tempo real: o proximo ciclo so comeca quando o anterior termina,
  // entao uma resposta lenta nunca empilha requisicoes. Aba escondida pausa.
  function scheduleMarketPoll(delay) {
    window.clearTimeout(marketPollTimer);
    marketPollTimer = window.setTimeout(async () => {
      if (document.hidden) {
        scheduleMarketPoll(1500);
        return;
      }
      await loadMarket(true, true);
      scheduleMarketPoll(500);
    }, delay);
  }
  scheduleMarketPoll(800);

  // Contador honesto: mostra ha quanto tempo veio a ultima leitura real.
  window.setInterval(() => {
    if (!radarLive || radarLive.dataset.state !== "live" || !marketReceivedAt) {
      return;
    }
    const seconds = Math.max(0, Math.round((Date.now() - marketReceivedAt) / 1000));
    setLiveState(
      radarLive,
      null,
      radarLiveMeta,
      "live",
      null,
      `${marketLiveCount} ativos · ${seconds <= 1 ? "atualizado agora" : `atualizado há ${seconds}s`}`,
    );
  }, 1000);

  // Carrega so quando o usuario realmente chega ao radar (ou clica no menu).
  const navLink = document.querySelector('a.nav-link[href="#radar"]');
  if (navLink) {
    navLink.addEventListener("click", () => loadMarket(false));
  }
  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          loadMarket(false);
          observer.disconnect();
        }
      },
      { rootMargin: "200px" },
    );
    observer.observe(section);
  }

  function populateSymbols(select) {
    if (!select) {
      return;
    }
    for (const item of SYMBOLS) {
      const option = document.createElement("option");
      option.value = item.symbol;
      option.textContent = `${item.label} (${item.symbol})`;
      select.append(option);
    }
  }
  populateSymbols(backtestSymbol);
  populateSymbols(planSymbol);
  if (backtestSymbol) {
    backtestSymbol.value = "BTC-USD";
  }
  if (planSymbol) {
    planSymbol.value = "BTC-USD";
  }

  function signalBadge(signal) {
    const normalized = String(signal || "NEUTRAL");
    return el("span", `signal-badge signal-${normalized.toLowerCase()}`, normalized);
  }

  const scannerSummary = document.getElementById("scanner-summary");
  const scannerFilters = document.getElementById("scanner-filters");
  let scannerItems = [];
  let scannerFilter = "all";
  let scannerMeta = { scanned: 0 };

  function renderScanner(data) {
    scannerItems = Array.isArray(data.items) ? data.items : [];
    scannerMeta = { scanned: Number(data.scanned) || scannerItems.length };
    scannerFilter = "all";
    renderScannerSummary();
    renderScannerRows();
  }

  function renderScannerSummary() {
    if (!scannerSummary) {
      return;
    }
    const counts = { LONG: 0, SHORT: 0, NEUTRAL: 0 };
    for (const item of scannerItems) {
      const key = counts[item.signal] === undefined ? "NEUTRAL" : item.signal;
      counts[key] += 1;
    }
    const best = scannerItems[0];
    scannerSummary.replaceChildren();
    const add = (label, value, tone) => {
      const card = el("div", `scanner-stat${tone ? ` is-${tone}` : ""}`);
      card.append(el("strong", null, String(value)), el("span", null, label));
      scannerSummary.append(card);
    };
    add("ativos varridos", scannerMeta.scanned);
    add("compras", counts.LONG, "long");
    add("vendas", counts.SHORT, "short");
    add("neutros", counts.NEUTRAL);
    if (best) {
      add(
        "melhor leitura",
        `${best.label} ${Number(best.score) > 0 ? "+" : ""}${Number(best.score).toFixed(0)}`,
      );
    }
    renderScannerFilters(counts);
  }

  function renderScannerFilters(counts) {
    if (!scannerFilters) {
      return;
    }
    const options = [
      ["all", `Todos · ${scannerItems.length}`],
      ["LONG", `Compras · ${counts.LONG}`],
      ["SHORT", `Vendas · ${counts.SHORT}`],
      ["NEUTRAL", `Neutros · ${counts.NEUTRAL}`],
    ];
    scannerFilters.replaceChildren();
    for (const [key, label] of options) {
      const chip = el("button", "scanner-filter", label);
      chip.type = "button";
      chip.setAttribute("aria-pressed", String(scannerFilter === key));
      chip.classList.toggle("is-active", scannerFilter === key);
      chip.addEventListener("click", () => {
        scannerFilter = key;
        renderScannerSummary();
        renderScannerRows();
      });
      scannerFilters.append(chip);
    }
  }

  function renderScannerRows() {
    scannerList.replaceChildren();
    if (scannerItems.length === 0) {
      scannerList.append(el("p", "radar-placeholder", "A varredura não encontrou ativos."));
      return;
    }
    const filtered =
      scannerFilter === "all"
        ? scannerItems
        : scannerItems.filter((item) => item.signal === scannerFilter);
    if (filtered.length === 0) {
      scannerList.append(
        el("p", "radar-placeholder", "Nenhum ativo com esse sinal agora. Tente outra varredura."),
      );
      return;
    }

    const header = el("div", "scanner-row scanner-header");
    header.append(
      el("span", null, "ATIVO"),
      el("span", null, "SINAL"),
      el("span", null, "PREÇO"),
      el("span", null, "RSI"),
      el("span", null, "ATR%"),
      el("span", null, "LEITURA"),
    );
    scannerList.append(header);

    filtered.forEach((item, index) => {
      const row = el("div", "scanner-row");
      row.style.setProperty("--i", String(index));

      const asset = el("div", "scanner-asset");
      asset.append(el("strong", null, item.label || item.symbol));
      asset.append(el("span", null, item.symbol));
      row.append(asset, signalBadge(item.signal));

      const change = Number(item.changePercent);
      const priceCell = el("div", "scanner-price-cell");
      priceCell.append(el("strong", "scanner-number", formatPrice(item.price)));
      priceCell.append(
        el("span", `scanner-change ${change >= 0 ? "is-up" : "is-down"}`, formatPercent(change)),
      );
      row.append(priceCell);
      row.append(el("span", "scanner-number", Number(item.rsi).toFixed(0)));
      row.append(el("span", "scanner-number", `${Number(item.atrPercent).toFixed(2)}%`));

      const reasons = el("span", "scanner-reasons", (item.reasons || []).join(" · "));
      const scoreWrap = el("span", "scanner-score-wrap");
      scoreWrap.append(
        el(
          "span",
          "scanner-score",
          `score ${Number(item.score) > 0 ? "+" : ""}${Number(item.score).toFixed(1)}`,
        ),
      );
      const bar = el("span", "scanner-bar");
      const fill = el("i");
      fill.style.width = `${Math.min(100, (Math.abs(Number(item.score)) / 60) * 100)}%`;
      bar.append(fill);
      scoreWrap.append(bar);
      reasons.append(scoreWrap);
      row.append(reasons);
      scannerList.append(row);
    });
  }

  function showScannerSkeleton() {
    scannerList.replaceChildren();
    for (let i = 0; i < 6; i++) {
      const row = el("div", "scanner-row scanner-skeleton-row");
      row.style.setProperty("--i", String(i));
      for (let column = 0; column < 6; column++) {
        row.append(el("span", "skeleton-bar"));
      }
      scannerList.append(row);
    }
  }

  scannerRun.addEventListener("click", async () => {
    if (scannerLoading) {
      return;
    }
    scannerLoading = true;
    scannerRun.disabled = true;
    scannerRun.textContent = "Varrendo…";
    setStatus(scannerStatus, "Varrendo a watchlist em tempo real, candles de 5 minutos…");
    setLiveState(
      scannerLive,
      scannerLiveLabel,
      scannerLiveMeta,
      "scanning",
      "Varrendo cotações e setups",
      "lendo candles de 5 minutos",
    );
    if (scannerSummary) {
      scannerSummary.replaceChildren();
    }
    if (scannerFilters) {
      scannerFilters.replaceChildren();
    }
    showScannerSkeleton();
    try {
      const data = await fetchJson("/api/scanner");
      renderScanner(data);
      const failed = Array.isArray(data.failed) ? data.failed.length : 0;
      const longCount = scannerItems.filter((item) => item.signal === "LONG").length;
      const shortCount = scannerItems.filter((item) => item.signal === "SHORT").length;
      const scanned = Number(data.scanned) || scannerItems.length;
      if (scanned === 0) {
        setStatus(scannerStatus, "A varredura não encontrou nenhum ativo em tempo real agora.", "error");
        setLiveState(
          scannerLive,
          scannerLiveLabel,
          scannerLiveMeta,
          "error",
          "Sem ativos em tempo real",
          `lido ${formatClock(data.at) || "agora"}`,
        );
      } else {
        // Ativo sem resposta fica fora da lista, mas nao e falha da varredura.
        const outside = failed
          ? failed === 1
            ? " · 1 sem preço ao vivo ficou fora"
            : ` · ${failed} sem preço ao vivo ficaram fora`
          : "";
        setStatus(
          scannerStatus,
          `Varredura concluída em ${scanned} ativos · ${longCount} compra(s), ${shortCount} venda(s)${outside}.`,
          "ok",
        );
        setLiveState(
          scannerLive,
          scannerLiveLabel,
          scannerLiveMeta,
          "ok",
          "Varredura concluída",
          `${scanned} ativos lidos às ${formatClock(data.at)}${failed ? ` · ${failed} fora` : ""}`,
        );
      }
    } catch (error) {
      setStatus(scannerStatus, error.message, "error");
      setLiveState(
        scannerLive,
        scannerLiveLabel,
        scannerLiveMeta,
        "error",
        "Varredura falhou",
        error.message,
      );
    } finally {
      scannerLoading = false;
      scannerRun.disabled = false;
      scannerRun.textContent = "Varrer agora";
    }
  });

  function statCard(label, value, hint) {
    const card = el("div", "stat-card");
    card.append(el("span", "stat-label", label));
    card.append(el("strong", "stat-value", value));
    if (hint) {
      card.append(el("span", "stat-hint", hint));
    }
    return card;
  }

  function renderBacktest(data) {
    const stats = data.stats || {};
    backtestResult.replaceChildren();
    const summary = el("div", "radar-result-head");
    summary.append(el("h3", null, `${data.label} · 60 dias em 5m`));
    summary.append(
      el(
        "p",
        null,
        `${stats.candles} candles · ${stats.trades} operações · ${data.strategy}. Período: ${formatDate(data.from)} a ${formatDate(data.to)}.`,
      ),
    );
    backtestResult.append(summary);

    const grid = el("div", "stats-grid");
    grid.append(statCard("Acerto", `${stats.winRate}%`, `${stats.wins}W / ${stats.losses}L`));
    grid.append(statCard("Resultado médio", `${stats.avgR}R`, "por operação"));
    grid.append(statCard("Fator de lucro", String(stats.profitFactor), "ganhos ÷ perdas"));
    grid.append(
      statCard("Simulações", String(stats.simulations), `${stats.probProfit}% terminaram positivas`),
    );
    grid.append(statCard("Resultado mediano", `${stats.medianR}R`, "10 mil reamostragens"));
    grid.append(statCard("Faixa provável", `${stats.p5R}R a ${stats.p95R}R`, "5% a 95%"));
    grid.append(statCard("Pior drawdown", `${stats.maxDrawdownR}R`, "no cenário simulado"));
    grid.append(
      statCard("Stop / alvo", `${stats.stopAtr} / ${stats.targetAtr} ATR`, "regra executada"),
    );
    backtestResult.append(grid);
    backtestResult.append(
      el(
        "p",
        "radar-disclaimer",
        "Backtest não garante resultado futuro. Custos, spread e slippage não estão incluídos; a simulação usa apenas o histórico público disponível.",
      ),
    );
    backtestResult.hidden = false;
  }

  const BACKTEST_PHASES = {
    candles: { label: "Baixando 60 dias de candles reais…", tag: "histórico" },
    trades: { label: "Lendo o histórico candle a candle…", tag: "trades" },
    simulations: { label: "Reamostrando os trades encontrados…", tag: "simulações" },
    done: { label: "Simulação concluída", tag: "concluído" },
    failed: { label: "Simulação interrompida", tag: "falhou" },
  };

  function formatCount(value) {
    return new Intl.NumberFormat("pt-BR").format(Number(value) || 0);
  }

  // Progresso REAL vindo do servidor: candles processados, trades encontrados e
  // reamostragens concluídas. Nada aqui avança sozinho.
  function setBacktestProgress(progress) {
    if (!backtestTimeline) {
      return;
    }
    backtestLastProgress = progress;
    backtestTimeline.hidden = false;
    const state = String(progress.state || "running");
    const phaseKey = state === "failed" ? "failed" : String(progress.phase || "candles");
    const phase = BACKTEST_PHASES[phaseKey] || BACKTEST_PHASES.candles;
    backtestTimeline.dataset.state = state;
    // Animacao propria da Maquina do tempo (faixa ciano), so enquanto roda.
    backtestTimeline.classList.toggle("is-running", state === "running");
    if (backtestPhase) {
      backtestPhase.textContent = phase.label;
    }
    if (backtestPhaseTag) {
      backtestPhaseTag.textContent = phase.tag;
    }
    if (backtestElapsed) {
      const seconds = (Number(progress.elapsedMs) || 0) / 1000;
      backtestElapsed.textContent = `${seconds.toFixed(1).replace(".", ",")} s`;
    }
    if (backtestTrades) {
      backtestTrades.textContent = formatCount(progress.trades);
    }
    const total = Number(progress.total) || 0;
    const done = Math.max(
      0,
      Math.min(Number(progress.done) || 0, total || Number.MAX_SAFE_INTEGER),
    );
    if (backtestCounter) {
      backtestCounter.textContent = formatCount(done);
    }
    if (backtestCounterLabel) {
      const unit = phaseKey === "simulations" || phaseKey === "done" ? "reamostragens" : "candles";
      backtestCounterLabel.textContent =
        total > 0
          ? `de ${formatCount(total)} ${unit}`
          : phaseKey === "candles"
            ? "aguardando os candles"
            : "sem total informado";
    }
    const percent = state === "done" ? 100 : total > 0 ? (done / total) * 100 : 0;
    if (backtestProgressFill) {
      backtestProgressFill.style.width = `${percent}%`;
    }
    if (backtestProgress) {
      backtestProgress.classList.toggle("is-waiting", total === 0 && state === "running");
      backtestProgress.setAttribute("aria-valuenow", String(Math.round(percent)));
    }

    const rails = backtestTimeline.querySelectorAll("[data-backtest-rail]");
    const order = ["candles", "trades", "simulations"];
    const activeIndex = order.indexOf(phaseKey);
    rails.forEach((rail, index) => {
      rail.classList.toggle(
        "is-done",
        state === "done" || (activeIndex >= 0 && index < activeIndex),
      );
      rail.classList.toggle("is-active", activeIndex === index && state === "running");
    });
  }

  function sleep(ms) {
    return new Promise((resolve) => window.setTimeout(resolve, ms));
  }

  async function pollBacktest(token) {
    while (token === backtestToken) {
      const progress = await fetchJson("/api/backtest/progress");
      if (token !== backtestToken) {
        return null;
      }
      if (progress.state === "idle") {
        throw new Error("A simulação não está mais rodando. Inicie de novo.");
      }
      setBacktestProgress(progress);
      if (progress.state === "done") {
        return progress;
      }
      if (progress.state === "failed") {
        throw new Error(progress.error || "A simulação falhou no servidor.");
      }
      await sleep(400);
    }
    return null;
  }

  backtestRun.addEventListener("click", async () => {
    if (backtestLoading) {
      return;
    }
    backtestLoading = true;
    backtestRun.disabled = true;
    backtestResult.hidden = true;
    backtestToken += 1;
    const token = backtestToken;
    setStatus(backtestStatus, "Preparando a Máquina do tempo…");
    setBacktestProgress({
      state: "running",
      phase: "candles",
      done: 0,
      total: 0,
      trades: 0,
      elapsedMs: 0,
    });
    try {
      const start = await fetchJson(
        `/api/backtest/start?symbol=${encodeURIComponent(backtestSymbol.value)}`,
      );
      setBacktestProgress(start);
      if (start.state === "done" && start.result) {
        renderBacktest(start.result);
        setStatus(backtestStatus, "Simulação concluída.", "ok");
      } else {
        const final = await pollBacktest(token);
        if (final && final.result) {
          renderBacktest(final.result);
          setStatus(backtestStatus, "Simulação concluída.", "ok");
        }
      }
    } catch (error) {
      setStatus(backtestStatus, error.message, "error");
      setBacktestProgress({
        ...(backtestLastProgress || {}),
        state: "failed",
        phase: "failed",
      });
    } finally {
      backtestLoading = false;
      backtestRun.disabled = false;
    }
  });

  function renderPlan(data) {
    const plan = data.plan || {};
    planResult.replaceChildren();
    const head = el("div", "radar-result-head");
    head.append(el("h3", null, `${data.label} · ${data.timeframe}`));
    head.append(
      el(
        "p",
        null,
        `Viés ${plan.bias} · break-even de ${plan.breakEvenWinRate}% de acerto para o alvo de ${plan.riskReward}R.`,
      ),
    );
    planResult.append(head);

    const grid = el("div", "stats-grid");
    grid.append(statCard("Entrada", formatPrice(plan.entry), "preço atual"));
    grid.append(statCard("Stop", formatPrice(plan.stop), `risco ${formatPrice(plan.riskPerUnit)}`));
    grid.append(statCard("Alvo", formatPrice(plan.target), `ganho ${formatPrice(plan.rewardPerUnit)}`));
    grid.append(statCard("Risco/retorno", `${plan.riskReward}R`, "por unidade"));
    grid.append(statCard("ATR", formatPrice(plan.atr), `${plan.atrPercent}% do preço`));
    grid.append(statCard("Invalidação", plan.bias === "SHORT" ? "acima do stop" : "abaixo do stop", "regra do plano"));
    planResult.append(grid);
    planResult.append(
      el(
        "p",
        "radar-disclaimer",
        "Plano mecânico baseado em ATR e swing recente. Confirme no seu gráfico e respeite o risco definido.",
      ),
    );
    planResult.hidden = false;
  }

  planRun.addEventListener("click", async () => {
    if (planLoading) {
      return;
    }
    planLoading = true;
    planRun.disabled = true;
    planResult.hidden = true;
    setStatus(planStatus, "Montando entrada, stop e alvo…");
    try {
      const data = await fetchJson(`/api/plan?symbol=${encodeURIComponent(planSymbol.value)}`);
      renderPlan(data);
      setStatus(planStatus, "Plano pronto.", "ok");
    } catch (error) {
      setStatus(planStatus, error.message, "error");
    } finally {
      planLoading = false;
      planRun.disabled = false;
    }
  });

  document.querySelectorAll(".step-button").forEach((button) => {
    button.addEventListener("click", () => {
      const input = document.getElementById(button.dataset.stepTarget || "");
      if (!input) {
        return;
      }
      const step = Number(input.step) || 1;
      const decimals = (String(input.step).split(".")[1] || "").length;
      const min = input.min === "" ? -Infinity : Number(input.min);
      const max = input.max === "" ? Infinity : Number(input.max);
      const current = Number(input.value);
      const base = Number.isFinite(current) ? current : 0;
      const next = base + (button.dataset.stepDir === "down" ? -step : step);
      input.value = Math.min(max, Math.max(min, next)).toFixed(decimals);
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
  });

  riskForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const balance = Number(document.getElementById("risk-balance").value);
    const riskPercent = Number(document.getElementById("risk-percent").value);
    const entry = Number(document.getElementById("risk-entry").value);
    const stop = Number(document.getElementById("risk-stop").value);
    const target = Number(document.getElementById("risk-target").value);

    if (!Number.isFinite(balance) || balance <= 0) {
      setStatus(riskStatus, "Informe um saldo maior que zero.", "error");
      return;
    }
    if (!Number.isFinite(riskPercent) || riskPercent <= 0 || riskPercent > 100) {
      setStatus(riskStatus, "O risco precisa ficar entre 0 e 100%.", "error");
      return;
    }
    const distance = Math.abs(entry - stop);
    if (!Number.isFinite(distance) || distance <= 0) {
      setStatus(riskStatus, "O stop precisa ser diferente do preço de entrada.", "error");
      return;
    }

    const riskAmount = balance * (riskPercent / 100);
    const size = riskAmount / distance;
    const notional = size * entry;
    const rr = Number.isFinite(target) && target > 0 ? Math.abs(target - entry) / distance : 0;
    const breakEven = rr > 0 ? 100 / (1 + rr) : 0;

    riskResult.replaceChildren();
    const grid = el("div", "stats-grid");
    grid.append(statCard("Risco máximo", `R$ ${riskAmount.toFixed(2)}`, `${riskPercent}% da conta`));
    grid.append(statCard("Tamanho da posição", size.toFixed(4), "unidades do ativo"));
    grid.append(statCard("Notional", `R$ ${notional.toFixed(2)}`, "exposição aproximada"));
    grid.append(statCard("Distância do stop", distance.toFixed(6), "por unidade"));
    if (rr > 0) {
      grid.append(statCard("Risco/retorno", `${rr.toFixed(2)}R`, "até o alvo"));
      grid.append(statCard("Acerto mínimo", `${breakEven.toFixed(1)}%`, "para empatar no alvo"));
    }
    riskResult.append(grid);
    riskResult.append(
      el(
        "p",
        "radar-disclaimer",
        "O cálculo não considera taxas, alavancagem, spread ou arredondamento do ativo. Confirme o tamanho mínimo na sua corretora.",
      ),
    );
    riskResult.hidden = false;
    setStatus(riskStatus, "Cálculo pronto.", "ok");
  });
  // =====================================================================
  // GRAFICO PROPRIO: candles reais + preco do TradingView, desenhado aqui
  // (sem iframe). SVG puro, crosshair, area/velas, EMA e animacoes.
  // =====================================================================
  const chartSymbol = document.getElementById("chart-symbol");
  const chartIntervals = document.getElementById("chart-intervals");
  const chartTypes = document.getElementById("chart-types");
  const chartEmaButton = document.getElementById("chart-ema");
  const chartRefreshButton = document.getElementById("chart-refresh");
  const chartSvg = document.getElementById("chart-svg");
  const chartTooltip = document.getElementById("chart-tooltip");
  const chartSkeleton = document.getElementById("chart-skeleton");
  const chartCard = document.getElementById("chart-card");
  const chartLabelNode = document.getElementById("chart-label");
  const chartPriceNode = document.getElementById("chart-price");
  const chartChangeNode = document.getElementById("chart-change");
  const chartBadges = document.getElementById("chart-badges");
  const chartStatus = document.getElementById("chart-status");
  const chartNote = document.getElementById("chart-note");
  const chartStage = document.getElementById("chart-stage");

  const CHART_BOX = { width: 1000, height: 380, left: 10, right: 70, top: 18, bottom: 28 };
  const chartState = {
    symbol: "BTC-USD",
    interval: "5m",
    type: "area",
    ema: false,
    data: null,
    loading: false,
    geometry: null,
  };

  if (chartSymbol) {
    populateSymbols(chartSymbol);
    chartSymbol.value = chartState.symbol;
  }

  function svgNode(tag, attrs) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    if (attrs) {
      for (const key of Object.keys(attrs)) {
        node.setAttribute(key, String(attrs[key]));
      }
    }
    return node;
  }

  function emaValues(values, period) {
    const factor = 2 / (period + 1);
    let previous = null;
    return values.map((value) => {
      previous = previous === null ? value : value * factor + previous * (1 - factor);
      return previous;
    });
  }

  function chartDate(value) {
    // O servidor manda epoch em segundos (padrao Yahoo); aceita ms tambem.
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) {
      return new Date(NaN);
    }
    return new Date(numeric < 1e11 ? numeric * 1000 : numeric);
  }

  function formatChartTime(value, interval) {
    const date = chartDate(value);
    if (Number.isNaN(date.getTime())) {
      return "";
    }
    if (interval === "1d") {
      return new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "2-digit" }).format(date);
    }
    return new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit" }).format(date);
  }

  function formatChartFullTime(value) {
    const date = chartDate(value);
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

  function syncChartControls() {
    if (chartIntervals) {
      for (const button of chartIntervals.querySelectorAll("[data-chart-interval]")) {
        const active = button.dataset.chartInterval === chartState.interval;
        button.classList.toggle("is-active", active);
        button.setAttribute("aria-pressed", String(active));
      }
    }
    if (chartTypes) {
      for (const button of chartTypes.querySelectorAll("[data-chart-type]")) {
        const active = button.dataset.chartType === chartState.type;
        button.classList.toggle("is-active", active);
        button.setAttribute("aria-pressed", String(active));
      }
    }
    if (chartEmaButton) {
      chartEmaButton.classList.toggle("is-active", chartState.ema);
      chartEmaButton.setAttribute("aria-pressed", String(chartState.ema));
    }
  }

  function renderChartHeader(data) {
    const quote = data.quote || {};
    const change = Number(quote.changePercent);
    if (chartLabelNode) {
      chartLabelNode.textContent = data.label || data.symbol;
    }
    if (chartPriceNode) {
      chartPriceNode.textContent = formatPrice(quote.price);
      chartPriceNode.classList.remove("is-up", "is-down");
      chartPriceNode.classList.add(change >= 0 ? "is-up" : "is-down");
    }
    if (chartChangeNode) {
      chartChangeNode.textContent = `${formatPercent(change)} · ${data.intervalLabel}`;
      chartChangeNode.classList.remove("is-up", "is-down");
      chartChangeNode.classList.add(change >= 0 ? "is-up" : "is-down");
    }
    if (chartBadges) {
      chartBadges.replaceChildren();
      const live = quote.live === true;
      const delay = Number(quote.delaySeconds);
      const priceBadge = el(
        "span",
        `chart-badge ${live ? "is-live" : "is-delayed"}`,
        quote.source === "TradingView"
          ? live
            ? "TradingView · tempo real"
            : `TradingView · ${delay > 0 ? `${Math.round(delay / 60)} min` : "atraso"}`
          : "Yahoo Finance",
      );
      chartBadges.append(priceBadge, el("span", "chart-badge", "candles: Yahoo Finance"));
      if (data.currency) {
        chartBadges.append(el("span", "chart-badge", String(data.currency)));
      }
    }
  }

  function renderChart(data) {
    if (!chartSvg) {
      return;
    }
    const candles = Array.isArray(data.candles) ? data.candles : [];
    if (candles.length < 2) {
      return;
    }
    const box = CHART_BOX;
    const plotWidth = box.width - box.left - box.right;
    const plotHeight = box.height - box.top - box.bottom;
    const lows = candles.map((candle) => Number(candle.l));
    const highs = candles.map((candle) => Number(candle.h));
    let min = Math.min(...lows);
    let max = Math.max(...highs);
    if (!Number.isFinite(min) || !Number.isFinite(max) || max <= min) {
      return;
    }
    const margin = (max - min) * 0.08;
    min -= margin;
    max += margin;
    const span = max - min;
    const step = plotWidth / candles.length;
    const bodyWidth = Math.max(2, Math.min(14, step * 0.62));
    const xOf = (index) => box.left + step * (index + 0.5);
    const yOf = (value) => box.top + ((max - value) / span) * plotHeight;
    const baseline = box.height - box.bottom;

    chartSvg.replaceChildren();

    const defs = svgNode("defs");
    const gradient = svgNode("linearGradient", {
      id: "znxChartFill",
      x1: "0",
      y1: "0",
      x2: "0",
      y2: "1",
    });
    gradient.append(
      svgNode("stop", { offset: "0%", "stop-color": "#4ade80", "stop-opacity": "0.42" }),
      svgNode("stop", { offset: "55%", "stop-color": "#4ade80", "stop-opacity": "0.12" }),
      svgNode("stop", { offset: "100%", "stop-color": "#4ade80", "stop-opacity": "0" }),
    );
    const gradientDown = svgNode("linearGradient", {
      id: "znxChartFillDown",
      x1: "0",
      y1: "0",
      x2: "0",
      y2: "1",
    });
    gradientDown.append(
      svgNode("stop", { offset: "0%", "stop-color": "#f87171", "stop-opacity": "0.34" }),
      svgNode("stop", { offset: "55%", "stop-color": "#f87171", "stop-opacity": "0.1" }),
      svgNode("stop", { offset: "100%", "stop-color": "#f87171", "stop-opacity": "0" }),
    );
    defs.append(gradient, gradientDown);
    chartSvg.append(defs);

    for (let tick = 0; tick <= 4; tick++) {
      const value = min + (span * tick) / 4;
      const y = yOf(value);
      chartSvg.append(
        svgNode("line", {
          x1: 0,
          x2: box.width - box.right,
          y1: y,
          y2: y,
          class: "chart-grid-line",
        }),
      );
      const label = svgNode("text", {
        x: box.width - box.right + 10,
        y: y + 4,
        class: "chart-axis-text",
      });
      label.textContent = formatPrice(value);
      chartSvg.append(label);
    }

    if (chartState.type === "area") {
      const points = candles.map(
        (candle, index) => `${xOf(index).toFixed(2)},${yOf(Number(candle.c)).toFixed(2)}`,
      );
      const linePath = `M${points.join(" L")}`;
      const areaPath = `${linePath} L${xOf(candles.length - 1).toFixed(2)},${baseline.toFixed(2)} L${xOf(0).toFixed(2)},${baseline.toFixed(2)} Z`;
      const first = Number(candles[0].c);
      const last = Number(candles[candles.length - 1].c);
      const tone = last >= first ? "is-up" : "is-down";
      chartSvg.append(
        svgNode("path", {
          d: areaPath,
          fill: `url(#${tone === "is-up" ? "znxChartFill" : "znxChartFillDown"})`,
          class: `chart-area ${tone}`,
        }),
      );
      const line = svgNode("path", { d: linePath, fill: "none", class: `chart-line ${tone}` });
      chartSvg.append(line);
      const length = typeof line.getTotalLength === "function" ? line.getTotalLength() : 0;
      if (length) {
        line.style.strokeDasharray = String(length);
        line.style.strokeDashoffset = String(length);
        requestAnimationFrame(() => {
          line.style.strokeDashoffset = "0";
        });
      }
    } else {
      candles.forEach((candle, index) => {
        const open = Number(candle.o);
        const high = Number(candle.h);
        const low = Number(candle.l);
        const close = Number(candle.c);
        const up = close >= open;
        const group = svgNode("g", { class: `chart-candle ${up ? "is-up" : "is-down"}` });
        group.style.animationDelay = `${Math.min(700, index * 3)}ms`;
        group.append(
          svgNode("line", {
            x1: xOf(index),
            x2: xOf(index),
            y1: yOf(high),
            y2: yOf(low),
            class: "chart-wick",
          }),
        );
        const top = yOf(Math.max(open, close));
        const height = Math.max(1.4, Math.abs(yOf(open) - yOf(close)));
        group.append(
          svgNode("rect", {
            x: xOf(index) - bodyWidth / 2,
            y: top,
            width: bodyWidth,
            height,
            rx: 0.8,
            class: "chart-body",
          }),
        );
        chartSvg.append(group);
      });
    }

    if (chartState.ema) {
      const closes = candles.map((candle) => Number(candle.c));
      const series = [
        ["9", "chart-ema-9"],
        ["21", "chart-ema-21"],
      ];
      for (const [period, className] of series) {
        const values = emaValues(closes, Number(period));
        const path = values
          .map(
            (value, index) =>
              `${index === 0 ? "M" : "L"}${xOf(index).toFixed(2)},${yOf(value).toFixed(2)}`,
          )
          .join(" ");
        chartSvg.append(svgNode("path", { d: path, fill: "none", class: `chart-ema ${className}` }));
      }
    }

    const lastClose = Number(candles[candles.length - 1].c);
    const lastY = yOf(lastClose);
    const lastUp = lastClose >= Number(candles[0].c);
    chartSvg.append(
      svgNode("line", {
        x1: 0,
        x2: box.width - box.right,
        y1: lastY,
        y2: lastY,
        class: `chart-last-line ${lastUp ? "is-up" : "is-down"}`,
      }),
    );
    chartSvg.append(
      svgNode("rect", {
        x: box.width - box.right + 4,
        y: lastY - 9,
        width: 62,
        height: 18,
        rx: 5,
        class: `chart-last-pill ${lastUp ? "is-up" : "is-down"}`,
      }),
    );
    const pillText = svgNode("text", {
      x: box.width - box.right + 35,
      y: lastY + 4,
      class: "chart-last-text",
      "text-anchor": "middle",
    });
    pillText.textContent = formatPrice(lastClose);
    chartSvg.append(pillText);

    for (let tick = 0; tick <= 4; tick++) {
      const index = Math.min(
        candles.length - 1,
        Math.round(((candles.length - 1) * tick) / 4),
      );
      const label = svgNode("text", {
        x: xOf(index),
        y: box.height - 8,
        class: "chart-axis-text",
        "text-anchor": tick === 0 ? "start" : tick === 4 ? "end" : "middle",
      });
      label.textContent = formatChartTime(candles[index].t, chartState.interval);
      chartSvg.append(label);
    }

    const cross = svgNode("g", { class: "chart-cross" });
    const crossV = svgNode("line", {
      y1: box.top,
      y2: baseline,
      class: "chart-cross-line",
    });
    const crossH = svgNode("line", {
      x1: 0,
      x2: box.width - box.right,
      class: "chart-cross-line",
    });
    const crossDot = svgNode("circle", { r: 3.6, class: "chart-cross-dot" });
    cross.append(crossV, crossH, crossDot);
    cross.style.display = "none";
    chartSvg.append(cross);

    const xs = candles.map((_, index) => xOf(index));
    const ys = candles.map((candle) => yOf(Number(candle.c)));
    chartState.geometry = { candles, xs, ys, cross, crossV, crossH, crossDot, width: box.width };
  }

  function hideChartHover() {
    const geometry = chartState.geometry;
    if (geometry && geometry.cross) {
      geometry.cross.style.display = "none";
    }
    if (chartTooltip) {
      chartTooltip.hidden = true;
      chartTooltip.classList.remove("is-left");
    }
  }

  function showChartHover(event) {
    const geometry = chartState.geometry;
    if (!geometry || !chartSvg || !chartStage) {
      return;
    }
    const rect = chartSvg.getBoundingClientRect();
    if (!rect.width || !rect.height) {
      return;
    }
    const ratio = (event.clientX - rect.left) / rect.width;
    const index = Math.max(
      0,
      Math.min(geometry.candles.length - 1, Math.round(ratio * (geometry.candles.length - 1))),
    );
    const candle = geometry.candles[index];
    const x = geometry.xs[index];
    const y = geometry.ys[index];

    geometry.cross.style.display = "";
    geometry.crossV.setAttribute("x1", String(x));
    geometry.crossV.setAttribute("x2", String(x));
    geometry.crossH.setAttribute("y1", String(y));
    geometry.crossH.setAttribute("y2", String(y));
    geometry.crossDot.setAttribute("cx", String(x));
    geometry.crossDot.setAttribute("cy", String(y));

    if (!chartTooltip) {
      return;
    }
    const stageRect = chartStage.getBoundingClientRect();
    const left = event.clientX - stageRect.left;
    const change = ((Number(candle.c) - Number(candle.o)) / Number(candle.o)) * 100;
    chartTooltip.replaceChildren();
    chartTooltip.append(el("strong", "chart-tooltip-time", formatChartFullTime(candle.t)));
    const grid = el("div", "chart-tooltip-grid");
    const rows = [
      ["Abertura", candle.o],
      ["Máxima", candle.h],
      ["Mínima", candle.l],
      ["Fechamento", candle.c],
    ];
    for (const [label, value] of rows) {
      grid.append(el("span", null, label), el("b", null, formatPrice(value)));
    }
    chartTooltip.append(
      grid,
      el("span", `chart-tooltip-change ${change >= 0 ? "is-up" : "is-down"}`, formatPercent(change)),
    );
    chartTooltip.hidden = false;
    chartTooltip.classList.remove("is-up", "is-down");
    chartTooltip.classList.add(change >= 0 ? "is-up" : "is-down");
    chartTooltip.style.left = `${left}px`;
    chartTooltip.style.top = `${event.clientY - stageRect.top}px`;
    chartTooltip.classList.toggle("is-left", left < 120);
  }

  async function loadChart(force) {
    if (!chartSvg || chartState.loading) {
      return;
    }
    if (chartState.data && !force) {
      return;
    }
    chartState.loading = true;
    if (chartRefreshButton) {
      chartRefreshButton.disabled = true;
    }
    if (chartSkeleton) {
      chartSkeleton.hidden = false;
    }
    chartSvg.classList.add("is-loading");
    if (chartStatus) {
      chartStatus.textContent = "Buscando candles reais…";
    }
    try {
      const url = `/api/chart?symbol=${encodeURIComponent(chartState.symbol)}&interval=${encodeURIComponent(chartState.interval)}`;
      const data = await fetchJson(url);
      chartState.data = data;
      renderChartHeader(data);
      renderChart(data);
      const last = data.candles[data.candles.length - 1];
      if (chartStatus) {
        chartStatus.textContent = `${data.candles.length} candles de ${data.intervalLabel} · última em ${formatChartFullTime(last.t)}`;
      }
      if (chartNote) {
        chartNote.textContent =
          "Preço: TradingView em tempo real. Série de candles: API pública do Yahoo Finance. Nenhum valor é estimado ou atrasado — se um dado falta, o gráfico avisa em vez de mostrar número velho.";
      }
      if (chartCard) {
        chartCard.classList.remove("is-fresh");
        void chartCard.offsetWidth;
        chartCard.classList.add("is-fresh");
      }
    } catch (error) {
      if (chartStatus) {
        chartStatus.textContent = error.message;
      }
    } finally {
      chartState.loading = false;
      if (chartRefreshButton) {
        chartRefreshButton.disabled = false;
      }
      if (chartSkeleton) {
        chartSkeleton.hidden = true;
      }
      chartSvg.classList.remove("is-loading");
    }
  }

  if (chartIntervals) {
    chartIntervals.addEventListener("click", (event) => {
      const button = event.target.closest("[data-chart-interval]");
      if (!button) {
        return;
      }
      chartState.interval = button.dataset.chartInterval;
      chartState.data = null;
      syncChartControls();
      loadChart(true);
    });
  }

  if (chartTypes) {
    chartTypes.addEventListener("click", (event) => {
      const button = event.target.closest("[data-chart-type]");
      if (!button || button.dataset.chartType === chartState.type) {
        return;
      }
      chartState.type = button.dataset.chartType;
      syncChartControls();
      if (chartState.data) {
        renderChart(chartState.data);
        if (chartCard) {
          chartCard.classList.remove("is-fresh");
          void chartCard.offsetWidth;
          chartCard.classList.add("is-fresh");
        }
      }
    });
  }

  if (chartEmaButton) {
    chartEmaButton.addEventListener("click", () => {
      chartState.ema = !chartState.ema;
      syncChartControls();
      if (chartState.data) {
        renderChart(chartState.data);
      }
    });
  }

  if (chartRefreshButton) {
    chartRefreshButton.addEventListener("click", () => loadChart(true));
  }

  if (chartSymbol) {
    chartSymbol.addEventListener("change", () => {
      chartState.symbol = chartSymbol.value;
      chartState.data = null;
      loadChart(true);
    });
  }

  if (chartSvg) {
    chartSvg.addEventListener("pointermove", showChartHover);
    chartSvg.addEventListener("pointerleave", hideChartHover);
  }

  syncChartControls();

})();

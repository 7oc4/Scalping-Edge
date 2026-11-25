import React, { useEffect, useId, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";

const TICKER_INTERVAL_MS = 2000;
const TOAST_DURATION_MS = 5000;
const TOAST_SOURCE_SELECTOR =
  "#upload-message, #feedback-status, #chart-status, #scanner-status, #backtest-status, #plan-status, #risk-status, #risk-history-status, #news-status, #history-status";

function marketQuotes(snapshot) {
  if (!snapshot || !Array.isArray(snapshot.groups)) {
    return [];
  }
  return snapshot.groups.flatMap((group) =>
    (Array.isArray(group.items) ? group.items : []).filter(
      (quote) =>
        quote.live === true &&
        Number(quote.delaySeconds) === 0 &&
        Number.isFinite(Number(quote.price)),
    ),
  );
}

function numberText(value, maximumFractionDigits = 6) {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return "—";
  }
  return new Intl.NumberFormat("pt-BR", {
    maximumFractionDigits,
  }).format(number);
}

function percentText(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return "—";
  }
  return `${number > 0 ? "+" : ""}${numberText(number, 2)}%`;
}

function MarketTicker() {
  const targetRef = useRef(null);
  const usesRadarTape = Boolean(document.getElementById("live-tape"));
  const [quotes, setQuotes] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const target = targetRef.current;
    const existingTape = document.getElementById("live-tape");
    if (target && existingTape) {
      existingTape.classList.add(
        "mb-0",
        "min-w-0",
        "flex-1",
        "border-white/10",
        "shadow-surface",
      );
      target.append(existingTape);
      return;
    }

    let active = true;
    let requestPending = false;
    let failures = 0;
    let timer = 0;
    async function refresh() {
      if (!active || document.hidden || requestPending) {
        return;
      }
      requestPending = true;
      try {
        const response = await fetch("/api/market", { cache: "no-store" });
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`);
        }
        const snapshot = await response.json();
        if (!active) {
          return;
        }
        failures = 0;
        setQuotes(marketQuotes(snapshot));
        setLoading(false);
      } catch (error) {
        failures += 1;
        console.error("Falha ao atualizar o ticker de mercado.", error);
        if (active) {
          setQuotes([]);
          setLoading(false);
        }
      } finally {
        requestPending = false;
        if (active && !document.hidden) {
          const delay = Math.min(
            16000,
            TICKER_INTERVAL_MS * 2 ** Math.max(0, failures - 1),
          );
          timer = window.setTimeout(refresh, delay);
        }
      }
    }

    function handleVisibilityChange() {
      window.clearTimeout(timer);
      if (!document.hidden) {
        refresh();
      }
    }

    document.addEventListener("visibilitychange", handleVisibilityChange);
    refresh();
    return () => {
      active = false;
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, []);

  const rootClass =
    "group relative min-w-0 flex-1 overflow-hidden rounded-xl border border-white/10 bg-glass shadow-surface [mask-image:linear-gradient(to_right,transparent,black_5%,black_95%,transparent)]";
  if (usesRadarTape) {
    return <div ref={targetRef} className={rootClass} aria-label="Cotações ao vivo" />;
  }

  const items = quotes.length ? quotes : null;
  return (
    <div
      className={`${rootClass} motion-reduce:overflow-x-auto motion-reduce:[mask-image:none]`}
      aria-label="Cotações ao vivo"
    >
      {items ? (
        <div className="flex w-max animate-marquee items-center py-2 will-change-transform hover:[animation-play-state:paused] motion-reduce:animate-none">
          {[false, true].map((duplicate) => (
            <div
              key={duplicate ? "copy" : "live"}
              className="flex items-center gap-3 px-3"
              aria-hidden={duplicate || undefined}
            >
              {items.map((quote) => {
                const change = Number(quote.changePercent);
                const changeClass = !Number.isFinite(change)
                  ? "text-zinc-400"
                  : change >= 0
                    ? "text-bull"
                    : "text-bear";
                return (
                  <span
                    className="inline-flex items-center gap-2 whitespace-nowrap rounded-full border border-white/10 bg-white/5 px-3 py-1.5 text-[11px] tabular-nums"
                    key={`${duplicate ? "copy-" : ""}${quote.symbol}`}
                  >
                    <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-bull" aria-hidden="true" />
                    <span className="font-semibold uppercase tracking-wide text-zinc-300">
                      {String(quote.label || quote.symbol).toUpperCase()}
                    </span>
                    <span className="font-medium text-zinc-100">{numberText(quote.price)}</span>
                    <span className={changeClass}>
                      {percentText(change)}
                    </span>
                  </span>
                );
              })}
            </div>
          ))}
        </div>
      ) : (
        <span className="block px-4 py-2 text-xs text-zinc-400">
          {loading ? "Carregando cotações…" : "Sem cotações agora."}
        </span>
      )}
    </div>
  );
}

function SplashLoader() {
  return (
    <svg className="h-12 w-36 overflow-visible" viewBox="0 0 144 48" fill="none" aria-hidden="true">
      <g className="text-brand" stroke="currentColor">
        <path d="M4 35h136M4 24h136M4 13h136" strokeOpacity=".12" />
        <path d="M20 30V17m-4 4h8m12 13V12m-4 8h8m12 12V18m-4 4h8m12 10V9m-4 9h8m12 17V15m-4 7h8m12 9V7m-4 8h8m12 18V12m-4 9h8" strokeOpacity=".55" />
        <path
          d="m5 31 16-8 12 3 12-10 12 7 12-12 12 8 12-9 12 8 12-13 12 8"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          strokeDasharray="180"
          className="drop-shadow-[0_0_6px_rgba(94,234,212,0.7)] animate-splash-draw motion-reduce:animate-splash-draw-reduced"
        />
        <circle cx="137" cy="13" r="3" fill="currentColor" className="animate-pulse" />
      </g>
    </svg>
  );
}

function Toast({ toast, onDismiss }) {
  const isError = toast.kind === "error";
  const isSuccess = toast.kind === "ok";
  const iconTone = isError
    ? "border-bear/40 bg-bear/10 text-bear"
    : isSuccess
      ? "border-bull/40 bg-bull/10 text-bull"
      : "border-brand/40 bg-brand/10 text-brand";

  return (
    <article
      className="pointer-events-auto relative overflow-hidden rounded-2xl border border-white/10 bg-[#0b1112]/95 p-4 text-base text-zinc-100 shadow-surface backdrop-blur-2xl animate-toast-in"
      role={isError ? "alert" : "status"}
    >
      <div className="flex items-center gap-3">
        <span className={`grid h-8 w-8 shrink-0 place-items-center rounded-full border ${iconTone}`} aria-hidden="true">
          {isError ? "!" : "✓"}
        </span>
        <p className="min-w-0 flex-1 font-medium">{toast.message}</p>
        <button
          className="rounded-full px-2 py-1 text-zinc-400 transition hover:bg-white/10 hover:text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/60"
          type="button"
          aria-label="Fechar notificação"
          onClick={() => onDismiss(toast.id)}
        >
          ×
        </button>
      </div>
      <span className="absolute inset-x-0 bottom-0 h-0.5 origin-left bg-brand animate-shrink" aria-hidden="true" />
    </article>
  );
}

function ToastStack() {
  const [toasts, setToasts] = useState([]);

  useEffect(() => {
    const sources = Array.from(document.querySelectorAll(TOAST_SOURCE_SELECTOR));
    const previous = new WeakMap();
    const timers = new Map();
    const observer = new MutationObserver((records) => {
      const changed = new Set(records.map((record) => record.target.nodeType === 1
        ? record.target
        : record.target.parentElement?.closest(TOAST_SOURCE_SELECTOR)));

      for (const source of changed) {
        if (!(source instanceof HTMLElement) || !source.matches(TOAST_SOURCE_SELECTOR)) {
          continue;
        }
        const message = source.textContent?.trim() || "";
        const kind = source.classList.contains("is-error")
          ? "error"
          : source.classList.contains("is-ok")
            ? "ok"
            : "info";
        const last = previous.get(source);
        if (!message || (last && last.message === message && last.kind === kind)) {
          continue;
        }
        previous.set(source, { message, kind });
        const toast = { id: `${Date.now()}-${Math.random()}`, message, kind };
        setToasts((current) => [...current.slice(-3), toast]);
        const timer = window.setTimeout(() => {
          setToasts((current) => current.filter((item) => item.id !== toast.id));
          timers.delete(toast.id);
        }, TOAST_DURATION_MS);
        timers.set(toast.id, timer);
      }
    });

    sources.forEach((source) => {
      source.classList.add("sr-only");
      source.setAttribute("aria-live", "off");
      previous.set(source, { message: source.textContent?.trim() || "", kind: "" });
      observer.observe(source, {
        attributes: true,
        attributeFilter: ["class"],
        childList: true,
        characterData: true,
        subtree: true,
      });
    });
    return () => {
      observer.disconnect();
      timers.forEach((timer) => window.clearTimeout(timer));
    };
  }, []);

  function dismiss(id) {
    setToasts((current) => current.filter((toast) => toast.id !== id));
  }

  return (
    <div className="pointer-events-none fixed bottom-5 right-5 z-[100] flex w-[min(26rem,calc(100vw-2rem))] flex-col gap-3 max-sm:inset-x-4 max-sm:bottom-auto max-sm:right-auto max-sm:top-4 max-sm:w-auto">
      {toasts.map((toast) => (
        <Toast key={toast.id} toast={toast} onDismiss={dismiss} />
      ))}
    </div>
  );
}

function PriceSparkChart({ series, positive }) {
  const id = useId().replace(/:/g, "");
  const values = Array.isArray(series)
    ? series.map(Number).filter(Number.isFinite)
    : [];
  if (values.length < 2) {
    return <div className="h-14 w-32 rounded-lg bg-white/[0.02]" aria-hidden="true" />;
  }

  let minimum = Math.min(...values);
  let maximum = Math.max(...values);
  const points = values.map((value, index) => {
    const x = (index / (values.length - 1)) * 184 + 4;
    const y =
      maximum === minimum
        ? 26
        : 44 - ((value - minimum) / (maximum - minimum)) * 36;
    return { x, y, value };
  });
  const linePath = points.map((point, index) => `${index ? "L" : "M"}${point.x},${point.y}`).join(" ");
  const areaPath = `${linePath} L188,52 L4,52 Z`;
  const tone = positive ? "text-bull" : "text-bear";
  const glow = positive
    ? "drop-shadow-[0_0_6px_rgba(94,234,212,0.6)]"
    : "drop-shadow-[0_0_6px_rgba(248,113,113,0.6)]";
  const fill = positive ? "#4ade80" : "#f87171";

  return (
    <div className="relative flex h-14 min-w-0 items-center gap-1" aria-label="Série histórica do ativo">
      <svg className={`h-14 min-w-0 flex-1 ${tone} ${glow}`} viewBox="0 0 192 56" preserveAspectRatio="none" role="img">
        <defs>
          <linearGradient id={`spark-fill-${id}`} x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor={fill} stopOpacity=".32" />
            <stop offset="100%" stopColor={fill} stopOpacity="0" />
          </linearGradient>
        </defs>
        {[14, 28, 42].map((y) => (
          <path key={y} d={`M0 ${y}H192`} stroke="currentColor" strokeOpacity=".13" strokeWidth=".6" />
        ))}
        <path d={areaPath} fill={`url(#spark-fill-${id})`} />
        <path d={linePath} fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        {points.map((point, index) => (
          <circle key={index} cx={point.x} cy={point.y} r="4" fill="transparent">
            <title>{`Preço da série: ${numberText(point.value)}`}</title>
          </circle>
        ))}
        <circle cx={points[points.length - 1].x} cy={points[points.length - 1].y} r="2" fill="currentColor" />
        <circle cx={points[points.length - 1].x} cy={points[points.length - 1].y} r="4" fill="currentColor" className="animate-ping" />
      </svg>
      <span className="flex h-12 w-9 flex-col justify-between text-right text-[9px] tabular-nums text-zinc-500" aria-hidden="true">
        <span>{numberText(maximum, 4)}</span>
        <span>{numberText(minimum, 4)}</span>
      </span>
      <span className="pointer-events-none absolute bottom-0 left-0 rounded bg-[#05080a]/80 px-1 text-[8px] leading-3 text-zinc-500">
        BOT
      </span>
    </div>
  );
}

const sparkRoots = new Map();

function unmountSparkCharts(container) {
  for (const [element, root] of sparkRoots) {
    if (element === container || container.contains(element)) {
      root.unmount();
      sparkRoots.delete(element);
    }
  }
}

function GlowCard() {
  useEffect(() => {
    const container = document.getElementById("scanner-summary");
    if (!container) {
      return undefined;
    }

    const cleanupByCard = new Map();
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const noHover = window.matchMedia("(hover: none)");

    function enhance() {
      container.querySelectorAll(".scanner-stat").forEach((card) => {
        if (cleanupByCard.has(card)) {
          return;
        }
        card.classList.add(
          "relative",
          "isolate",
          "bg-white/5",
          "backdrop-blur-2xl",
          "backdrop-saturate-150",
          "border",
          "border-white/10",
          "shadow-surface",
          "[background-image:radial-gradient(circle_at_var(--mx,50%)_var(--my,50%),rgba(94,234,212,0.16),transparent_45%)]",
          "[@media(hover:none)]:[background-image:none]",
          "motion-reduce:[background-image:none]",
        );
        let frame = 0;
        let pending = null;
        const move = (event) => {
          if (reducedMotion.matches || noHover.matches) {
            return;
          }
          pending = event;
          if (frame) {
            return;
          }
          frame = window.requestAnimationFrame(() => {
            frame = 0;
            if (!pending) {
              return;
            }
            const rect = card.getBoundingClientRect();
            const x = ((pending.clientX - rect.left) / rect.width) * 100;
            const y = ((pending.clientY - rect.top) / rect.height) * 100;
            card.style.setProperty("--mx", `${x}%`);
            card.style.setProperty("--my", `${y}%`);
            pending = null;
          });
        };
        card.addEventListener("pointermove", move, { passive: true });
        cleanupByCard.set(card, () => {
          card.removeEventListener("pointermove", move);
          if (frame) {
            window.cancelAnimationFrame(frame);
          }
          card.style.removeProperty("--mx");
          card.style.removeProperty("--my");
        });
      });
    }

    const observer = new MutationObserver(enhance);
    observer.observe(container, { childList: true, subtree: true });
    enhance();
    return () => {
      observer.disconnect();
      cleanupByCard.forEach((cleanup) => cleanup());
      cleanupByCard.clear();
    };
  }, []);

  return null;
}

const api = {
  mountPriceSparkChart(container, series, positive) {
    let root = sparkRoots.get(container);
    if (!root) {
      root = createRoot(container);
      sparkRoots.set(container, root);
    }
    root.render(<PriceSparkChart series={series} positive={positive} />);
  },
  unmountPriceSparkCharts: unmountSparkCharts,
};

window.ScalpingReact = api;
window.dispatchEvent(new Event("scalping:react-ready"));

const tickerRoot = document.getElementById("market-ticker-root");
if (tickerRoot) {
  createRoot(tickerRoot).render(<MarketTicker />);
}

const toastRoot = document.getElementById("react-toast-root");
if (toastRoot) {
  createRoot(toastRoot).render(<ToastStack />);
}

const splashRoot = document.getElementById("splash-loader-root");
if (splashRoot) {
  createRoot(splashRoot).render(<SplashLoader />);
}

if (document.getElementById("scanner-summary")) {
  const glowRoot = document.createElement("div");
  glowRoot.id = "react-glow-root";
  document.body.append(glowRoot);
  createRoot(glowRoot).render(<GlowCard />);
}

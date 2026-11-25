// Efeitos interativos do radar — SOMENTE no Brave.
// ---------------------------------------------------------------------
// O gate é real: navigator.brave.isBrave() precisa confirmar o navegador.
// ?fx=on / ?fx=off existem apenas para testar o efeito em outro navegador
// e para desligar sem mexer no código; nada é ativado por user-agent.
// Com prefers-reduced-motion ligado, o módulo não inicia.
(() => {
  "use strict";

  const params = new URLSearchParams(window.location.search);
  const override = params.get("fx");
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  const TAU = Math.PI * 2;

  async function isBrave() {
    if (override === "on") {
      return true;
    }
    if (override === "off") {
      return false;
    }
    try {
      return Boolean(navigator.brave && (await navigator.brave.isBrave()));
    } catch {
      return false;
    }
  }

  function boot() {
    if (document.querySelector(".znx-fx-canvas")) {
      return;
    }
    document.body.classList.add("znx-fx-on");

    const canvas = document.createElement("canvas");
    canvas.className = "znx-fx-canvas";
    canvas.setAttribute("aria-hidden", "true");
    document.body.prepend(canvas);
    const ctx = canvas.getContext("2d", { alpha: true });
    if (!ctx) {
      return;
    }

    const state = {
      w: 0,
      h: 0,
      dpr: 1,
      pointer: { x: -999, y: -999, active: false },
      particles: [],
      pulses: [],
      scroll: 0,
      lastScroll: window.scrollY,
      raf: 0,
      tiltNode: null,
    };

    function spawn() {
      const angle = Math.random() * TAU;
      const speed = 0.1 + Math.random() * 0.5;
      return {
        x: Math.random() * state.w,
        y: Math.random() * state.h,
        vx: Math.cos(angle) * speed,
        vy: Math.sin(angle) * speed,
        r: 0.7 + Math.random() * 1.7,
        amber: Math.random() < 0.16,
      };
    }

    function resize() {
      state.dpr = Math.min(window.devicePixelRatio || 1, 1.75);
      state.w = window.innerWidth;
      state.h = window.innerHeight;
      canvas.width = Math.round(state.w * state.dpr);
      canvas.height = Math.round(state.h * state.dpr);
      canvas.style.width = `${state.w}px`;
      canvas.style.height = `${state.h}px`;
      ctx.setTransform(state.dpr, 0, 0, state.dpr, 0, 0);
      // Densidade proporcional à tela, com teto: fica pesado no desktop e
      // continua utilizável em tela pequena.
      const target = Math.max(70, Math.min(130, Math.round((state.w * state.h) / 16000)));
      while (state.particles.length < target) {
        state.particles.push(spawn());
      }
      state.particles.length = target;
      ctx.fillStyle = "#080b0f";
      ctx.fillRect(0, 0, state.w, state.h);
    }

    function burst(x, y, rings, color) {
      for (let i = 0; i < rings; i += 1) {
        state.pulses.push({
          x,
          y,
          r: 6 + i * 12,
          life: 1 - i * 0.14,
          color: color || "74,222,128",
          width: Math.max(0.8, 2.2 - i * 0.4),
        });
      }
      for (const particle of state.particles) {
        const dx = particle.x - x;
        const dy = particle.y - y;
        const distance = Math.hypot(dx, dy) || 1;
        if (distance < 240) {
          const force = (1 - distance / 240) * 7;
          particle.vx += (dx / distance) * force;
          particle.vy += (dy / distance) * force;
        }
      }
    }

    function step() {
      state.raf = window.requestAnimationFrame(step);
      if (document.hidden) {
        return;
      }
      const { w, h, pointer, particles } = state;

      // Rastro em vez de limpeza total: dá a sensação de fluxo contínuo.
      ctx.fillStyle = "rgba(8, 11, 15, 0.45)";
      ctx.fillRect(0, 0, w, h);

      const pull = 240;
      for (const particle of particles) {
        if (pointer.active) {
          const dx = particle.x - pointer.x;
          const dy = particle.y - pointer.y;
          const distance = Math.hypot(dx, dy) || 1;
          if (distance < pull) {
            // Vórtice: empurra na tangente e repele de muito perto.
            const force = (1 - distance / pull) * 0.45;
            particle.vx += (-dy / distance) * force;
            particle.vy += (dx / distance) * force;
            if (distance < 55) {
              particle.vx += (dx / distance) * force * 2.6;
              particle.vy += (dy / distance) * force * 2.6;
            }
          }
        }

        particle.vx *= 0.985;
        particle.vy *= 0.985;
        particle.vy -= state.scroll * 0.0015;

        const speed = Math.hypot(particle.vx, particle.vy);
        if (speed > 3.4) {
          particle.vx *= 3.4 / speed;
          particle.vy *= 3.4 / speed;
        }

        particle.x += particle.vx;
        particle.y += particle.vy;

        if (particle.x < -30) particle.x = w + 30;
        if (particle.x > w + 30) particle.x = -30;
        if (particle.y < -30) particle.y = h + 30;
        if (particle.y > h + 30) particle.y = -30;
      }

      state.scroll *= 0.9;

      // Ligações entre partículas próximas; o cursor ilumina a malha.
      for (let i = 0; i < particles.length; i += 1) {
        const a = particles[i];
        for (let j = i + 1; j < particles.length; j += 1) {
          const b = particles[j];
          const dx = a.x - b.x;
          const dy = a.y - b.y;
          const d2 = dx * dx + dy * dy;
          if (d2 > 14400) {
            continue;
          }
          const distance = Math.sqrt(d2);
          let alpha = (1 - distance / 120) * 0.1;
          if (pointer.active) {
            const pd = Math.hypot((a.x + b.x) / 2 - pointer.x, (a.y + b.y) / 2 - pointer.y);
            if (pd < 200) {
              alpha += (1 - pd / 200) * 0.14;
            }
          }
          ctx.strokeStyle = `rgba(74, 222, 128, ${alpha.toFixed(3)})`;
          ctx.lineWidth = 0.6;
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.lineTo(b.x, b.y);
          ctx.stroke();
        }
      }

      for (const particle of particles) {
        ctx.beginPath();
        ctx.fillStyle = particle.amber
          ? "rgba(251, 191, 36, 0.85)"
          : "rgba(74, 222, 128, 0.8)";
        ctx.arc(particle.x, particle.y, particle.r, 0, TAU);
        ctx.fill();
      }

      for (let index = state.pulses.length - 1; index >= 0; index -= 1) {
        const pulse = state.pulses[index];
        pulse.r += 3.6;
        pulse.life -= 0.014;
        if (pulse.life <= 0) {
          state.pulses.splice(index, 1);
          continue;
        }
        ctx.strokeStyle = `rgba(${pulse.color}, ${(pulse.life * 0.55).toFixed(3)})`;
        ctx.lineWidth = pulse.width;
        ctx.beginPath();
        ctx.arc(pulse.x, pulse.y, pulse.r, 0, TAU);
        ctx.stroke();
      }

      if (pointer.active) {
        const spin = performance.now() / 900;
        ctx.save();
        ctx.translate(pointer.x, pointer.y);
        ctx.rotate(spin);
        ctx.strokeStyle = "rgba(74, 222, 128, 0.55)";
        ctx.lineWidth = 1;
        ctx.setLineDash([5, 7]);
        ctx.beginPath();
        ctx.arc(0, 0, 26, 0, TAU);
        ctx.stroke();
        ctx.setLineDash([]);
        ctx.strokeStyle = "rgba(251, 191, 36, 0.5)";
        for (let tick = 0; tick < 4; tick += 1) {
          const angle = (tick / 4) * TAU;
          ctx.beginPath();
          ctx.moveTo(Math.cos(angle) * 30, Math.sin(angle) * 30);
          ctx.lineTo(Math.cos(angle) * 38, Math.sin(angle) * 38);
          ctx.stroke();
        }
        ctx.restore();
      }
    }

    function tiltAt(event) {
      const target = event.target instanceof Element ? event.target.closest(".market-row") : null;
      if (target !== state.tiltNode) {
        if (state.tiltNode) {
          state.tiltNode.classList.remove("fx-tilt");
          state.tiltNode.style.transform = "";
        }
        state.tiltNode = target;
      }
      if (!target) {
        return;
      }
      const rect = target.getBoundingClientRect();
      const px = (event.clientX - rect.left) / Math.max(1, rect.width) - 0.5;
      const py = (event.clientY - rect.top) / Math.max(1, rect.height) - 0.5;
      target.classList.add("fx-tilt");
      target.style.transform = `perspective(700px) rotateY(${(px * 5).toFixed(2)}deg) rotateX(${(-py * 5).toFixed(2)}deg) translateZ(3px)`;
    }

    window.addEventListener(
      "pointermove",
      (event) => {
        state.pointer.x = event.clientX;
        state.pointer.y = event.clientY;
        state.pointer.active = true;
        tiltAt(event);
      },
      { passive: true },
    );

    window.addEventListener("pointerleave", () => {
      state.pointer.active = false;
    });

    window.addEventListener(
      "pointerdown",
      (event) => {
        burst(event.clientX, event.clientY, 3, "74,222,128");
      },
      { passive: true },
    );

    window.addEventListener(
      "scroll",
      () => {
        const current = window.scrollY;
        state.scroll = current - state.lastScroll;
        state.lastScroll = current;
      },
      { passive: true },
    );

    // Cada tique real de preço do radar vira um pulso na cor da direção.
    window.addEventListener("znx:market-tick", (event) => {
      const up = Boolean(event.detail && event.detail.up);
      if (state.pulses.length > 20) {
        state.pulses.shift();
      }
      state.pulses.push({
        x: 40 + Math.random() * Math.max(1, state.w - 80),
        y: state.h * (0.22 + Math.random() * 0.56),
        r: 4,
        life: 1,
        color: up ? "74,222,128" : "248,113,113",
        width: 1.6,
      });
    });

    window.addEventListener("resize", resize, { passive: true });

    resize();
    step();
  }

  isBrave().then((brave) => {
    // prefers-reduced-motion continua valendo; ?fx=on e intencao explicita do
    // usuario e por isso pode sobrepor a preferencia do sistema.
    if (!brave || (reduce.matches && override !== "on")) {
      return;
    }
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", boot, { once: true });
    } else {
      boot();
    }
  });
})();

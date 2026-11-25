/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./pages/**/*.html", "./assets/react/**/*.{js,jsx}", "./assets/js/radar.js"],
  corePlugins: {
    preflight: false,
  },
  theme: {
    extend: {
      colors: {
        brand: "#5EEAD4",
        bull: "#4ade80",
        bear: "#f87171",
        glass: "rgb(255 255 255 / 5%)",
      },
      boxShadow: {
        surface: "0 8px 32px rgb(0 0 0 / 35%), inset 0 1px 0 rgb(255 255 255 / 7%)",
        glow: "0 0 24px rgb(94 234 212 / 18%)",
      },
      keyframes: {
        marquee: {
          from: { transform: "translateX(0)" },
          to: { transform: "translateX(-50%)" },
        },
        shrink: {
          from: { transform: "scaleX(1)" },
          to: { transform: "scaleX(0)" },
        },
        "splash-draw": {
          from: { strokeDashoffset: "180" },
          to: { strokeDashoffset: "0" },
        },
        "toast-in": {
          from: { opacity: "0", transform: "translateY(0.75rem)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
      },
      animation: {
        marquee: "marquee 48s linear infinite",
        shrink: "shrink 5s linear forwards",
        "splash-draw": "splash-draw 1.8s ease-out infinite alternate",
        "splash-draw-reduced": "splash-draw 1s ease-out forwards",
        "toast-in": "toast-in 240ms ease-out both",
      },
      fontFamily: {
        sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"],
      },
    },
  },
  plugins: [],
};

import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "assets/build",
    emptyOutDir: true,
    cssCodeSplit: false,
    sourcemap: false,
    rollupOptions: {
      input: "assets/react/main.jsx",
      output: {
        entryFileNames: "react-islands.js",
        chunkFileNames: "chunks/[name].js",
        assetFileNames: "react-islands.[ext]",
      },
    },
  },
});

import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// The Swift WKWebView loads this dev server (or the built dist via file://).
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  server: {
    port: 5173,
    strictPort: true,
    // The model manifest lives with the Swift resources (single source of
    // truth) — allow the dev server to read outside web/.
    fs: { allow: [fileURLToPath(new URL("..", import.meta.url))] },
  },
  // Relative base so the production build also works when loaded from file://.
  base: "./",
});

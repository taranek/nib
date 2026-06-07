import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The Swift WKWebView loads this dev server (or the built dist via file://).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
  },
  // Relative base so the production build also works when loaded from file://.
  base: "./",
});

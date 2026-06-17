import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { Settings } from "./Settings";
import "./styles.css";

// One bundle, two surfaces: the per-word card (default) and the settings
// window (loaded with #settings by the Swift host).
const isSettings = window.location.hash.replace(/^#/, "") === "settings";

createRoot(document.getElementById("root")!).render(
  <StrictMode>{isSettings ? <Settings /> : <App />}</StrictMode>,
);

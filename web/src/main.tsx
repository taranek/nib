import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MotionConfig } from "motion/react";
import { App } from "./App";
import { Settings } from "./Settings";
import "./styles.css";

// One bundle, two surfaces: the per-word card (default) and the settings
// window. The Swift host marks settings via an injected `__locoSettings` flag
// (a file:// URL fragment is unreliable with loadFileURL); #settings still works
// for plain-browser dev.
const isSettings =
  (window as unknown as { __locoSettings?: boolean }).__locoSettings === true ||
  window.location.hash.replace(/^#/, "") === "settings";

// reducedMotion="user" makes Motion drop transforms/height animation (keeping
// opacity) when the OS "Reduce motion" setting is on.
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <MotionConfig reducedMotion="user">
      {isSettings ? <Settings /> : <App />}
    </MotionConfig>
  </StrictMode>,
);

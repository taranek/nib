import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MotionConfig } from "motion/react";
import { App } from "./App";
import { Settings } from "./Settings";
import "./styles.css";

// One bundle, two surfaces: the per-word card (default) and the settings
// window (loaded with #settings by the Swift host).
const isSettings = window.location.hash.replace(/^#/, "") === "settings";

// reducedMotion="user" makes Motion drop transforms/height animation (keeping
// opacity) when the OS "Reduce motion" setting is on.
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <MotionConfig reducedMotion="user">
      {isSettings ? <Settings /> : <App />}
    </MotionConfig>
  </StrictMode>,
);

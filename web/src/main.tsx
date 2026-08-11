import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MotionConfig } from "motion/react";
import { App } from "./App";
import { Settings } from "./Settings";
import { Pill } from "./Pill";
import "./styles.css";

// One bundle, three surfaces: the per-word card (default), the settings
// window, and the selection pill. The Swift host marks non-default surfaces
// via injected flags (a file:// URL fragment is unreliable with loadFileURL);
// #settings / #pill still work for plain-browser dev.
const flags = window as unknown as {
  __locoSettings?: boolean;
  __locoPill?: boolean;
};
const hash = window.location.hash.replace(/^#/, "");
const isSettings = flags.__locoSettings === true || hash === "settings";
const isPill = flags.__locoPill === true || hash === "pill";


// reducedMotion="user" makes Motion drop transforms/height animation (keeping
// opacity) when the OS "Reduce motion" setting is on.
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <MotionConfig reducedMotion="user">
      {isPill ? <Pill /> : isSettings ? <Settings /> : <App />}
    </MotionConfig>
  </StrictMode>,
);

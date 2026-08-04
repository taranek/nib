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
  __locoLinter?: boolean;
};
const hash = window.location.hash.replace(/^#/, "");
const isSettings = flags.__locoSettings === true || hash === "settings";
const isPill = flags.__locoPill === true || hash === "pill";
const isLinter = flags.__locoLinter === true || hash === "linter";

// The linter surface is headless — no React; the module wires window.loco.lint.
if (isLinter) {
  void import("./linter");
}

// reducedMotion="user" makes Motion drop transforms/height animation (keeping
// opacity) when the OS "Reduce motion" setting is on.
if (!isLinter) {
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <MotionConfig reducedMotion="user">
        {isPill ? <Pill /> : isSettings ? <Settings /> : <App />}
      </MotionConfig>
    </StrictMode>,
  );
}

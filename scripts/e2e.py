#!/usr/bin/env python3
"""Drive loco's real user flow through the dev e2e driver (LOCO_E2E_PORT).

Launch the dev build with LOCO_E2E_PORT=7788, then:

    scripts/e2e.py state
    scripts/e2e.py flow --out /tmp/e2e [--dm 'Name (DM)']
        # Slack self-DM: type → squiggles → select → hover pill → card → accept
        # → shortcut → Tab → keep typing; the draft is cleared, never sent.

Screenshots come from the overlay webview's own snapshot (no Screen Recording
grant needed); `shot` captures the real screen when loco has that grant.
"""
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

PORT = int(os.environ.get("LOCO_E2E_PORT", "7788"))


def call(route, **params):
    q = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None}, quote_via=urllib.parse.quote)
    url = f"http://127.0.0.1:{PORT}/{route}" + (f"?{q}" if q else "")
    with urllib.request.urlopen(url, timeout=30) as r:
        body = r.read().decode()
    try:
        return json.loads(body)
    except ValueError:
        return body.strip()


def state():
    return call("state")


def wait_for(pred, timeout=10.0, every=0.2, what="condition"):
    end = time.time() + timeout
    while time.time() < end:
        st = state()
        if pred(st):
            return st
        time.sleep(every)
    raise TimeoutError(f"timed out waiting for {what}: {json.dumps(state())[:600]}")


def move(x, y, steps=12):
    call("move", x=x, y=y, steps=steps)


def click(x, y, count=1):
    call("click", x=x, y=y, count=count)


def type_text(text):
    call("type", text=text)


# kVK codes
KEY = {"a": 0, "tab": 48, "esc": 53, "grave": 50, "delete": 51, "return": 36,
       "left": 123, "right": 124, "down": 125, "up": 126}


def key(name, mods=""):
    call("key", code=KEY[name], mods=mods)


def snap(path, crop=None):
    """Overlay webview snapshot; crop=(x, y, w, h) in points (2x backing)."""
    call("snap", path=path)
    if crop:
        x, y, w, h = (int(v) for v in crop)
        subprocess.run(["sips", "-s", "format", "png", "--cropOffset", str(y * 2), str(x * 2),
                        "-c", str(h * 2), str(w * 2), path, "--out", path],
                       check=True, capture_output=True)
    return path


def shot(path, rect=None):
    """Real screen capture (needs Screen Recording for loco); rect=(x, y, w, h)."""
    params = {"path": path}
    if rect:
        params.update(dict(zip("xywh", (int(v) for v in rect))))
    return call("shot", **params)


def around(st, pad=40):
    """Crop box covering the pill and card with padding."""
    rects = [st[k] for k in ("pill", "card") if st.get(k)]
    if not rects:
        return None
    x0 = min(r["x"] for r in rects) - pad
    y0 = min(r["y"] for r in rects) - pad
    x1 = max(r["x"] + r["w"] for r in rects) + pad
    y1 = max(r["y"] + r["h"] for r in rects) + pad
    return (max(0, x0), max(0, y0), x1 - max(0, x0), y1 - max(0, y0))


def slack_window():
    out = subprocess.run(["osascript", "-e",
                          'tell application "System Events" to tell process "Slack" '
                          'to get {name, position, size} of window 1'],
                         capture_output=True, text=True, check=True).stdout.strip()
    name, rest = out.split(", ", 1)
    x, y, w, h = (int(v) for v in rest.replace(" ", "").split(","))
    return name, (x, y, w, h)


def accept_button():
    """Accept button centre, from the overlay DOM (webview space == CG space)."""
    js = ("JSON.stringify([...document.querySelectorAll('button')]"
          ".filter(b=>/Accept/.test(b.textContent)&&!b.disabled)"
          ".map(b=>{const r=b.getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]}))")
    pts = json.loads(call("js", code=js)["result"] or "[]")
    return pts[0] if pts else None


def flow(out_dir, dm_prefix, sentence="Did you recieve my last message? We definately need to talk."):
    """Full user flow in Slack, in the user's self-DM only. Never presses Return."""
    os.makedirs(out_dir, exist_ok=True)
    steps = []

    def step(name, ok, **info):
        steps.append({"step": name, "ok": ok, **info})
        print(("PASS " if ok else "FAIL ") + name, json.dumps(info)[:300])
        return ok

    subprocess.run(["open", "-a", "Slack"], check=True)
    wait_for(lambda s: s.get("frontApp") == "Slack", 5, what="Slack front")
    time.sleep(0.8)
    name, (x, y, w, h) = slack_window()
    if not name.startswith(dm_prefix):
        step("self-DM open", False, window=name)
        return steps

    # 0. focus the composer (bottom of the window) and start from an empty draft
    click(x + w // 2, y + h - 75)
    try:
        st = wait_for(lambda s: s.get("field") and s["field"]["y"] > y + h / 2, 3, what="composer focus")
    except TimeoutError:
        step("composer focused", False)
        return steps
    field = st["field"]
    key("a", "cmd"); key("delete")
    time.sleep(0.3)

    try:
        # 1. type → squiggles
        type_text(sentence)
        try:
            st = wait_for(lambda s: len(s.get("flagged", [])) >= 2, 8, what="squiggles")
            step("squiggles drawn", True, flagged=[f["original"] for f in st["flagged"]])
            field = st.get("field") or field   # the composer resizes with its text
        except TimeoutError as e:
            step("squiggles drawn", False, text=state().get("text"))
            return steps
        # Squiggles sit inside the field, on the text line.
        shot(os.path.join(out_dir, "01-squiggles.png"),
             (field["x"] - 40, field["y"] - 60, field["w"] + 80, field["h"] + 100))
        f0 = st["flagged"][0]["rect"]
        step("squiggle inside field", field["x"] <= f0["x"] and f0["y"] + f0["h"] <= field["y"] + field["h"],
             rect=f0, field=field)

        # 2. double-click the first flagged word → pill on selection
        click(f0["cx"], f0["cy"], count=2)
        try:
            st = wait_for(lambda s: s.get("pill") and s.get("pillOnSelection"), 4, what="pill")
        except TimeoutError:
            step("pill on selection", False, sel=state().get("rephraseText"))
            return steps
        pill = st["pill"]
        step("pill on selection", True, pill=pill, selection=st.get("rephraseText"))
        step("pill level with the text line", abs(pill["cy"] - f0["cy"]) <= 6, pill_cy=pill["cy"], text_cy=f0["cy"])

        # 3. hover the pill → card opens without taking the keyboard
        move(pill["cx"], pill["cy"])
        try:
            st = wait_for(lambda s: s.get("popoverMode") == "rephrase" and s.get("card"), 4, what="card")
        except TimeoutError:
            step("hover opens card", False)
            return steps
        step("hover opens card", True, card=st["card"])
        step("hover card leaves keyboard with Slack", not st["morphKey"])
        card = st["card"]
        step("card on screen, not over the composer text",
             card["y"] >= 0 and (card["y"] + card["h"] <= field["y"] + 1 or card["y"] >= field["y"] + field["h"] - 1),
             card=card, field=field)
        time.sleep(0.3)
        snap(os.path.join(out_dir, "03-card-open.png"), around(st, 60))

        # 4. result arrives (model may cold-start)
        try:
            wait_for(lambda s: accept_button_ready(), 45, 0.5, what="card result")
            step("card result ready", True)
        except TimeoutError:
            step("card result ready", False)
        st = state()
        snap(os.path.join(out_dir, "04-card-result.png"), around(st, 60))

        # 5. one click on Accept writes back (no first-click swallow)
        btn = accept_button()
        if btn:
            move(*btn)
            click(*btn)
            try:
                st = wait_for(lambda s: "recieve" not in s.get("text", "recieve"), 5, what="write-back")
                step("single click Accept writes back", True, text=st["text"])
            except TimeoutError:
                step("single click Accept writes back", False, text=state().get("text"))
        else:
            step("single click Accept writes back", False, error="no Accept button")
        try:
            wait_for(lambda s: s.get("popoverMode") == "none", 3, what="card close")
            step("card closes after accept", True)
        except TimeoutError:
            step("card closes after accept", False)

        # 6. shortcut on the remaining error opens the card with key; Tab accepts
        st = state()
        if st.get("flagged"):
            f1 = st["flagged"][0]["rect"]
            click(f1["cx"], f1["cy"], count=2)
            time.sleep(0.8)
            key("grave", "cmd")
            try:
                st = wait_for(lambda s: s.get("popoverMode") == "rephrase" and s.get("card"), 4, what="shortcut card")
                step("shortcut opens card with key", st["morphKey"], pill=st.get("pill"))
                wait_for(lambda s: accept_button_ready(), 45, 0.5, what="card result")
                time.sleep(0.6)   # let the open animation finish before the snapshot
                snap(os.path.join(out_dir, "06-shortcut-card.png"), around(state(), 60))
                key("tab")
                st = wait_for(lambda s: "definately" not in s.get("text", "definately"), 5, what="tab write-back")
                step("Tab accepts", True, text=st["text"])
            except TimeoutError as e:
                snap(os.path.join(out_dir, "06-FAIL.png"), around(state(), 60))
                print(call("js", code="JSON.stringify([...document.querySelectorAll('button')].map(b=>[b.textContent.trim().slice(0,20),b.disabled]))"))
                step("shortcut → Tab accept", False, error=str(e)[:200])

        # 7. typing continues in Slack after the card closes — at the caret,
        # which sits right after the replaced word.
        time.sleep(0.6)
        type_text(" ok")
        time.sleep(0.8)
        after = state().get("text", "")
        step("typing continues after card", "definitely ok" in after, text=after)
    finally:
        # Leave no draft behind (never sent — Return is never pressed). Close
        # any card first: while it holds the keyboard, keys would go to it.
        if state().get("popoverMode") != "none":
            key("esc")
            time.sleep(0.8)
        for _ in range(3):
            click(field["cx"], field["cy"])
            time.sleep(0.4)
            key("a", "cmd")
            time.sleep(0.3)
            key("delete")
            time.sleep(0.8)
            if not state().get("text", "").strip():
                break
        print("draft cleared" if not state().get("text", "").strip() else "WARNING: draft not cleared")
        json.dump(steps, open(os.path.join(out_dir, "steps.json"), "w"), indent=1)
    return steps


def accept_button_ready():
    return accept_button() is not None


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "state"
    if cmd == "state":
        print(json.dumps(state(), indent=1))
    elif cmd == "flow":
        out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "/tmp/loco-e2e"
        dm = sys.argv[sys.argv.index("--dm") + 1] if "--dm" in sys.argv else "Tomasz Taranek (DM)"
        res = flow(out, dm)
        sys.exit(0 if all(s["ok"] for s in res) else 1)
    else:
        print(call(cmd, **dict(a.split("=", 1) for a in sys.argv[2:])))

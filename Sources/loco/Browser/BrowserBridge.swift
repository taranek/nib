import Foundation

// MARK: - Browser bridge (locate phrases + write-back in the real page)
//
// Contenteditable surfaces (Gmail, docs, chat boxes) expose text via AX but no
// per-range geometry — so once the LLM tells us which substrings are wrong, we
// run JS in the real page to find each phrase's DOM rect, and to apply fixes.
// Phrases are passed base64-encoded so arbitrary LLM text can't break the
// AppleScript/JS quoting. Requires the browser's "Allow JavaScript from Apple
// Events" (View → Developer) and Automation permission. No extension needed.

/// A located phrase as the page reports it: which phrase (index into the request
/// list), which occurrence, and a rect relative to the focused element's box.
struct RawLocate {
    let phraseIndex: Int
    let occurrence: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

final class BrowserBridge {
    static let appNames: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.brave.Browser": "Brave Browser",
        "com.brave.Browser.beta": "Brave Browser Beta",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    private var warned = false

    /// The plain text of the focused contenteditable, taken from the DOM so it
    /// matches what `locate` searches. Returns nil when focus isn't editable.
    func focusedText(appName: String) -> String? {
        let js = "(function(){try{var el=document.activeElement;if(!el||!el.isContentEditable){return '';}return el.textContent||'';}catch(x){return '';}})()"
        guard let text = run(appName, js), !text.isEmpty else { return nil }
        return text
    }

    /// Locate each phrase's occurrences in the focused contenteditable and return
    /// their rects. Returns nil when JS is unavailable / the focus isn't editable.
    func locate(appName: String, phrases: [String]) -> [RawLocate]? {
        guard !phrases.isEmpty else { return [] }
        let b64 = base64(["phrases": phrases])
        let js = "(function(b64){try{var a=JSON.parse(decodeURIComponent(escape(atob(b64))));var el=document.activeElement;if(!el||!el.isContentEditable){return '';}function w(c){return c>='A'&&c<='Z'||c>='a'&&c<='z'||c>='0'&&c<='9';}function bound(t,i,n){var b=i>0?t.charAt(i-1):'';var f=(i+n)<t.length?t.charAt(i+n):'';return !w(b)&&!w(f);}var e=el.getBoundingClientRect();var out=[];for(var pi=0;pi<a.phrases.length;pi++){var phrase=a.phrases[pi];if(!phrase){continue;}var wk=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null);var nd;var occ=0;while(nd=wk.nextNode()){var t=nd.nodeValue;var from=0;var idx;while((idx=t.indexOf(phrase,from))!==-1){from=idx+phrase.length;if(!bound(t,idx,phrase.length)){continue;}var rg=document.createRange();rg.setStart(nd,idx);rg.setEnd(nd,idx+phrase.length);var rc=rg.getBoundingClientRect();if(rc.width>0){out.push({p:pi,i:occ,x:Math.round(rc.left-e.left),y:Math.round(rc.top-e.top),width:Math.round(rc.width),h:Math.round(rc.height)});}occ++;}}}return JSON.stringify(out);}catch(x){return '';}})('\(b64)')"

        guard let text = run(appName, js), !text.isEmpty,
              let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        return arr.compactMap { obj in
            guard let p = (obj["p"] as? NSNumber)?.intValue,
                  let i = (obj["i"] as? NSNumber)?.intValue,
                  let x = (obj["x"] as? NSNumber)?.doubleValue,
                  let y = (obj["y"] as? NSNumber)?.doubleValue,
                  let width = (obj["width"] as? NSNumber)?.doubleValue,
                  let h = (obj["h"] as? NSNumber)?.doubleValue else { return nil }
            return RawLocate(phraseIndex: p, occurrence: i, x: x, y: y, width: width, height: h)
        }
    }

    /// Replace the Nth occurrence of `phrase` with `fix` via the DOM
    /// (execCommand so the editor's model updates and fires input events).
    func replace(appName: String, phrase: String, occurrence: Int, fix: String) {
        let b64 = base64(["phrase": phrase, "occurrence": occurrence, "fix": fix])
        let js = "(function(b64){try{var a=JSON.parse(decodeURIComponent(escape(atob(b64))));var el=document.activeElement;if(!el||!el.isContentEditable){return 'no';}function w(c){return c>='A'&&c<='Z'||c>='a'&&c<='z'||c>='0'&&c<='9';}function bound(t,i,n){var b=i>0?t.charAt(i-1):'';var f=(i+n)<t.length?t.charAt(i+n):'';return !w(b)&&!w(f);}var phrase=a.phrase;var target=a.occurrence;var fix=a.fix;var wk=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null);var nd;var occ=0;while(nd=wk.nextNode()){var t=nd.nodeValue;var from=0;var idx;while((idx=t.indexOf(phrase,from))!==-1){from=idx+phrase.length;if(!bound(t,idx,phrase.length)){continue;}if(occ===target){var rg=document.createRange();rg.setStart(nd,idx);rg.setEnd(nd,idx+phrase.length);var sel=window.getSelection();sel.removeAllRanges();sel.addRange(rg);if(!document.execCommand('insertText',false,fix)){nd.nodeValue=t.slice(0,idx)+fix+t.slice(idx+phrase.length);}return 'ok';}occ++;}}return 'miss';}catch(x){return 'err';}})('\(b64)')"
        _ = run(appName, js)
    }

    /// JSON-encode + base64 so the payload survives AppleScript/JS string quoting.
    private func base64(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object))?.base64EncodedString() ?? ""
    }

    /// Compile + run a one-off JS snippet in the front tab; returns its string
    /// result (nil on error). Grammar checks are infrequent, so per-call compile
    /// is fine.
    private func run(_ appName: String, _ js: String) -> String? {
        guard let script = NSAppleScript(source: wrap(appName, js)) else { return nil }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error { warnOnce(error); return nil }
        return descriptor.stringValue
    }

    private func wrap(_ appName: String, _ js: String) -> String {
        "tell application \"\(appName)\"\nexecute active tab of front window javascript \"\(js)\"\nend tell"
    }

    private func warnOnce(_ error: NSDictionary) {
        guard !warned else { return }
        warned = true
        print("""
        ⚠️ Browser JS unavailable. To enable in-browser highlighting:
           1. In Brave/Chrome: View → Developer → Allow JavaScript from Apple Events
           2. Grant Automation permission for loco to control the browser when prompted
           (\(error[NSAppleScript.errorMessage] ?? error))
        """)
    }
}

import Foundation

// MARK: - Browser bridge (locate phrases + write-back in the real page)
//
// Contenteditable surfaces (Gmail, docs, chat boxes) expose text via AX but no
// per-range geometry — so once the LLM tells us which substrings are wrong, we
// run JS in the real page to find each phrase's DOM rect, and to apply fixes.
// Phrases are passed base64-encoded so arbitrary LLM text can't break the
// AppleScript/JS quoting. Requires the browser's "Allow JavaScript from Apple
// Events" (View → Developer) and Automation permission. No extension needed.

/// A rect for one requested character range, relative to the focused box.
struct RawRect {
    let index: Int     // which requested range
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// The current page selection: its text, a rect relative to the focused box,
/// whether it spans multiple lines, and the whole-sentence text it sits within.
struct RawSelection {
    let text: String
    let sentence: String
    let multiline: Bool
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

    /// The plain text of the focused contenteditable, taken from the DOM so its
    /// offsets line up with `rects`. Returns nil when focus isn't editable.
    func focusedText(appName: String) -> String? {
        let js = "(function(){try{var el=document.activeElement;if(!el||!el.isContentEditable){return '';}return el.textContent||'';}catch(x){return '';}})()"
        guard let text = run(appName, js), !text.isEmpty else { return nil }
        return text
    }

    /// Rects for character ranges (start, length) into the focused element's
    /// textContent — used to underline the changed words of a sentence.
    func rects(appName: String, ranges: [(Int, Int)]) -> [RawRect]? {
        guard !ranges.isEmpty else { return [] }
        let b64 = base64(["ranges": ranges.map { [$0.0, $0.1] }])
        let js = "(function(b64){try{var a=JSON.parse(decodeURIComponent(escape(atob(b64))));var el=document.activeElement;if(!el||!el.isContentEditable){return '';}var e=el.getBoundingClientRect();var wk=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null);var nodes=[];var full='';var nd;while(nd=wk.nextNode()){nodes.push({node:nd,start:full.length});full+=nd.nodeValue;}function loc(i){for(var k=0;k<nodes.length;k++){var s=nodes[k].start;var len=nodes[k].node.nodeValue.length;if(i<=s+len){return {node:nodes[k].node,off:i-s};}}var last=nodes[nodes.length-1];return {node:last.node,off:last.node.nodeValue.length};}var out=[];for(var j=0;j<a.ranges.length;j++){var st=a.ranges[j][0];var ln=a.ranges[j][1];var A=loc(st);var B=loc(st+ln);var rg=document.createRange();rg.setStart(A.node,A.off);rg.setEnd(B.node,B.off);var rc=rg.getBoundingClientRect();if(rc.width>0){out.push({i:j,x:Math.round(rc.left-e.left),y:Math.round(rc.top-e.top),width:Math.round(rc.width),h:Math.round(rc.height)});}}return JSON.stringify(out);}catch(x){return '';}})('\(b64)')"

        guard let text = run(appName, js), !text.isEmpty,
              let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        return arr.compactMap { obj in
            guard let i = (obj["i"] as? NSNumber)?.intValue,
                  let x = (obj["x"] as? NSNumber)?.doubleValue,
                  let y = (obj["y"] as? NSNumber)?.doubleValue,
                  let width = (obj["width"] as? NSNumber)?.doubleValue,
                  let h = (obj["h"] as? NSNumber)?.doubleValue else { return nil }
            return RawRect(index: i, x: x, y: y, width: width, height: h)
        }
    }

    /// The current non-empty selection in the focused contenteditable: its text
    /// and a rect relative to the focused element's box. Nil if nothing selected.
    func selection(appName: String) -> RawSelection? {
        let js = "(function(){try{var el=document.activeElement;if(!el||!el.isContentEditable){return '';}var s=window.getSelection();if(!s||!s.rangeCount||s.isCollapsed){return '';}var r=s.getRangeAt(0);var e=el.getBoundingClientRect();var rc=r.getBoundingClientRect();var selText=s.toString();var multiline=r.getClientRects().length>1;var full=el.textContent||'';var pre=document.createRange();pre.selectNodeContents(el);pre.setEnd(r.startContainer,r.startOffset);var start=pre.toString().length;var end=start+selText.length;var enders='.!?';var a=start;while(a>0&&enders.indexOf(full.charAt(a-1))<0){a--;}while(a<end&&full.charCodeAt(a)<=32){a++;}var b=end;while(b<full.length&&enders.indexOf(full.charAt(b-1))<0){b++;}var sentence=full.slice(a,b).trim();return JSON.stringify({text:selText,sentence:sentence,multiline:multiline,x:Math.round(rc.left-e.left),y:Math.round(rc.top-e.top),width:Math.round(rc.width),h:Math.round(rc.height)});}catch(x){return '';}})()"
        guard let out = run(appName, js), !out.isEmpty,
              let data = out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = o["text"] as? String, !text.isEmpty,
              let x = (o["x"] as? NSNumber)?.doubleValue,
              let y = (o["y"] as? NSNumber)?.doubleValue,
              let width = (o["width"] as? NSNumber)?.doubleValue,
              let h = (o["h"] as? NSNumber)?.doubleValue else { return nil }
        let sentence = (o["sentence"] as? String) ?? ""
        let multiline = (o["multiline"] as? NSNumber)?.boolValue ?? false
        return RawSelection(text: text, sentence: sentence, multiline: multiline,
                            x: x, y: y, width: width, height: h)
    }

    /// Replace `original` with `replacement`. Prefers the live selection if it
    /// still matches; otherwise finds `original` in the editable and selects it
    /// first. execCommand keeps the editor's model in sync.
    func replaceText(appName: String, original: String, replacement: String) {
        let b64 = base64(["orig": original, "rep": replacement])
        let js = "(function(b64){try{var a=JSON.parse(decodeURIComponent(escape(atob(b64))));var el=document.activeElement;if(!el||!el.isContentEditable){return 'no';}var s=window.getSelection();if(s&&s.rangeCount&&!s.isCollapsed&&s.toString()===a.orig){document.execCommand('insertText',false,a.rep);return 'ok';}var wk=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null);var nodes=[];var full='';var nd;while(nd=wk.nextNode()){nodes.push({node:nd,start:full.length});full+=nd.nodeValue;}var idx=full.indexOf(a.orig);if(idx<0){return 'miss';}function loc(i){for(var k=0;k<nodes.length;k++){var st=nodes[k].start;var len=nodes[k].node.nodeValue.length;if(i<=st+len){return {node:nodes[k].node,off:i-st};}}var last=nodes[nodes.length-1];return {node:last.node,off:last.node.nodeValue.length};}var A=loc(idx),B=loc(idx+a.orig.length);var rg=document.createRange();rg.setStart(A.node,A.off);rg.setEnd(B.node,B.off);s.removeAllRanges();s.addRange(rg);document.execCommand('insertText',false,a.rep);return 'ok';}catch(x){return 'err';}})('\(b64)')"
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

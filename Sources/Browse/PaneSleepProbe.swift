import WebKit

// @lat: [[lat.md/architecture/pane-sleep#Conservative state checks]]
@MainActor
enum PaneSleepProbe {
    private static let world = WKContentWorld.world(name: "Bend.PaneSleep")
    static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source == tracker }) else { return }
        controller.addUserScript(WKUserScript(source: tracker, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: activityTracker, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    static func remove(from controller: WKUserContentController) {
        let scripts = controller.userScripts
        let remaining = scripts.filter { $0.source != tracker && $0.source != activityTracker }
        guard remaining.count != scripts.count else { return }
        controller.removeAllUserScripts()
        for script in remaining { controller.addUserScript(script) }
    }

    static func check(_ web: WKWebView) async -> String? {
        // The page-world marker catches long-lived APIs that DOM/media queries
        // cannot describe (screen sharing, WebRTC, WebAudio). Missing = unknown.
        let activity: Bool? = await sleepReply { done in
            web.evaluateJavaScript("window.__bendSleepActivity?.safe === true && !window.onbeforeunload") { result, error in
                done(error == nil ? result as? Bool : nil)
            }
        }
        guard activity == true else { return nil }
        return await sleepReply { done in
            web.evaluateJavaScript(checkScript, in: nil, in: world) { result in
                guard case .success(let value) = result else { done(nil); return }
                done(value as? String)
            }
        }
    }

    static let tracker = #"""
    (() => {
      let dirty = false;
      const token = crypto.randomUUID();
      // Sticky until navigation: an autosave or a cleared field is not evidence
      // that an editor has safely persisted its work.
      for (const event of ['input', 'change', 'beforeinput'])
        addEventListener(event, () => { dirty = true; }, true);
      globalThis.__bendSleepCheck = () => {
        if (dirty || document.readyState !== 'complete' || document.designMode === 'on') return null;
        if (document.pictureInPictureElement || document.fullscreenElement) return null;
        // Embedded documents and custom elements may hide editors/calls in
        // inaccessible frames or closed shadow roots. Do not guess their state.
        for (const e of document.querySelectorAll('*')) {
          if (e.localName.includes('-') || e.shadowRoot || ['iframe','frame','object','embed'].includes(e.localName)) return null;
          if (e.isContentEditable) return null;
          if (e instanceof HTMLTextAreaElement && e.value !== e.defaultValue) return null;
          if (e instanceof HTMLInputElement && (e.value !== e.defaultValue || e.checked !== e.defaultChecked || e.files?.length)) return null;
          if (e instanceof HTMLSelectElement && Array.from(e.options).some(o => o.selected !== o.defaultSelected)) return null;
          if (e instanceof HTMLMediaElement && (!e.paused || e.webkitPresentationMode === 'picture-in-picture')) return null;
        }
        return token;
      };
    })();
    """#

    static let checkScript = "globalThis.__bendSleepCheck?.() ?? null"

    private static let activityTracker = #"""
    (() => {
      let safe = true;
      Object.defineProperty(window, '__bendSleepActivity', {value: Object.freeze({ get safe() { return safe; } })});
      try {
        const attachShadow = Element.prototype.attachShadow;
        Element.prototype.attachShadow = function(...args) {
          safe = false;
          return attachShadow.apply(this, args);
        };
        const listen = window.addEventListener;
        window.addEventListener = function(type, ...args) {
          if (type === 'beforeunload') safe = false;
          return listen.call(this, type, ...args);
        };
        for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'AudioContext', 'webkitAudioContext']) {
          const original = window[name];
          if (!original) continue;
          const wrapper = new Proxy(original, {construct(target, args, receiver) {
            safe = false;
            return Reflect.construct(target, args, receiver);
          }});
          window[name] = wrapper;
          if (window[name] !== wrapper) safe = false;
        }
        const devices = navigator.mediaDevices;
        for (const name of ['getUserMedia', 'getDisplayMedia']) {
          if (!devices?.[name]) continue;
          const original = devices[name];
          const wrapper = function(...args) { safe = false; return original.apply(this, args); };
          devices[name] = wrapper;
          if (devices[name] !== wrapper) safe = false;
        }
      } catch { safe = false; }
    })();
    """#
}

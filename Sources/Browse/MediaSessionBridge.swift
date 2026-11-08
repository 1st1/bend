import WebKit

// @lat: [[architecture#Sidebar media player]]
@MainActor
final class MediaSessionBridge: NSObject, WKScriptMessageHandler {
    static let script = #"""
    (() => {
        if (window.__bendMedia) return;
        const documentID = '10000000-1000-4000-8000-100000000000'.replace(/[018]/g,
            digit => (Number(digit) ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> Number(digit) / 4).toString(16));
        const handlers = new Map(), players = new Set(), played = new WeakSet(), detached = new WeakSet();
        const ids = new WeakMap();
        let nextID = 0, current = null, previous = '', queued = false, sessionPlayed = false;
        let declaredPlaybackState = 'none';
        let positionState = null;
        const buffering = new WeakSet();
        const sessionPosition = () => positionState ? Math.max(0, Math.min(positionState.duration,
            positionState.position + (declaredPlaybackState === 'playing' ?
                (performance.now() - positionState.updatedAt) / 1000 * positionState.playbackRate : 0))) : 0;
        let playbackRevision = 0, wasPlaying = false, lastPlayerID = '';
        const session = navigator.mediaSession;
        const post = value => {
            try { window.webkit.messageHandlers.bendMedia.postMessage({documentID, ...value}); } catch {}
        };
        const text = value => typeof value === 'string' ? value.slice(0, 512) : '';
        const remember = media => {
            if (!(media instanceof HTMLMediaElement) || players.has(media)) return;
            players.add(media); ids.set(media, String(++nextID));
            if (!media.isConnected) detached.add(media);
            for (const name of ['play','playing','pause','ended','emptied','error','loadedmetadata','volumechange',
                'durationchange','ratechange','seeking','seeked','waiting']) {
                media.addEventListener(name, () => {
                    if (name === 'waiting') buffering.add(media);
                    if (name === 'playing' || name === 'seeked' || name === 'emptied') buffering.delete(media);
                    if (!media.paused && !media.ended && !media.muted && media.volume > 0) { played.add(media); current = media; }
                    schedule();
                });
            }
            if (!media.paused && !media.ended && !media.muted && media.volume > 0) { played.add(media); current = media; }
        };
        const scan = root => {
            if (root instanceof HTMLMediaElement) remember(root);
            if (root.querySelectorAll) {
                for (const media of root.querySelectorAll('audio,video')) remember(media);
                for (const element of root.querySelectorAll('*')) if (element.shadowRoot) watch(element.shadowRoot);
            }
        };
        const watched = new WeakSet();
        const watch = root => {
            if (watched.has(root)) return;
            watched.add(root);
            new MutationObserver(records => {
                for (const record of records) for (const node of record.addedNodes) scan(node);
                if (players.size || sessionPlayed) schedule();
            }).observe(root, {childList:true, subtree:true});
            scan(root);
        };
        const snapshot = () => {
            for (const media of players) {
                if (media.isConnected) detached.delete(media);
                else if (!detached.has(media) || media.ended || media.error
                    || (played.has(media) && media.networkState === HTMLMediaElement.NETWORK_EMPTY)) players.delete(media);
            }
            const audible = media => !media.muted && media.volume > 0;
            const playing = [...players].filter(media => !media.paused && !media.ended && audible(media));
            if (!playing.includes(current) && playing.length) current = playing[playing.length - 1];
            if (!players.has(current) || current?.ended) current = [...players].find(media => played.has(media) && !media.ended) || null;
            const declared = declaredPlaybackState;
            if (declared === 'playing') sessionPlayed = true;
            const metadata = session?.metadata;
            const hasSession = sessionPlayed && (declared !== 'none' || current != null);
            const active = hasSession || !!(current && played.has(current) && !current.ended);
            const actions = [...handlers.keys()];
            if (current) {
                for (const action of ['play', 'pause']) if (!actions.includes(action)) actions.push(action);
                if (Number.isFinite(current.duration) && current.duration > 0 && current.seekable.length
                    && !actions.includes('seekto')) actions.push('seekto');
            }
            let timeline = null;
            if (current && Number.isFinite(current.duration) && current.duration > 0) {
                timeline = {duration: current.duration, position: current.currentTime,
                    rate: !current.paused && !current.seeking && !buffering.has(current) && current.readyState >= 3 ? current.playbackRate : 0};
            } else if (positionState && Number.isFinite(positionState.duration) && positionState.duration > 0) {
                timeline = {duration: positionState.duration, position: sessionPosition(),
                    rate: declared === 'playing' ? positionState.playbackRate : 0};
            }
            const playerID = hasSession ? 'session' : (ids.get(current) || '');
            const isPlaying = playing.length > 0 || (declared === 'playing' && !current);
            if (isPlaying && (!wasPlaying || lastPlayerID !== playerID)) playbackRevision++;
            wasPlaying = isPlaying; lastPlayerID = playerID;
            return {
                active, playerID, playbackRevision, playing: isPlaying,
                title: text(metadata?.title) || text(current?.getAttribute('aria-label')) || text(current?.title) || text(document.title),
                artist: text(metadata?.artist), actions, timeline
            };
        };
        const publish = (force = false) => {
            queued = false;
            const state = snapshot(), serialized = JSON.stringify(state);
            if (force || serialized !== previous) { previous = serialized; post({kind:'state', ...state}); }
        };
        function schedule() {
            if (!queued) { queued = true; queueMicrotask(() => publish()); }
        }
        if (session) {
            const prototype = Object.getPrototypeOf(session);
            const original = prototype.setActionHandler;
            prototype.setActionHandler = function(action, handler) {
                const result = original.call(this, action, handler);
                if (this === session) {
                    if (handler == null) handlers.delete(action); else handlers.set(action, handler);
                    schedule();
                }
                return result;
            };
            const setPosition = prototype.setPositionState;
            if (setPosition) prototype.setPositionState = function(value) {
                const result = setPosition.call(this, value);
                if (this === session) {
                    positionState = value && value.duration !== undefined ? {
                        duration: Number(value.duration), position: Number(value.position ?? 0),
                        playbackRate: Number(value.playbackRate ?? 1), updatedAt: performance.now()
                    } : null;
                    schedule();
                }
                return result;
            };
            // Preserve native accessors and exceptions; active-frame refresh also
            // catches in-place changes to MediaMetadata.title/artist.
            for (const name of ['metadata', 'playbackState']) {
                const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
                if (descriptor?.set && descriptor.configurable) {
                    Object.defineProperty(prototype, name, {...descriptor, set(value) {
                        const position = sessionPosition();
                        descriptor.set.call(this, value);
                        if (this === session) {
                            if (name === 'playbackState') {
                                if (positionState) { positionState.position = position; positionState.updatedAt = performance.now(); }
                                declaredPlaybackState = String(value);
                            }
                            schedule();
                        }
                    }});
                }
            }
        }
        Object.defineProperty(window, '__bendMedia', {value: {
            pauseForFocusLoss(expected, playerID, revision, nativePaused = false) {
                const state = snapshot();
                if (expected !== documentID || state.playerID !== playerID || state.playbackRevision !== revision) return 'stale';
                if (!state.playing) return 'paused';
                let handled = nativePaused;
                if (!nativePaused && handlers.has('pause')) {
                    try {
                        Promise.resolve(handlers.get('pause')({action:'pause'})).catch(() => {});
                        handled = true;
                    } catch {}
                }
                for (const media of players) { media.pause(); handled = true; }
                if (!handled) return 'native';
                // Mirror the explicit browser pause for handler-only sessions.
                // Web Audio without a handler is stopped by the native fallback.
                if (positionState) { positionState.position = sessionPosition(); positionState.updatedAt = performance.now(); }
                declaredPlaybackState = 'paused';
                publish();
                return 'paused';
            },
            refresh(expected) {
                if (expected !== documentID) return false;
                publish(); return true;
            },
            async command(expected, playerID, action, value) {
                if (expected !== documentID) return false;
                const state = snapshot();
                if (!state.active || state.playerID !== playerID || !state.actions.includes(action)) return false;
                if (action === 'seekto') {
                    if (!Number.isFinite(value) || !state.timeline || value < 0 || value > state.timeline.duration) return false;
                    if (handlers.has(action)) await handlers.get(action)({action, seekTime: value, fastSeek: false});
                    else if (current) {
                        let seekable = false;
                        for (let i = 0; i < current.seekable.length; i++)
                            if (value >= current.seekable.start(i) && value <= current.seekable.end(i)) seekable = true;
                        if (!seekable) return false;
                        current.currentTime = value;
                    } else return false;
                } else if (handlers.has(action)) {
                    await handlers.get(action)({action});
                } else if (current && action === 'play') { await current.play(); }
                else if (current && action === 'pause') { current.pause(); }
                else return false;
                publish(); return true;
            }
        }});
        // Audio can play without ever entering the DOM. Preserve the native
        // play promise and exceptions while observing those elements too.
        const play = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function(...args) {
            const result = play.apply(this, args);
            remember(this); schedule();
            return result;
        };
        // Discover inserted and open-shadow-root players without idle polling.
        const attachShadow = Element.prototype.attachShadow;
        Element.prototype.attachShadow = function(options) {
            const root = attachShadow.call(this, options);
            if (options.mode === 'open') watch(root);
            return root;
        };
        post({kind:'hello'});
        watch(document);
        addEventListener('pagehide', () => post({kind:'gone'}));
        addEventListener('pageshow', () => { post({kind:'hello'}); publish(true); });
        publish();
    })();
    """#

    static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source == script }) else { return }
        controller.add(MediaSessionBridge(), contentWorld: .page, name: "bendMedia")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Shared content controllers must route using WebKit's source, never a page-supplied pane ID.
        guard let web = message.webView as? FocusWebView else { return }
        web.mediaController?.receive(message)
    }
}

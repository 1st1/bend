// @lat: [[architecture#Extension WASM diagnostics]]
enum ExtensionWasmDiagnostics {
    // Runs only inside the authorized extension-page adapter. Observations are
    // bounded and classified here, before reaching the host's diagnostic log.
    static let javascript = #"""
    (() => {
        let remaining = 96;
        let page = 'extension-page';
        try {
            const background = native.runtime.getManifest().background?.page;
            if (background && new URL(background, native.runtime.getURL('/')).pathname === location.pathname) page = 'background';
        } catch (_) {}
        const describe = (phase, stage, value, error) => {
            try {
                if (remaining-- <= 0) return;
                let errorName = 'none', category = 'none';
                if (stage === 'failed') {
                    errorName = error?.name;
                    if (!['Error','TypeError','RangeError','CompileError','LinkError','RuntimeError'].includes(errorName)) errorName = 'other';
                    const text = String(error?.message ?? '').toLowerCase();
                    category = /mime/.test(text) ? 'mime-type'
                        : /content security policy|unsafe-eval|disallowed by.*policy/.test(text) ? 'csp'
                        : /out of memory|out-of-memory|memory allocation/.test(text) ? 'out-of-memory'
                        : errorName === 'CompileError' ? 'compile'
                        : errorName === 'LinkError' ? 'link'
                        : errorName === 'RuntimeError' ? 'runtime-trap'
                        : phase === 'fetch' ? 'fetch' : 'other';
                }
                let mime = 'not-response', responseType = 'not-response', responseOK = 'not-response';
                if (value instanceof Response) {
                    const type = value.headers.get('Content-Type');
                    mime = type === null ? 'missing' : type.split(';')[0].trim().toLowerCase() === 'application/wasm' ? 'wasm' : 'other';
                    responseType = ['basic','cors','default','error','opaque','opaqueredirect'].includes(value.type) ? value.type : 'not-response';
                    responseOK = String(value.ok);
                }
                call('wasmDiagnostic', {phase, stage, page, errorName, category, mime, responseType, responseOK}).catch(() => {});
            } catch (_) { /* Diagnostics must never replace the original result. */ }
        };
        const observe = (phase, original, receiver, args, response) => {
            describe(phase, 'started', response);
            let pending;
            try { pending = Reflect.apply(original, receiver, args); }
            catch (error) { describe(phase, 'failed', response, error); throw error; }
            return pending.then(value => {
                describe(phase, 'succeeded', phase === 'fetch' ? value : response);
                return value;
            }, error => {
                describe(phase, 'failed', response, error);
                throw error;
            });
        };
        // Fetch only observes packaged WASM resources in this extension's own
        // origin. It never consumes or clones a response body or reads options.
        const originalFetch = globalThis.fetch;
        globalThis.fetch = function(...args) {
            let isModule = false;
            try {
                const input = args[0];
                if (typeof input === 'string' || input instanceof URL || input instanceof Request) {
                    const url = new URL(input instanceof Request ? input.url : input, location.href);
                    isModule = url.origin === location.origin && url.protocol === location.protocol
                        && url.host === location.host && url.pathname.endsWith('.wasm');
                }
            } catch (_) {}
            return isModule ? observe('fetch', originalFetch, this, args) : Reflect.apply(originalFetch, this, args);
        };
        if (typeof WebAssembly !== 'object') return;
        for (const phase of ['compile', 'compileStreaming', 'instantiate', 'instantiateStreaming']) {
            const original = WebAssembly[phase];
            if (typeof original !== 'function') continue;
            WebAssembly[phase] = function(...args) {
                return observe(phase, original, this, args, args[0]);
            };
        }
    })();
    """#
}

// DIAGNOSTIC ONLY. These event registrations let startup continue far enough
// to find other failures. They are not a notifications implementation.
// No notification operation is reported as successful.
(() => {
    const event = () => {
        const listeners = new Set();
        return {
            addListener(listener) { listeners.add(listener); },
            removeListener(listener) { listeners.delete(listener); },
            hasListener(listener) { return listeners.has(listener); },
            hasListeners() { return listeners.size > 0; }
        };
    };
    const unsupported = () => { throw new Error('Diagnostic probe has no notifications implementation'); };
    for (const api of [globalThis.chrome, globalThis.browser]) {
        if (!api || api.notifications) continue;
        api.notifications = {
            onClicked: event(), onButtonClicked: event(), onClosed: event(), onPermissionLevelChanged: event(),
            create: unsupported, clear: unsupported, update: unsupported, getAll: unsupported,
            getPermissionLevel: unsupported
        };
    }
})();

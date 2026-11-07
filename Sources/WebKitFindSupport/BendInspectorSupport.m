#import "BendInspectorSupport.h"

@protocol BendOptionalInspector <NSObject>
@property (nonatomic, weak) id delegate;
- (void)connect;
- (WKWebView *)inspectorWebView;
- (void)close;
- (void)hide;
@end

@interface WKWebView (BendOptionalInspector)
@property (nonatomic, readonly) id<BendOptionalInspector> _inspector;
@end

@interface WKPreferences (BendOptionalDeveloperExtras)
- (void)_setDeveloperExtrasEnabled:(BOOL)enabled;
@end

@interface BendInspectorSupport () <WKScriptMessageHandler>
@end

// @lat: [[architecture#Developer tools]]
@implementation BendInspectorSupport {
    __weak WKWebView *_webView;
    __weak id<BendOptionalInspector> _openedInspector;
    __weak WKWebView *_frontend;
    BOOL _consoleRequested;
    BOOL _presented;
}

+ (void)enableForWebView:(WKWebView *)webView
{
    webView.inspectable = YES;
    WKPreferences *preferences = webView.configuration.preferences;
    if ([preferences respondsToSelector:@selector(_setDeveloperExtrasEnabled:)])
        [preferences _setDeveloperExtrasEnabled:YES];
}

- (instancetype)initWithWebView:(WKWebView *)webView
{
    if (!(self = [super init])) return nil;
    _webView = webView;
    return self;
}

- (id<BendOptionalInspector>)inspector
{
    WKWebView *web = _webView;
    return [web respondsToSelector:@selector(_inspector)] ? web._inspector : nil;
}

- (BOOL)canShow
{
    id inspector = self.inspector;
    return [inspector respondsToSelector:@selector(connect)]
        && [inspector respondsToSelector:@selector(inspectorWebView)]
        && [inspector respondsToSelector:@selector(setDelegate:)]
        && [inspector respondsToSelector:@selector(hide)]
        && [inspector respondsToSelector:@selector(close)];
}

- (BOOL)isVisible
{
    return _presented;
}

- (BOOL)showConsole:(BOOL)console
{
    if (!self.canShow) return NO;
    id<BendOptionalInspector> inspector = self.inspector;
    if (![inspector respondsToSelector:@selector(delegate)] || (inspector.delegate && inspector.delegate != self)) return NO;
    _openedInspector = inspector;
    _consoleRequested = console;
    _presented = YES;
    inspector.delegate = self;
    // Connect without asking WebKit to create a separate inspector window or
    // apply its minimum-size docking policy. Bend hosts the native frontend.
    if (_frontend) [self presentFrontend]; else [inspector connect];
    return YES;
}

- (void)presentFrontend
{
    WKWebView *frontend = _frontend;
    if (!_presented || !frontend) return;
    if (self.onFrontendReady) self.onFrontendReady(frontend);
    if (_consoleRequested) {
        // This targets only WebKit's inspector UI, never the inspected website.
        [frontend evaluateJavaScript:@"if (window.WI?.showConsoleTab) WI.showConsoleTab();"
                   completionHandler:nil];
    }
}

- (void)inspectorFrontendLoaded:(id<BendOptionalInspector>)inspector
{
    if (inspector != _openedInspector || ![inspector respondsToSelector:@selector(inspectorWebView)]) return;
    _frontend = [inspector inspectorWebView];
    // Only the trusted inspector frontend gets this bridge. Website frames
    // never receive a handler or script that can change inspector placement.
    [_frontend.configuration.userContentController addScriptMessageHandler:self name:@"bendInspector"];
    [_frontend evaluateJavaScript:@""
        "(() => {"
        " const wi = window.WI; if (!wi) return;"
        " const style = document.createElement('style');"
        " style.textContent = '.tab-bar { background: #202020 !important; }"
        " .tab-bar, .tab-bar > .tabs > .item, .tab-bar .navigation-bar { backdrop-filter: none !important; -webkit-backdrop-filter: none !important; background-image: none !important; box-shadow: none !important; }"
        " .tab-bar > .tabs > .item { background-color: #202020 !important; }"
        " .tab-bar > .tabs > .item.selected { background-color: #303030 !important; }';"
        " document.head.append(style);"
        " const send = action => window.webkit.messageHandlers.bendInspector.postMessage(action);"
        " for (const [key, handler, action] of [['_closeTabBarButton', 'close', 'close'], ['_dockRightTabBarButton', '_dockRight', 'right'], ['_dockBottomTabBarButton', '_dockBottom', 'bottom']]) {"
        "   const item = wi[key]; if (!item) continue;"
        "   item.removeEventListener(wi.ButtonNavigationItem.Event.Clicked, wi[handler], wi);"
        "   item.addEventListener(wi.ButtonNavigationItem.Event.Clicked, () => send(action), wi);"
        " }"
        " wi._updateDockNavigationItems = () => {"
        "   for (const key of ['_dockLeftTabBarButton', '_undockTabBarButton'])"
        "     if (wi[key]) wi[key].hidden = true;"
        "   for (const key of ['_closeTabBarButton', '_dockRightTabBarButton', '_dockBottomTabBarButton'])"
        "     if (wi[key]) wi[key].hidden = false;"
        "   if (wi._dockRightTabBarButton) wi._dockRightTabBarButton.enabled = wi.dockConfiguration !== wi.DockConfiguration.Right;"
        "   if (wi._dockBottomTabBarButton) wi._dockBottomTabBarButton.enabled = wi.dockConfiguration !== wi.DockConfiguration.Bottom;"
        "   wi._updateTabBarDividers?.(); wi.tabBar?.resetCachedWidths();"
        " };"
        " wi.moveUndockedWindowMouseDown = () => {};"
        " wi.resizeDockedFrameMouseDown = () => {};"
        " if (wi._dockedResizerElement) wi._dockedResizerElement.style.display = 'none';"
        " wi._updateDockNavigationItems();"
        " if (wi._togglePreviousDockConfigurationKeyboardShortcut) wi._togglePreviousDockConfigurationKeyboardShortcut.disabled = true;"
        "})();"
        completionHandler:nil];
    [self updateDockedState];
    [self presentFrontend];
}

- (void)setDockedToRight:(BOOL)dockedToRight
{
    _dockedToRight = dockedToRight;
    [self updateDockedState];
}

- (void)restoreEmbedding
{
    if (!_presented || !_frontend) return;
    // Inspect-element and debugger reveal requests can invoke WebKit's native
    // presentation after connect(). Hide that presentation without closing the
    // backend, stopping its automatic resizing before remounting our frontend.
    [_openedInspector hide];
    if (self.onFrontendReady) self.onFrontendReady(_frontend);
    [self updateDockedState];
}

- (void)updateDockedState
{
    [_frontend evaluateJavaScript:_dockedToRight
        ? @"window.WI?.updateDockedState(WI.DockConfiguration.Right);"
        : @"window.WI?.updateDockedState(WI.DockConfiguration.Bottom);" completionHandler:nil];
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (!_presented || message.webView != _frontend || !message.frameInfo.mainFrame
        || ![message.body isKindOfClass:NSString.class]) return;
    NSString *action = message.body;
    if (([action isEqualToString:@"close"] || [action isEqualToString:@"bottom"] || [action isEqualToString:@"right"])
        && self.onAction) self.onAction(action);
}

- (void)invalidate
{
    [_frontend.configuration.userContentController removeScriptMessageHandlerForName:@"bendInspector"];
    id<BendOptionalInspector> inspector = _openedInspector;
    if ([inspector respondsToSelector:@selector(delegate)] && [inspector respondsToSelector:@selector(setDelegate:)]
        && inspector.delegate == self) inspector.delegate = nil;
    if ([inspector respondsToSelector:@selector(close)]) [inspector close];
    _openedInspector = nil;
    _frontend = nil;
    _presented = NO;
    self.onFrontendReady = nil;
    self.onAction = nil;
    _webView = nil;
}
@end

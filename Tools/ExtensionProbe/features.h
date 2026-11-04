#import <WebKit/WebKit.h>
BOOL enableProbeFeature(WKPreferences *preferences, NSString *key);
WKWebView *probeBackgroundView(WKWebExtensionContext *context);

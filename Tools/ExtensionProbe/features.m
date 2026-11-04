#import "features.h"

// Diagnostic-only SPI: discover feature availability instead of assuming that
// the installed framework matches the source checkout.
@interface WKPreferences (ProbeFeatures)
+ (NSArray *)_features;
- (void)_setEnabled:(BOOL)enabled forFeature:(id)feature;
@end

BOOL enableProbeFeature(WKPreferences *preferences, NSString *key) {
    if (![WKPreferences respondsToSelector:@selector(_features)]) return NO;
    for (id feature in [WKPreferences _features]) {
        if ([[feature valueForKey:@"key"] isEqual:key]) {
            [preferences _setEnabled:YES forFeature:feature];
            return YES;
        }
    }
    return NO;
}

WKWebView *probeBackgroundView(WKWebExtensionContext *context) {
    if (![context respondsToSelector:NSSelectorFromString(@"_backgroundWebView")]) return nil;
    return [context valueForKey:@"_backgroundWebView"];
}

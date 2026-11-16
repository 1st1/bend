#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
NS_SWIFT_UI_ACTOR
@interface BendSelectionSupport : NSObject
+ (BOOL)enableForWebView:(WKWebView *)webView;
@end
NS_ASSUME_NONNULL_END

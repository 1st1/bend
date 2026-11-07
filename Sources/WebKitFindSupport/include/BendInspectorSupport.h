#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// Optional local inspector SPI; public isInspectable remains the Safari fallback.
NS_SWIFT_UI_ACTOR
@interface BendInspectorSupport : NSObject
+ (void)enableForWebView:(WKWebView *)webView;
- (instancetype)initWithWebView:(WKWebView *)webView;
@property (nonatomic, copy, nullable) void (^onFrontendReady)(WKWebView *frontend);
@property (nonatomic, copy, nullable) void (^onAction)(NSString *action);
@property (nonatomic) BOOL dockedToRight;
@property (nonatomic, readonly) BOOL canShow;
@property (nonatomic, readonly) BOOL isVisible;
- (BOOL)showConsole:(BOOL)console;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END

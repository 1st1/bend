#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// Keeps optional WebKit SPI behind a checked, typed Objective-C boundary.
NS_SWIFT_UI_ACTOR
@interface BendFindSupport : NSObject
- (instancetype)initWithWebView:(WKWebView *)webView;
- (void)countMatches:(NSString *)query completion:(void (^)(NSNumber * _Nullable count))completion;
- (void)clearSearch;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END

#import "BendFindSupport.h"

// These selectors are WebKit SPI, not public SDK API. Keep use optional and
// confined here; ordinary search continues to use WKWebView's public API.
@interface WKWebView (BendOptionalFind)
@property (nonatomic, weak, setter=_setFindDelegate:) id _findDelegate;
- (void)_countStringMatches:(NSString *)query options:(NSUInteger)options maxCount:(NSUInteger)maxCount;
- (void)_findString:(NSString *)query options:(NSUInteger)options maxCount:(NSUInteger)maxCount;
- (void)_hideFindUI;
@end

@interface BendFindRequest : NSObject
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) void (^completion)(NSNumber *);
@end
@implementation BendFindRequest
@end

// @lat: [[lat.md/architecture/find#Find in page]]
@implementation BendFindSupport {
    __weak WKWebView *_webView;
    NSMutableArray<BendFindRequest *> *_requests;
    BOOL _canCount;
}

- (instancetype)initWithWebView:(WKWebView *)webView
{
    if (!(self = [super init])) return nil;
    _webView = webView;
    _requests = [NSMutableArray array];
    _canCount = [webView respondsToSelector:@selector(_setFindDelegate:)]
        && [webView respondsToSelector:@selector(_findDelegate)]
        && [webView respondsToSelector:@selector(_countStringMatches:options:maxCount:)];
    // Do not take over a delegate belonging to another feature.
    if (_canCount && webView._findDelegate != nil) _canCount = NO;
    if (_canCount) webView._findDelegate = self;
    return self;
}

- (void)countMatches:(NSString *)query completion:(void (^)(NSNumber *))completion
{
    WKWebView *web = _webView;
    if (!_canCount || !web || web._findDelegate != self) { completion(nil); return; }
    BendFindRequest *request = [BendFindRequest new];
    request.query = query;
    request.completion = completion;
    [_requests addObject:request];
    // Case-insensitive, matching WKFindConfiguration. Bound renderer work.
    [web _countStringMatches:query options:1 maxCount:10000];
}

- (void)_webView:(WKWebView *)webView didCountMatches:(NSUInteger)matches forString:(NSString *)query
{
    if (webView != _webView) return;
    // Replies echo the query, but not a request ID. Preserve FIFO for repeated
    // queries; Swift's generation checks discard obsolete completions.
    NSUInteger index = [_requests indexOfObjectPassingTest:^BOOL(BendFindRequest *request, NSUInteger idx, BOOL *stop) {
        return [request.query isEqualToString:query];
    }];
    if (index == NSNotFound) return;
    BendFindRequest *request = _requests[index];
    [_requests removeObjectAtIndex:index];
    request.completion(@(MIN(matches, 10001)));
}

- (void)clearSearch
{
    WKWebView *web = _webView;
    if (!web) return;
    // Public find("") is a no-op. The native empty-string operation clears
    // the find selection, including inside frames, without moving the viewport.
    if ([web respondsToSelector:@selector(_findString:options:maxCount:)])
        [web _findString:@"" options:0 maxCount:1];
    else {
        [web evaluateJavaScript:@"(() => { const clear = w => { try { w.getSelection()?.removeAllRanges(); for (let i = 0; i < w.frames.length; i++) clear(w.frames[i]); } catch {} }; clear(window); })()"
              completionHandler:nil];
    }
    if ([web respondsToSelector:@selector(_hideFindUI)]) [web _hideFindUI];
}

- (void)invalidate
{
    WKWebView *web = _webView;
    if (_canCount && web._findDelegate == self) web._findDelegate = nil;
    _webView = nil;
    [_requests removeAllObjects];
}
@end

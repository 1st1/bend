#import "BendContextMenuDelegate.h"

// Selectors from WebKit's _WKContextMenuElementInfo and _WKHitTestResult.
// No dependency on private class symbols; leave the native menu intact if absent.
@interface NSObject (BendMenuElement)
@property (nonatomic, readonly) id hitTestResult;
@property (nonatomic, readonly) NSURL *absoluteLinkURL;
@property (nonatomic, readonly) WKFrameInfo *frameInfo;
@property (nonatomic, readonly) BOOL allowsFollowingLink;
@end

@implementation BendContextMenuDelegate
- (void)_webView:(WKWebView *)webView getContextMenuFromProposedMenu:(NSMenu *)menu
     forElement:(id)element userInfo:(id)userInfo completionHandler:(void (^)(NSMenu *))completion
{
    if (![element respondsToSelector:@selector(hitTestResult)]
        || ![element respondsToSelector:@selector(allowsFollowingLink)] || ![element allowsFollowingLink]) {
        completion(menu);
        return;
    }
    id hit = [element hitTestResult];
    NSURL *url = [hit respondsToSelector:@selector(absoluteLinkURL)] ? [hit absoluteLinkURL] : nil;
    if (![url isKindOfClass:NSURL.class]
        || ![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]) {
        completion(menu);
        return;
    }
    WKFrameInfo *frame = [hit respondsToSelector:@selector(frameInfo)] ? [hit frameInfo] : nil;
    completion([self contextMenu:menu forLinkURL:url fromMainFrame:frame.isMainFrame]);
}

- (NSMenu *)contextMenu:(NSMenu *)menu forLinkURL:(NSURL *)url fromMainFrame:(BOOL)mainFrame
{
    return menu;
}
@end

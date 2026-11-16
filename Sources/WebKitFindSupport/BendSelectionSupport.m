#import "BendSelectionSupport.h"
#import <dlfcn.h>
#include <stdbool.h>

@interface WKWebView (BendOptionalSelection)
- (const void *)_pageRefForTransitionToWKWebView;
@end

// @lat: [[lat.md/architecture/ai#Selection and screenshots]]
@implementation BendSelectionSupport
+ (BOOL)enableForWebView:(WKWebView *)webView
{
    // Keep WebKit's actual selection, including images, across native focus
    // changes. Resolve both private entry points at runtime; never assume ABI
    // layout or suppress WebKit's normal resignFirstResponder housekeeping.
    typedef void (*SetMaintainsSelection)(const void *, bool);
    static SetMaintainsSelection setMaintainsSelection;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        setMaintainsSelection = (SetMaintainsSelection)dlsym(RTLD_DEFAULT, "WKPageSetMaintainsInactiveSelection");
    });
    if (!setMaintainsSelection || ![webView respondsToSelector:@selector(_pageRefForTransitionToWKWebView)])
        return NO;
    const void *page = [webView _pageRefForTransitionToWKWebView];
    if (!page) return NO;
    setMaintainsSelection(page, true);
    return YES;
}
@end

#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// The macOS hit-test delegate is SPI. Keep its checked access in Objective-C.
NS_SWIFT_UI_ACTOR
@interface BendContextMenuDelegate : NSObject
- (NSMenu *)contextMenu:(NSMenu *)menu forLinkURL:(NSURL *)url fromMainFrame:(BOOL)mainFrame;
@end

NS_ASSUME_NONNULL_END

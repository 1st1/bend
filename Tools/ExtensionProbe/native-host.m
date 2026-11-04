#import <AppKit/AppKit.h>
#import <SafariServices/SafariServices.h>

// Diagnostic-only declaration of the same Foundation SPI used by WebKit.
// Host validation is performed by macOS; the build script can vary entitlements.
@interface NSObject (NativeExtensionProbe)
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
@end

static NSDictionary *describeError(NSError *error) {
    if (!error) return @{};
    NSMutableDictionary *result = [@{
        @"domain": error.domain, @"code": @(error.code),
        @"description": error.localizedDescription
    } mutableCopy];
    NSString *debug = error.userInfo[NSDebugDescriptionErrorKey];
    if (debug) result[@"debug"] = debug;
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (underlying && underlying != error) result[@"underlying"] = describeError(underlying);
    return result;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: BrowseExtensionProbe extension-bundle-identifier\n"); return 2; }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [NSBundle bundleForClass:SFSafariApplication.class];
        Class extensionClass = NSClassFromString(@"NSExtension");
        NSError *error = nil;
        id extension = [extensionClass extensionWithIdentifier:@(argv[1]) error:&error];
        NSDictionary *result = @{
            @"host": NSBundle.mainBundle.bundleIdentifier ?: @"unbundled",
            @"pid": @(NSProcessInfo.processInfo.processIdentifier),
            @"extension": @(argv[1]),
            @"resolved": @(extension != nil),
            @"error": describeError(error)
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return extension && !error ? 0 : 1;
    }
}

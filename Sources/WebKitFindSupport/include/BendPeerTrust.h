#import <Foundation/Foundation.h>
#import <Security/Security.h>

// Core Foundation objects in NSError.userInfo need a CF type ID check before bridging.
static inline SecTrustRef _Nullable BendPeerTrust(NSError * _Nonnull error) CF_RETURNS_NOT_RETAINED {
    id value = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey];
    CFTypeRef object = (__bridge CFTypeRef)value;
    if (!object || CFGetTypeID(object) != SecTrustGetTypeID()) return NULL;
    return (SecTrustRef)object;
}

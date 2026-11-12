import WebKit
import BrowseCore

// @lat: [[architecture#Privacy preferences]]
@MainActor
enum WebKitPrivacy {
    // Keep private WebKit SPI isolated and capability-checked. These preferences
    // belong to Bend's objects and never change Safari's settings.
    enum Control {
        case tracking, applePay, measurement, advanced

        var key: String {
            switch self {
            case .tracking: "_resourceLoadStatisticsEnabled"
            case .applePay: "_applePayCapabilityDisclosureAllowed"
            case .measurement: "_privateClickMeasurementEnabled"
            case .advanced: "_networkConnectionIntegrityEnabled"
            }
        }
        var setter: String {
            switch self {
            case .tracking: "_setResourceLoadStatisticsEnabled:"
            case .applePay: "_setApplePayCapabilityDisclosureAllowed:"
            case .measurement: "_setPrivateClickMeasurementEnabled:"
            case .advanced: "_setNetworkConnectionIntegrityEnabled:"
            }
        }
    }

    static func supports(_ control: Control, on object: NSObject) -> Bool {
        object.responds(to: NSSelectorFromString(control.key))
            && object.responds(to: NSSelectorFromString(control.setter))
    }

    static func set(_ control: Control, on object: NSObject, enabled: Bool) {
        guard supports(control, on: object) else { return }
        let selector = NSSelectorFromString(control.setter)
        typealias BooleanSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(object.method(for: selector), to: BooleanSetter.self)
        setter(object, selector, enabled)
    }

    static func apply(_ settings: WebsiteSettings, to configuration: WKWebViewConfiguration) {
        set(.tracking, on: configuration.websiteDataStore, enabled: settings.preventCrossSiteTracking)
        set(.applePay, on: configuration.preferences, enabled: settings.applePayDisclosureAllowed)
        set(.measurement, on: configuration.preferences, enabled: settings.privateClickMeasurementEnabled)
        enableAdvancedProtection(configuration.defaultWebpagePreferences)
    }

    static func enableAdvancedProtection(_ preferences: WKWebpagePreferences) {
        set(.advanced, on: preferences, enabled: true)
    }
}

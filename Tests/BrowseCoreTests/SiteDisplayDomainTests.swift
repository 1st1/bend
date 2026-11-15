import Foundation
import Testing
@testable import BrowseCore

// @lat: [[lat.md/tests/web-pages-tests#Web pages tests#Site domain labels]]
@Test func siteDisplayDomainLabels() throws {
    for (host, expected) in [
        ("www.youtube.com", "youtube.com"),
        ("music.youtube.com", "youtube.com"),
        ("www.bbc.co.uk", "bbc.co.uk"),
        ("a.example.com.au", "example.com.au"),
        ("www.tenant.github.io", "tenant.github.io"),
        ("a.b.ck", "a.b.ck"),
        ("a.www.ck", "www.ck"),
        ("www.city.kawasaki.jp", "city.kawasaki.jp"),
        ("www.食狮.公司.cn", "xn--85x722f.xn--55qx5d.cn"),
        ("localhost", "localhost"),
        ("127.0.0.1", "127.0.0.1"),
        ("[::1]", "[::1]"),
        ("co.uk", "co.uk"),
        ("WWW.YOUTUBE.COM.", "youtube.com"),
        ("a.example.unknown", "example.unknown")
    ] {
        let url = try #require(URL(string: "https://\(host)/"))
        #expect(SiteDisplayDomain.label(for: url) == expected)
    }
}

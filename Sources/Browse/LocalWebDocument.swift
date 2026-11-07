import Foundation

// @lat: [[architecture#Default browser]]
enum LocalWebDocument {
    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && ["html", "htm", "xhtml", "xht"].contains(url.pathExtension.lowercased())
    }

    static func contains(_ url: URL, in directory: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

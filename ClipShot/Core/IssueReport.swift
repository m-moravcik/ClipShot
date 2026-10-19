import Foundation

/// A pre-filled GitHub issue: macOS version, app version and the last log lines, no paths.
enum IssueReport {
    static let newIssue = "https://github.com/m-moravcik/ClipShot/issues/new"
    static let logLineCount = 20

    /// Unreserved characters only (RFC 3986); everything else, `+` and `&` included, is encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func url(title: String, osVersion: String, appVersion: String, logLines: [String]) -> URL {
        let log = logLines.map(scrub).joined(separator: "\n")
        let body = """
            **What happened**


            **Environment**
            - macOS: \(osVersion)
            - ClipShot: \(appVersion)

            **Last log lines**
            ```
            \(log)
            ```
            """
        let query = [("title", title), ("body", body)]
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return URL(string: "\(newIssue)?\(query)")!
    }

    /// The last `count` lines of the log, reaching into the rolled `.1` file when the
    /// current one is shorter. Empty when there is no log.
    static func lastLines(of log: URL, count: Int = logLineCount) -> [String] {
        func lines(_ url: URL) -> [String] {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        var result = lines(log)
        if result.count < count {
            result = lines(log.appendingPathExtension("1")) + result
        }
        return Array(result.suffix(count))
    }

    /// The log never carries paths; this is a second line of defence for user and volume names.
    static func scrub(_ line: String) -> String {
        line.replacing(/\/Users\/[^\/ ]+/, with: "~")
            .replacing(/\/Volumes\/[^\/ ]+/, with: "/Volumes/-")
    }
}

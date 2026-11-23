import Foundation
import Testing

private func node(_ p: String, _ mb: Int64, _ kids: [MapNode] = [], kind: MapKind = .folder) -> MapNode {
    MapNode(path: p, name: (p as NSString).lastPathComponent, kind: kind, bytes: mb * 1_000_000, cleanable: 0, children: kids)
}

@Test func reportsUnknownFoldersWithoutTheUserName() throws {
    let resolve = node("/Users/ann/Library/Application Support/Blackmagic Design/Fusion", 4_200, [
        node("/Users/ann/Library/Application Support/Blackmagic Design/Fusion/Cache", 3_000),
        node("/Users/ann/Library/Application Support/Blackmagic Design/Fusion/Profiles", 10),
        node("/Users/ann/Library/Application Support/Blackmagic Design/Fusion/x", 5, kind: .other),
    ])
    let body = UnknownReport.body([resolve, node("/opt/thing", 900)], home: "/Users/ann", note: "  I edit video in Fusion. ",
                                  version: "0.8.0", macOS: "27.3")
    #expect(!body.contains("ann"))
    #expect(body.contains("| `~/Library/Application Support/Blackmagic Design/Fusion` | 4.2 GB | Cache 3.0 GB, Profiles 10 MB |"))
    #expect(body.contains("| `/opt/thing` | 900 MB | – |"))
    #expect(body.contains("**What I know about them:** I edit video in Fusion."))
    #expect(body.contains("Roomy 0.8.0, macOS 27.3"))
    let url = try #require(UnknownReport.url(body: body))
    #expect(url.absoluteString.hasPrefix("https://github.com/jurek-zsl/Roomy/issues/new?"))
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value == body)
}

@Test func keepsTheReportShortEnoughForALink() {
    let many = (0..<400).map { node("/Users/ann/Library/Application Support/Some Long App Name \($0)", 1_000) }
    let body = UnknownReport.body(many, home: "/Users/ann", note: "", version: "1", macOS: "27")
    #expect(body.count <= UnknownReport.maxBody)
    #expect(body.hasSuffix("**What I know about them:** Nothing yet."))
}

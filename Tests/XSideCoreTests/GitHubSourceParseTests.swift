import Testing
@testable import XSideCore

@Suite struct GitHubSourceParseTests {
    @Test(arguments: [
        "https://github.com/itzzace/ytkace",
        "https://github.com/itzzace/ytkace/",
        "https://github.com/itzzace/ytkace/releases",
        "https://github.com/itzzace/ytkace/releases/",
        "https://github.com/itzzace/ytkace/releases/tag/v1.1.8",
        "https://github.com/itzzace/ytkace.git",
        "github.com/itzzace/ytkace",
        "  https://www.github.com/itzzace/ytkace  ",
        "HTTPS://GitHub.com/itzzace/ytkace",
        "http://github.com/itzzace/ytkace",
    ])
    func accepts(_ s: String) {
        #expect(GitHubSource.parse(s) == GitHubSource(owner: "itzzace", repo: "ytkace"))
    }

    @Test(arguments: [
        "", "   ", "junk", "https://gitlab.com/itzzace/ytkace", "https://github.com/itzzace",
        "https://github.com/", "https://gist.github.com/itzzace/ytkace",
        "https://raw.githubusercontent.com/itzzace/ytkace/main/a.ipa",
        "https://github.com.evil.com/itzzace/ytkace", "https://github.com//ytkace", "https://github.com/itzzace//releases",
        "ftp://github.com/itzzace/ytkace", "https://github.com/itz zace/ytkace",
    ])
    func rejects(_ s: String) {
        #expect(GitHubSource.parse(s) == nil)
    }
}

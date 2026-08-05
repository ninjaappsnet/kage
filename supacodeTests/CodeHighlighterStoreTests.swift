import Foundation
import Testing

@testable import supacode

/// `highlightCode` is a `nonisolated` protocol witness, so MarkdownUI may call it
/// from whatever thread renders a code block, against one process-wide
/// JavaScriptCore-backed Highlightr. These pin that down: the store's lock has to
/// keep concurrent callers safe, and the theme switch inside it must stay atomic,
/// or a shared `JSContext` gets entered from two threads at once.
struct CodeHighlighterStoreTests {
  @Test nonisolated func highlightsFromManyThreadsWithoutCrashing() async {
    await withTaskGroup(of: Bool.self) { group in
      for index in 0..<64 {
        group.addTask {
          let code = "let value\(index) = \(index)"
          return CodeHighlighterStore.shared
            .attributed(code: code, language: "swift", dark: index.isMultiple(of: 2)) != nil
        }
      }
      var succeeded = 0
      for await ok in group where ok { succeeded += 1 }
      // The point is surviving the concurrency; highlighting itself must still work.
      #expect(succeeded == 64)
    }
  }

  @Test func alternatingThemesStayConsistent() {
    let store = CodeHighlighterStore.shared
    #expect(store.attributed(code: "let a = 1", language: "swift", dark: true) != nil)
    #expect(store.attributed(code: "let a = 1", language: "swift", dark: false) != nil)
  }

  @Test func unknownLanguageStillReturnsSomething() {
    let store = CodeHighlighterStore.shared
    #expect(store.attributed(code: "hello", language: "not-a-real-language", dark: false) != nil)
  }
}

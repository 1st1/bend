import AppKit
import SwiftUI
import AI
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Streaming transcript]]
@Test @MainActor func chatStreamPresentation() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIStream-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let chat = TabChat(store: store, tabID: store.selectedTab.id)
    chat.consume(.stepStart(0))
    #expect(chat.bubbles.isEmpty)
    chat.consume(.reasoningDelta("Considering the pages."))
    #expect(chat.bubbles.isEmpty)
    #expect(chat.thinkingSummary == "Considering the pages.")
    chat.consume(.reasoningDelta("\n"))
    chat.consume(.reasoningDelta("\nNext paragraph."))
    #expect(chat.thinkingSummary == "Next paragraph.")
    chat.consume(.toolCall(.init(id: "one", name: "list_panes", arguments: "{}")))
    #expect(chat.bubbles.last?.state == "Running")
    chat.consume(.toolResult(.init(callID: "one", name: "list_panes", value: .array([]))))
    #expect(chat.bubbles.last?.state == "Completed")
    chat.consume(.stepStart(1))
    #expect(chat.bubbles.count == 1)
    #expect(chat.thinkingSummary == "Next paragraph.")
    chat.consume(.reasoningDelta("Checking the result."))
    #expect(chat.thinkingSummary == "Checking the result.")
    #expect(chat.thinkingSummaryBeforeBubbleID == nil)
    chat.consume(.textDelta("Hello"))
    let responseID = chat.bubbles.last?.id
    #expect(chat.thinkingSummaryBeforeBubbleID == responseID)
    chat.consume(.textDelta(" there"))
    #expect(chat.bubbles.count == 2)
    #expect(chat.bubbles.last?.text == "Hello there")
    #expect(chat.thinkingSummaryBeforeBubbleID == responseID)
    #expect(chat.bubbles.allSatisfy { !$0.text.isEmpty })
    chat.consume(.serverToolUsage(.object(["perplexity_search": .integer(1)])))
    #expect(chat.bubbles.last?.title == "Web search")
    #expect(chat.bubbles.last?.state == "Completed")
    #expect(chat.thinkingSummaryBeforeBubbleID == responseID)
    let count = chat.bubbles.count
    chat.consume(.serverToolUsage(.integer(0)))
    chat.consume(.serverToolUsage(.object(["perplexity_search": .integer(0)])))
    #expect(chat.bubbles.count == count)
    let suite = "SearchTest-\(UUID())"
    chat.consume(.serverToolActivity(.init(id: "native", query: "Bend browser")))
    let nativeCount = chat.bubbles.count
    chat.consume(.serverToolActivity(.init(id: "native", query: "Bend browser", status: "Completed", sources: [.init(url: "https://example.com", title: "Example")])))
    #expect(chat.bubbles.count == nativeCount)
    #expect(chat.bubbles.last?.sources.first?.title == "Example")
    #expect(chat.bubbles.last?.text == "Bend browser")
    #expect(chat.bubbles.last?.argumentSummary == "Bend browser")
    chat.consume(.toolCall(.init(id: "read", name: "read_pane", arguments: "{}")))
    #expect(chat.bubbles.last?.title == "Read page")
    #expect(chat.bubbles.last?.argumentSummary == "part 1")
    chat.consume(.toolResult(.init(callID: "read", name: "read_pane", value: .string("{\"text_start\":24001,\"text_end\":48000,\"chunk\":2}"))))
    #expect(chat.bubbles.last?.argumentSummary == "Page text · characters \(24001.formatted())–\(48000.formatted())")
    let pane = store.selectedTab.pages[0]
    let args = "{\"pane\":\"\(pane.id)\",\"cursor\":\"snapshot:2\",\"selector\":\"#comment\"}"
    chat.consume(.toolCall(.init(id: "fields", name: "read_pane", arguments: args)))
    let fields = try #require(chat.bubbles.last?.argumentFields)
    #expect(fields.map(\.label) == ["Page", "Read", "Element"])
    #expect(fields.map(\.value) == ["Start page", "Part 3", "#comment"])
    #expect(chat.argumentFields("{}").isEmpty)
    #expect(chat.argumentFields("{").first?.value == "Unable to display arguments")
    #expect(chat.argumentFields("{\"pane\":\"missing\"}").first?.value == "Unavailable page")
    chat.clear()
    #expect(chat.thinkingSummary.isEmpty)
    #expect(chat.thinkingSummaryBeforeBubbleID == nil)
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AISettings(defaults: defaults)
    #expect(settings.webSearchEnabled)
    settings.webSearchEnabled = false
    #expect(!AISettings(defaults: defaults).webSearchEnabled)
}

// @lat: [[lat.md/tests/ai-tests#Model search keyboard commands]]
@Test @MainActor func modelSearchKeyboardCommands() {
    var movement = 0; var submitted = false; var dismissed = false
    let field = AIModelSearchField(text: .constant(""), move: { movement += $0 },
                                  submit: { submitted = true }, dismiss: { dismissed = true })
    let delegate = field.makeCoordinator()
    let control = NSSearchField(); let editor = NSTextView()
    #expect(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    #expect(movement == 1)
    #expect(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
    #expect(movement == 0)
    #expect(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(submitted)
    #expect(delegate.control(control, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(dismissed)
}

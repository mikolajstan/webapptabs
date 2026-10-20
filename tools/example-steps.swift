// Example test: pinned tabs at launch, a ⌘-click from a pinned tab, ⌘W on a pinned tab, a list edit.
// Run:  tools/test.sh tools/example-steps.swift https://example.com/?home tools/example-defaults.json
let steps: [(Double, @MainActor () -> Void)] = [
    (3, { log("launch:        \(bar())   widths: \(widths())")
          snap(selectedWindow(), "launch")
          App.shared.tabs.first { $0.pinned?.name == "Zadania" }?.openInNewTab(URL(string: "https://example.com/?task-1")!) }),
    (4, { log("⌘-click:       \(bar())")
          App.shared.tabs.first { $0.pinned?.name == "Zadania" }?.window?.performClose(nil) }),
    (5, { log("⌘W on pinned:  \(bar())   (pinned tab stays)")
          var pages = App.shared.pinnedPages
          pages.append(PinnedPage(name: "Raporty", url: "https://example.com/?reports", icon: "chart.bar"))
          App.shared.pinnedPages = pages }),
    (6, { log("added pinned:  \(bar())   widths: \(widths())")
          snap(selectedWindow(), "after-edit")
          NSApp.terminate(nil) }),
]

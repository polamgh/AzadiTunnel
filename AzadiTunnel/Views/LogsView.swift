import SwiftUI
import UIKit

struct LogsView: View {
    @State private var entries: [(id: Int, line: String)] = []
    @State private var showCopiedConfirmation = false

    var body: some View {
        List(entries, id: \.id) { entry in
            let line = entry.line
            Text(line)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = line
                        showCopiedConfirmation = true
                    } label: {
                        Label(L10n.t(.copyLogLine), systemImage: "doc.on.doc")
                    }
                }
        }
        .navigationTitle(L10n.t(.logsTitle))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        copyAllLogs()
                    } label: {
                        Label(L10n.t(.copyAllLogs), systemImage: "doc.on.doc")
                    }
                    Button {
                        reload()
                    } label: {
                        Label(L10n.t(.refreshLogs), systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("copy_logs_button")
            }
        }
        .onAppear { reload() }
        .alert(L10n.t(.logsCopiedTitle), isPresented: $showCopiedConfirmation) {
            Button(L10n.t(.understand), role: .cancel) {}
        }
    }

    private func reload() {
        let lines = SharedLogger.shared.allLines()
        entries = Array(lines.enumerated().map { ($0, $1) })
    }

    private func copyAllLogs() {
        UIPasteboard.general.string = SharedLogger.shared.exportText()
        showCopiedConfirmation = true
    }
}

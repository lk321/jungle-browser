import AppKit
import SwiftUI

/// ⌘F. Floats over the top of the page like the zoom badge, so opening it never moves the
/// page it is searching. Return and ⇧Return step through the matches, Escape hands the
/// keyboard back to the page.
struct FindInPageBar: View {
    @ObservedObject var find: FindInPage
    let dismiss: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Find in Page", text: $find.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                // A fixed width: a text field only given a minimum takes every point it is
                // offered, which stretched the bar across the page.
                .frame(width: 130)
                .focused($isFieldFocused)
                // One handler for Return: a key-press handler next to it could step twice.
                .onSubmit {
                    NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? find.previous() : find.next()
                }
                .onExitCommand(perform: dismiss)

            Text(statusText)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(find.status == .noMatches ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: find.status)

            Divider().frame(height: 14)

            Toggle(isOn: $find.isCaseSensitive) {
                Text("Aa").font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(find.isCaseSensitive ? "Match Case: On" : "Match Case: Off")

            Button(action: find.previous) { Image(systemName: "chevron.up") }
                .help("Previous Match (⇧⌘G)")
                .disabled(!hasMatches)
            Button(action: find.next) { Image(systemName: "chevron.down") }
                .help("Next Match (⌘G)")
                .disabled(!hasMatches)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .help("Done (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5, weight: .semibold))
        .controlSize(.small)
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        // Not a material: a material takes its colour from the page under it, so over a white
        // page dark chrome turned light grey behind white text, and light chrome dissolved into
        // the page. The window's own colour is the background the text colour was chosen for.
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.14)))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        .onAppear(perform: focusField)
        .onChange(of: find.focusRequest) { focusField() }
    }

    private var hasMatches: Bool {
        switch find.status {
        case .match, .found: true
        case .idle, .noMatches: false
        }
    }

    private var statusText: String {
        switch find.status {
        case .idle: ""
        case .noMatches: "No results"
        case .found: "Found"
        case .match(let index, let count):
            "\(index + 1) of \(count >= PageFinder.maximumMatches ? "\(PageFinder.maximumMatches)+" : "\(count)")"
        }
    }

    /// ⌘F on an open bar selects what is typed, so the next search replaces it. Only the
    /// field's own editor is asked: sent down the responder chain before focus lands, a select
    /// all reaches the page and highlights all of it.
    private func focusField() {
        isFieldFocused = true
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
            editor.selectAll(nil)
        }
    }
}

import AppKit
import SwiftUI

/// The widths the sidebar is allowed to stop at. Each step names the presentation its width can
/// actually fit, so the layout never has to guess what a raw number is supposed to look like.
enum SidebarStep: CaseIterable {
    /// Icons only. 96 is a floor from two directions: the window's traffic lights own the first
    /// ~78pt of the sidebar, and the 2x2 chrome button grid needs 68pt of content width.
    case compact
    case regular
    case full

    var width: CGFloat {
        switch self {
        case .compact: 96
        case .regular: 200
        case .full: 268
        }
    }

    /// Titles and section headers stop fitting once the rows are icon-width.
    var showsLabels: Bool { self != .compact }

    /// Anything narrower slides the profile name under the traffic lights.
    var showsProfileName: Bool { self == .full }

    var quickAccessColumns: Int {
        switch self {
        case .compact: 1
        case .regular: 2
        case .full: 3
        }
    }

    /// Dragging this far inside the narrowest step reads as "get out of the way", not
    /// "make it smaller".
    static let hideThreshold: CGFloat = SidebarStep.compact.width - 26

    static func nearest(to width: CGFloat) -> SidebarStep {
        allCases.min(by: { abs($0.width - width) < abs($1.width - width) }) ?? .full
    }

    static func resolve(draggedWidth: CGFloat) -> SidebarWidthChange {
        draggedWidth < hideThreshold ? .hidden : .snapped(nearest(to: draggedWidth))
    }
}

enum SidebarWidthChange: Equatable {
    case hidden
    case snapped(SidebarStep)
}

/// Drops the title below the step that can fit it, keeping the icon and the accessible name the
/// `Label` already carries.
struct SidebarLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}

private struct SidebarStepKey: EnvironmentKey {
    static let defaultValue = SidebarStep.full
}

extension EnvironmentValues {
    var sidebarStep: SidebarStep {
        get { self[SidebarStepKey.self] }
        set { self[SidebarStepKey.self] = newValue }
    }
}

/// The sidebar's trailing edge. Snapping happens while the pointer moves, not on release, so the
/// sidebar is never parked at a width its contents were not designed for.
struct SidebarResizeHandle: View {
    @ObservedObject var store: BrowserStore

    @State private var isHovering = false

    var body: some View {
        // A clear fill is invisible to the window server once the window stops being opaque,
        // and a pointer press over it falls straight through to the desktop. The wash is
        // barely there to the eye and is what keeps the grab area grabbable; the hairline
        // only firms up under the pointer, so the edge is a hint at rest and a handle on hover.
        Rectangle()
            .fill(Color.primary.opacity(isHovering ? 0.06 : 0.02))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(isHovering ? 0.18 : 0.05))
                    .frame(width: 1)
            }
            .frame(width: 8)
            .contentShape(Rectangle())
            // A cursor rect, not a hover callback: `NSCursor.set()` is undone by the next
            // mouse-moved event, which is why the resize cursor only showed sometimes.
            .pointerStyle(.frameResize(position: .trailing))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .gesture(
                // The handle itself moves the moment the sidebar snaps, so a translation measured
                // in its own space would feed the next frame a width the pointer never asked for.
                // The window's leading edge is global x = 0, so the pointer's x is the width.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { snap(to: $0.location.x) }
            )
            .accessibilityLabel("Resize sidebar")
            .accessibilityHint("Drag to resize, or past the narrowest width to hide")
    }

    private func snap(to pointerX: CGFloat) {
        let change = SidebarStep.resolve(draggedWidth: pointerX)
        // Every pointer frame resolves to the same step. Only the crossings are worth a spring
        // and a write to disk.
        guard change != .snapped(SidebarStep.nearest(to: store.settings.sidebarWidth)) else { return }
        withAnimation(.spring(duration: 0.26, bounce: 0.18)) {
            switch change {
            case .hidden:
                store.isSidebarVisible = false
            case .snapped(let step):
                store.settings.sidebarWidth = step.width
            }
        }
    }
}

/// macOS sidebars are a behind-window `.sidebar` material, not an in-window blur: this is the only
/// one that samples the desktop under the window the way Finder and Mail do.
struct SidebarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
    }
}

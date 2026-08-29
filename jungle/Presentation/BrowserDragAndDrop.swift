import SwiftUI

struct BrowserDragPayload: Equatable {
    enum Kind: Equatable {
        case tab
        case bookmark
    }

    let kind: Kind
    let id: UUID
    let folderID: UUID?

    static func tab(_ id: UUID) -> BrowserDragPayload {
        BrowserDragPayload(kind: .tab, id: id, folderID: nil)
    }

    static func bookmark(_ id: UUID, folderID: UUID) -> BrowserDragPayload {
        BrowserDragPayload(kind: .bookmark, id: id, folderID: folderID)
    }
}

enum SidebarDropTarget: Hashable {
    case tab(UUID)
    case tabEnd(isPinned: Bool)
    case bookmark(bookmarkID: UUID, folderID: UUID)
    case folder(UUID)
    case quickAccess(UUID)
    case removal
}

enum SidebarDragSpace {
    static let name = "jungle-sidebar-drag-space"
}

struct SidebarDropTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [SidebarDropTarget: CGRect] = [:]

    static func reduce(
        value: inout [SidebarDropTarget: CGRect],
        nextValue: () -> [SidebarDropTarget: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func sidebarDropTarget(_ target: SidebarDropTarget) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarDropTargetPreferenceKey.self,
                    value: [target: proxy.frame(in: .named(SidebarDragSpace.name))]
                )
            }
        }
    }

    func sidebarDragGesture(
        payload: BrowserDragPayload,
        source: SidebarDropTarget,
        began: @escaping (BrowserDragPayload) -> Void,
        changed: @escaping (SidebarDropTarget, CGPoint) -> Void,
        ended: @escaping (SidebarDropTarget, CGPoint) -> Void
    ) -> some View {
        highPriorityGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    began(payload)
                    changed(source, value.location)
                }
                .onEnded { value in
                    ended(source, value.location)
                }
        )
    }
}

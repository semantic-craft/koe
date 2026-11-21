import KoeAppleCore
import SwiftUI

enum IOSModeWorkspaceRoute: Hashable {
    case quickNote
    case allDay
    case liveMinutes

    var title: String {
        switch self {
        case .quickNote: CaptureMode.quickNote.title
        case .allDay: CaptureMode.allDay.title
        case .liveMinutes: CaptureMode.meeting.title
        }
    }
}

struct IOSModeWorkspacesView: View {
    let store: HostSessionStore
    let route: IOSModeWorkspaceRoute
    let onSelectRecord: (String) -> Void
    let onOpenSource: (SourceSnapshot) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch route {
                case .quickNote:
                    IOSQuickNoteWorkspaceView(store: store, onSelectRecord: onSelectRecord, onOpenSource: onOpenSource)
                case .allDay:
                    IOSAllDayWorkspaceView(store: store, onSelectRecord: onSelectRecord, onOpenSource: onOpenSource)
                case .liveMinutes:
                    IOSLiveMinutesWorkspaceView(store: store, onSelectRecord: onSelectRecord, onOpenSource: onOpenSource)
                }
            }
            .frame(maxWidth: route == .liveMinutes ? 1200 : 760)
            .padding(16)
        }
        .background(IOSColors.bgPanel)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

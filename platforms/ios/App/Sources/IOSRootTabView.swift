import KoeAppleCore
import SwiftUI

enum IOSAppTab: Hashable {
    case today
    case records
    case actions
    case ask
}

enum IOSDetailRoute: Hashable {
    case record(String)
    case workspace(IOSModeWorkspaceRoute)
}

struct IOSRootTabView: View {
    let store: HostSessionStore

    @State private var selectedTab: IOSAppTab = .today
    @State private var todayPath: [IOSDetailRoute] = []
    @State private var recordsPath: [IOSDetailRoute] = []
    @State private var actionsPath: [IOSDetailRoute] = []
    @State private var askPath: [IOSDetailRoute] = []
    @State private var dismissedNotice: String?
    @State private var showingDeviceSheet = false
    @State private var showingSettingsSheet = false

    private var tabSelection: Binding<IOSAppTab> {
        Binding(
            get: { selectedTab },
            set: { nextTab in
                if nextTab == selectedTab {
                    popToRoot(for: nextTab)
                } else {
                    selectedTab = nextTab
                }
            }
        )
    }

    var body: some View {
        GeometryReader { viewport in
            tabs.environment(\.iosViewportHeight, viewport.size.height)
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            tabNavigationStack(path: $todayPath) {
                IOSTodayView(
                    store: store,
                    onOpenWorkspace: { route in
                        todayPath.append(IOSDetailRoute.workspace(route))
                    }
                )
            }
            .tabItem {
                Label("今天", systemImage: "square.grid.2x2")
                .accessibilityIdentifier("tab-today")
            }
            .tag(IOSAppTab.today)

            tabNavigationStack(path: $recordsPath) {
                IOSRecordsView(
                    store: store,
                    onSelectRecord: { recordId in
                        openRecordInCurrentTab(recordId)
                    }
                )
            }
            .tabItem {
                Label("记录", systemImage: "tray.full")
                .accessibilityIdentifier("tab-records")
            }
            .tag(IOSAppTab.records)

            tabNavigationStack(path: $actionsPath) {
                IOSActionsView(
                    store: store,
                    onOpenSource: { source in
                        openSource(source)
                    }
                )
            }
            .tabItem {
                Label("行动", systemImage: "checklist")
                .accessibilityIdentifier("tab-actions")
            }
            .tag(IOSAppTab.actions)

            tabNavigationStack(path: $askPath) {
                IOSAskView(
                    store: store,
                    onOpenSource: { source in
                        openSource(source)
                    }
                )
            }
            .tabItem {
                Label("问 AI", systemImage: "bubble.left.and.text.bubble.right")
                .accessibilityIdentifier("tab-ask")
            }
            .tag(IOSAppTab.ask)
        }
        .onChange(of: store.navigation.notice) { dismissedNotice = nil }
        .tint(IOSColors.accent)
        .sheet(isPresented: $showingDeviceSheet) {
            IOSDeviceSheetView(store: store, onOpenRecord: openRecordInCurrentTab)
        }
        .sheet(isPresented: $showingSettingsSheet) {
            IOSSettingsView(store: store)
        }
    }

    @ViewBuilder
    private func tabNavigationStack<Content: View>(
        path: Binding<[IOSDetailRoute]>,
        @ViewBuilder root: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            NavigationStack(path: path) {
                root()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 8) {
                                deviceStatusPill
                                settingsButton
                            }
                        }
                    }
                    .navigationDestination(for: IOSDetailRoute.self) { route in
                        switch route {
                        case .record(let recordId):
                            IOSRecordDetailView(store: store, recordId: recordId, onOpenRelatedSource: openSource, onAsk: {
                                askPath.removeAll()
                                selectedTab = .ask
                            })
                        case .workspace(let modeRoute):
                            IOSModeWorkspacesView(
                                store: store,
                                route: modeRoute,
                                onSelectRecord: openRecordInCurrentTab,
                                onOpenSource: openSource
                            )
                        }
                    }
            }
            dockedOverlayStack(route: path.wrappedValue.last)
        }
    }

    private var deviceStatusPill: some View {
        let device = store.device
        let isReleased = store.today.beanControlState == "released"
        let pillLabel: String = {
            if isReleased { return "录音豆 已让出" }
            if device.connected, let battery = device.batteryPercent {
                return "录音豆 \(battery)%"
            }
            if device.connected { return "录音豆 已连接" }
            return "录音豆"
        }()
        let dotColor: Color = {
            if isReleased { return IOSColors.textMuted }
            if device.connected { return IOSColors.success }
            return device.phase == "disconnected" ? IOSColors.textMuted : IOSColors.warning
        }()

        return Button {
            showingDeviceSheet = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(pillLabel)
                    .font(.system(size: AppFontSizes.xs, weight: .semibold))
                    .foregroundStyle(IOSColors.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(IOSColors.bgSubtle, in: Capsule())
            .overlay(Capsule().stroke(IOSColors.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("device-status-pill")
        .accessibilityLabel(pillLabel)
    }

    private var settingsButton: some View {
        Button {
            showingSettingsSheet = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: AppFontSizes.sm, weight: .medium))
                .foregroundStyle(IOSColors.textPrimary)
                .frame(width: 32, height: 32)
                .background(IOSColors.bgSubtle, in: Circle())
                .overlay(Circle().stroke(IOSColors.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-button")
        .accessibilityLabel("设置")
    }

    private func dockedOverlayStack(route: IOSDetailRoute?) -> some View {
        VStack(spacing: 8) {
            IOSHostErrorBar(store: store)
            if let notice = store.navigation.notice, !notice.isEmpty, notice != dismissedNotice {
                HStack {
                    Text(notice)
                        .font(.system(size: AppFontSizes.xs))
                        .lineLimit(2)
                    Spacer()
                    Button("关闭提示", systemImage: "xmark") { dismissedNotice = notice }
                        .labelStyle(.iconOnly)
                }
                .padding(10)
                .background(IOSColors.surface1, in: RoundedRectangle(cornerRadius: IOSRadii.card))
            }
            IOSMiniPlayerBar(store: store, visibleRoute: route, openRecord: openRecordInCurrentTab)
            IOSLiveCaptionBar(store: store) { recordId in
                openRecordInCurrentTab(recordId)
            }
            IOSActiveCaptureBar(store: store)
            IOSUndoTrashBar(store: store)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .iosChromeSurface()
    }

    private func popToRoot(for tab: IOSAppTab) {
        switch tab {
        case .today: todayPath = []
        case .records: recordsPath = []
        case .actions: actionsPath = []
        case .ask: askPath = []
        }
    }

    private func openRecordInCurrentTab(_ recordId: String) {
        store.send(.selectRecord(recordId: recordId))
        switch selectedTab {
        case .today: todayPath.append(IOSDetailRoute.record(recordId))
        case .records: recordsPath.append(IOSDetailRoute.record(recordId))
        case .actions: actionsPath.append(IOSDetailRoute.record(recordId))
        case .ask: askPath.append(IOSDetailRoute.record(recordId))
        }
    }

    private func openSource(_ source: SourceSnapshot) {
        store.send(.openSource(recordId: source.recordId, segmentId: source.segmentId))
        switch selectedTab {
        case .today: todayPath.append(IOSDetailRoute.record(source.recordId))
        case .records: recordsPath.append(IOSDetailRoute.record(source.recordId))
        case .actions: actionsPath.append(IOSDetailRoute.record(source.recordId))
        case .ask: askPath.append(IOSDetailRoute.record(source.recordId))
        }
    }
}

private struct IOSUndoTrashBar: View {
    let store: HostSessionStore

    var body: some View {
        if let undo = store.navigation.undoTrash {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textSecondary)
                Text("已移入回收站  \(undo.title)")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                IOSPrimaryButton("撤销", isPrimary: true) {
                    let ids = undo.effectiveRecordIds
                    if ids.count > 1 {
                        store.send(.batchRestoreRecords(recordIds: ids))
                    } else {
                        store.send(.restoreRecord(recordId: undo.recordId))
                    }
                }
                .accessibilityIdentifier("trash-undo")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(IOSColors.surface1, in: RoundedRectangle(cornerRadius: IOSRadii.card))
            .overlay(
                RoundedRectangle(cornerRadius: IOSRadii.card)
                    .stroke(IOSColors.border, lineWidth: 1)
            )
            .task(id: undo.recordId) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                if store.navigation.undoTrash?.recordId == undo.recordId {
                    store.send(.dismissUndoTrash)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("undo-trash-bar")
        }
    }
}

struct IOSHostErrorBar: View {
    let store: HostSessionStore
    var identifier = "host-error"

    var body: some View {
        if let errorMessage = store.navigation.effectiveError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.danger)
                Text(errorMessage)
                    .accessibilityIdentifier(identifier)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                IOSPrimaryButton("知道了", isPrimary: false) {
                    store.clearError()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(IOSColors.surface1, in: RoundedRectangle(cornerRadius: IOSRadii.card))
            .overlay(
                RoundedRectangle(cornerRadius: IOSRadii.card)
                    .stroke(IOSColors.danger.opacity(0.4), lineWidth: 1)
            )
        }
    }
}

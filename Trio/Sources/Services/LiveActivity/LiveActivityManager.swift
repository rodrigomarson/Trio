import ActivityKit
import Combine
import CoreData
import Foundation
import Swinject
import UIKit

@available(iOS 16.2, *) enum LiveActivityExistingSessionAction: Equatable {
    case update
    case recreate
    case waitForForeground
}

@available(iOS 16.2, *) enum LiveActivityUpdatePolicy {
    static let freshnessWindow: TimeInterval = 12 * 60
    static let maximumActivityAge: TimeInterval = 7 * 60 * 60

    static func staleDate(now: Date = .now) -> Date {
        now.addingTimeInterval(freshnessWindow)
    }

    static func existingSessionAction(
        activityState: ActivityState,
        startDate: Date,
        isAppActive: Bool,
        now: Date = .now
    ) -> LiveActivityExistingSessionAction {
        switch activityState {
        case .dismissed,
             .ended:
            return isAppActive ? .recreate : .waitForForeground
        case .active,
             .pending,
             .stale:
            break
        @unknown default:
            return isAppActive ? .recreate : .waitForForeground
        }

        if now.timeIntervalSince(startDate) > maximumActivityAge, isAppActive {
            return .recreate
        }

        // ActivityKit can continue accepting updates for an old or stale session.
        // Keep it alive in the background because requesting a replacement there is
        // unreliable and otherwise creates a several-hour gap until Trio is opened.
        return .update
    }
}

@available(iOS 16.2, *) private struct ActiveActivity {
    let activity: Activity<LiveActivityAttributes>

    func action(isAppActive: Bool, now: Date = .now) -> LiveActivityExistingSessionAction {
        LiveActivityUpdatePolicy.existingSessionAction(
            activityState: activity.activityState,
            startDate: activity.attributes.startDate,
            isAppActive: isAppActive,
            now: now
        )
    }
}

final class LiveActivityData: ObservableObject {
    /// Determination data used to update live activity state.
    @Published var determination: DeterminationData?
    /// The most recent IoB data
    @Published var iob: Decimal?
    /// Array of glucose readings fetched from persistent storage.
    @Published var glucoseFromPersistence: [GlucoseData]?
    /// The current override data (if any).
    @Published var override: OverrideData?
    /// The current temp target data (if any).
    @Published var tempTarget: TempTargetData?
    /// The widget items displayed within the live activity.
    @Published var widgetItems: [LiveActivityAttributes.LiveActivityItem]?
}

/// A service managing live activity updates and state management.
///
/// This class handles the creation, update, and termination of live activities based on various data sources
/// (e.g. Core Data notifications, glucose updates, settings changes). It integrates with system notifications,
/// dependency injection, and user defaults to ensure that the live activity reflects the current app state.
///
/// Additionally, it supports a restart functionality (via `restartActivityFromLiveActivityIntent()`)
/// via iOS shortcuts, similar to other iOS apps like xDrip4iOS or Sweet Dreams.
@available(iOS 16.2, *) final class LiveActivityManager: Injectable, ObservableObject, SettingsObserver {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var iobService: IOBService!

    private let activityAuthorizationInfo = ActivityAuthorizationInfo()
    /// Indicates whether system live activities are enabled.
    @Published private(set) var systemEnabled: Bool

    /// Returns the current Trio settings.
    private var settings: TrioSettings {
        settingsManager.settings
    }

    /// The current active live activity.
    private var currentActivity: ActiveActivity?

    private var data = LiveActivityData()

    /// The last state successfully delivered to ActivityKit.
    ///
    /// Several pieces of a loop result arrive independently (glucose, determination,
    /// IOB, overrides, and temp targets). Keeping the last complete state prevents
    /// identical ActivityKit updates when more than one publisher reports the same
    /// logical change.
    @MainActor private var lastPushedContent: LiveActivityAttributes.ContentState?

    /// Coalesces notifications that arrive while an ActivityKit operation is in progress.
    @MainActor private var pendingContent: LiveActivityAttributes.ContentState?
    @MainActor private var pendingForce = false
    @MainActor private var isProcessingUpdate = false

    /// A Core Data task context.
    let context = CoreDataStack.shared.newTaskContext()
    /// A dispatch queue for handling Core Data change notifications.
    private let queue = DispatchQueue(label: "LiveActivityBridge.queue", qos: .userInitiated)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Initializes a new instance of `LiveActivityBridge` and sets up observers, subscribers, and notifications.
    ///
    /// - Parameter resolver: The dependency injection resolver.
    init(resolver: Resolver) {
        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        systemEnabled = activityAuthorizationInfo.areActivitiesEnabled
        injectServices(resolver)
        setupNotifications()
        registerHandler()
        monitorForLiveActivityAuthorizationChanges()
        broadcaster.register(SettingsObserver.self, observer: self)
        data.objectWillChange
            .debounce(for: .seconds(12), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor in
                    // By the time the debounce fires, all related loop data has
                    // normally arrived and the published values have been updated.
                    await self?.pushCurrentContent()
                }
            }
            .store(in: &subscriptions)
        loadInitialData()
    }

    /// Sets up application notifications that trigger live activity updates when the app state changes.
    private func setupNotifications() {
        let notificationCenter = Foundation.NotificationCenter.default
        notificationCenter
            .addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    await self?.pushCurrentContent()
                }
            }
        notificationCenter
            .addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    // Force a reconciliation with ActivityKit. The system may have
                    // ended the session while Trio was suspended even when glucose
                    // content itself did not change.
                    await self?.pushCurrentContent(force: true)
                }
            }
        notificationCenter.addObserver(
            self,
            selector: #selector(loadWidgetItems),
            name: .liveActivityOrderDidChange,
            object: nil
        )
    }

    /// Called when the app settings change.
    ///
    /// This method triggers an update to the live activity content state based on the new settings.
    /// - Parameter _: The updated `TrioSettings`.
    func settingsDidChange(_: TrioSettings) {
        Task { @MainActor in
            await self.pushCurrentContent(force: true)
        }
    }

    /// Registers handlers for Core Data changes related to overrides, glucose readings, and determinations.
    private func registerHandler() {
        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            Task { await self?.loadOverrides() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            Task { await self?.loadTempTarget() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            Task { await self?.loadGlucose() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OrefDetermination")
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                Task { await self?.loadDetermination() }
            }.store(in: &subscriptions)

        iobService.iobPublisher
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.data.iob = self?.iobService.currentIOB
            }.store(in: &subscriptions)
    }

    /// Fetches and maps new determination data and updates the live activity content state.
    private func loadDetermination() async {
        do {
            data.determination = try await fetchAndMapDetermination()
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map determination: \(error)"
            )
        }
    }

    /// Fetches and maps override data and updates the live activity content state.
    private func loadOverrides() async {
        do {
            data.override = try await fetchAndMapOverride()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map override: \(error)")
        }
    }

    /// Fetches and maps temp target data and updates the live activity content state.
    private func loadTempTarget() async {
        do {
            data.tempTarget = try await fetchAndMapTempTarget()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map temp target: \(error)")
        }
    }

    /// Handles changes to the live activity order.
    ///
    /// Loads widget items from user defaults and triggers an update to the live activity order.
    @objc private func loadWidgetItems() {
        data.widgetItems = UserDefaults.standard.loadLiveActivityOrderFromUserDefaults() ?? LiveActivityAttributes
            .LiveActivityItem.defaultItems
    }

    /// Sets up the array of glucose data from persistent storage and triggers an update to the live activity.
    private func loadGlucose() async {
        do {
            data.glucoseFromPersistence = try await fetchAndMapGlucose()
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch glucose with error: \(error)"
            )
        }
    }

    private func loadInitialData() {
        Task {
            await self.loadGlucose()
            await self.loadOverrides()
            await self.loadTempTarget()
            await self.loadDetermination()
            self.loadWidgetItems()
        }
    }

    /// Monitors live activity authorization changes and updates the `systemEnabled` flag.
    private func monitorForLiveActivityAuthorizationChanges() {
        Task {
            for await activityState in activityAuthorizationInfo.activityEnablementUpdates {
                if activityState != systemEnabled {
                    await MainActor.run {
                        systemEnabled = activityState
                    }
                    await pushCurrentContent(force: true)
                }
            }
        }
    }

    /// Pushes an update to the live activity with the specified content state.
    ///
    /// If an existing activity requires recreation or is outdated, this method ends it and starts a new one.
    /// Otherwise, it updates the current live activity.
    ///
    /// - Parameter state: The new content state to push to the live activity.
    @MainActor private func pushUpdate(_ state: LiveActivityAttributes.ContentState) async -> Bool {
        if !settings.useLiveActivity || !systemEnabled {
            if currentActivity != nil || !Activity<LiveActivityAttributes>.activities.isEmpty {
                await endActivity()
            } else {
                lastPushedContent = nil
            }
            return false
        }

        if currentActivity == nil {
            // try to restore an existing activity
            currentActivity = Activity<LiveActivityAttributes>.activities
                .max { $0.attributes.startDate < $1.attributes.startDate }.map {
                    ActiveActivity(activity: $0)
                }

            if let currentActivity {
                debug(.default, "[LiveActivityManager] Restored live activity: \(currentActivity.activity.id)")
            }
        }

        let unknownActivities = Activity<LiveActivityAttributes>.activities
            .filter { self.currentActivity?.activity.id != $0.id }
        if !unknownActivities.isEmpty {
            debug(.default, "[LiveActivityManager] Ending \(unknownActivities.count) duplicate live activity instance(s).")
        }
        for unknownActivity in unknownActivities {
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        if let currentActivity {
            let isAppActive = UIApplication.shared.applicationState == .active
            switch currentActivity.action(isAppActive: isAppActive) {
            case .recreate:
                debug(.default, "[LiveActivityManager] Ending current activity for recreation: \(currentActivity.activity.id)")
                await endActivity()
            case .waitForForeground:
                // Activity creation is unreliable while Trio is in the background.
                // didBecomeActive performs a forced reconciliation.
                return false
            case .update:
                let content = ActivityContent(
                    state: state,
                    staleDate: LiveActivityUpdatePolicy.staleDate()
                )
                // Before the update, check if currentActivity is still valid
                if let stillCurrent = self.currentActivity, stillCurrent.activity.id == currentActivity.activity.id {
                    await stillCurrent.activity.update(content)
                    return true
                } else {
                    debug(.default, "[LiveActivityManager] Skipped update: currentActivity changed during pushUpdate.")
                    return false
                }
            }
        }

        guard UIApplication.shared.applicationState == .active else {
            return false
        }

        do {
            // Request with real glucose content. Creating an expired placeholder
            // and immediately replacing it is racy and can leave that placeholder visible.
            let now = Date.now
            let content = ActivityContent(
                state: state,
                staleDate: LiveActivityUpdatePolicy.staleDate(now: now)
            )
            let activity = try Activity.request(
                attributes: LiveActivityAttributes(startDate: now),
                content: content,
                pushType: nil
            )
            currentActivity = ActiveActivity(activity: activity)
            debug(.default, "[LiveActivityManager] Created new activity with current glucose content: \(activity.id)")
            return true
        } catch {
            debug(
                .default,
                "[LiveActivityManager]: Error creating new activity: \(error)"
            )
            currentActivity = nil
            return false
        }
    }

    /// Ends the current live activity and ensures that all unknown activities are terminated.
    @MainActor private func endActivity() async {
        let activityID = currentActivity?.activity.id
        let unknownActivities = Activity<LiveActivityAttributes>.activities
            .filter { $0.id != activityID }

        guard currentActivity != nil || !unknownActivities.isEmpty else {
            lastPushedContent = nil
            return
        }

        debug(.default, "[LiveActivityManager] Ending live activity session.")

        if let currentActivity {
            await currentActivity.activity.end(nil, dismissalPolicy: .immediate)
            self.currentActivity = nil
        }
        lastPushedContent = nil

        for unknownActivity in unknownActivities {
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Restarts the live activity from a Live Activity Intent.
    ///
    /// This method mimics xdrip's `restartActivityFromLiveActivityIntent()` behavior by verifying that a valid content state
    /// exists,
    /// ending the current live activity, and starting a new one using the current state.
    @MainActor func restartActivityFromLiveActivityIntent() async {
        await endActivity()

        while (currentActivity != nil && currentActivity!.activity.activityState != .ended) || Activity<LiveActivityAttributes>
            .activities.contains(where: { $0.activityState != .ended })
        {
            debug(.default, "[LiveActivityManager] Waiting for Live Activity to end...")
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s sleep
        }

        // Add additional delay to ensure iOS has fully cleaned up the previous activity
        debug(.default, "[LiveActivityManager] Waiting additional time for iOS to clean up...")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s additional delay

        await pushCurrentContent(force: true)

        debug(.default, "[LiveActivityManager] Restarted Live Activity from LiveActivityIntent (via iOS Shortcut)")
    }
}

@available(iOS 16.2, *) extension LiveActivityManager {
    @MainActor func pushCurrentContent(force: Bool = false) async {
        if !settings.useLiveActivity || !systemEnabled {
            pendingContent = nil
            pendingForce = false
            if currentActivity != nil || !Activity<LiveActivityAttributes>.activities.isEmpty {
                await endActivity()
            } else {
                lastPushedContent = nil
            }
            return
        }

        guard let glucose = data.glucoseFromPersistence, let bg = glucose.first else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no current glucose data available")
            return
        }
        let prevGlucose = data.glucoseFromPersistence?.dropFirst().first

        let rawContent = LiveActivityAttributes.ContentState(
            new: bg,
            prev: prevGlucose,
            units: settings.units,
            chart: glucose,
            settings: settings,
            determination: data.determination,
            iob: data.iob,
            override: data.override,
            tempTarget: data.tempTarget,
            widgetItems: data.widgetItems
        )
        let content = LiveActivityPayloadPolicy.contentFittingActivityKitBudget(rawContent)

        let rawSize = LiveActivityPayloadPolicy.encodedSize(of: rawContent)
        if rawSize != LiveActivityPayloadPolicy.encodedSize(of: content) {
            debug(
                .default,
                "[LiveActivityManager] Compacted content state from \(rawSize) to \(LiveActivityPayloadPolicy.encodedSize(of: content)) bytes"
            )
        }

        pendingContent = content
        pendingForce = pendingForce || force

        guard !isProcessingUpdate else {
            return
        }

        isProcessingUpdate = true
        defer { isProcessingUpdate = false }

        while let nextContent = pendingContent {
            let nextForce = pendingForce
            pendingContent = nil
            pendingForce = false

            if !nextForce, nextContent == lastPushedContent {
                continue
            }

            if await pushUpdate(nextContent) {
                lastPushedContent = nextContent
            }
        }
    }
}

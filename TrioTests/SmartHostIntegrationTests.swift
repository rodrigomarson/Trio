import Foundation
import SmartCGMKit
import Testing
@testable import Trio
import UserNotifications

@Suite("Smart Host Integration") struct SmartHostIntegrationTests {
    @Test("Alarm snooze preserves future Smart reminders and critical alarms") func preservesSensorReminders() {
        let content = UNMutableNotificationContent()
        let reminder = UNNotificationRequest(
            identifier: "Trio.Smart.replacement.reminder.sensor.expires-in-24-hours",
            content: content, trigger: nil
        )
        #expect(!SensorReminderNotificationPolicy.shouldRemoveForSnooze(reminder))
        let ordinary = UNNotificationRequest(identifier: "ordinary", content: content, trigger: nil)
        #expect(SensorReminderNotificationPolicy.shouldRemoveForSnooze(ordinary))
        content.interruptionLevel = .critical
        let critical = UNNotificationRequest(identifier: "critical", content: content, trigger: nil)
        #expect(!SensorReminderNotificationPolicy.shouldRemoveForSnooze(critical))
    }

    @Test("Keeps production heartbeat fallback enabled for Smart") func keepsSmartHeartbeatFallback() {
        let manager = SmartCGMManager(peripheralIdentifier: UUID())
        #expect(!manager.providesBLEHeartbeat)
        #expect(
            CGMTimerFetchPolicy.shouldFetch(
                pluginIdentifier: manager.pluginIdentifier,
                providesBLEHeartbeat: manager.providesBLEHeartbeat
            )
        )
    }

    @Test("Skips the redundant timer fetch only for passive Smart delivery") func skipsSmartTimerFetch() {
        #expect(
            !CGMTimerFetchPolicy.shouldFetch(
                pluginIdentifier: SmartCGMManager.pluginIdentifier,
                providesBLEHeartbeat: true
            )
        )
        #expect(
            CGMTimerFetchPolicy.shouldFetch(
                pluginIdentifier: SmartCGMManager.pluginIdentifier,
                providesBLEHeartbeat: false
            )
        )
        #expect(
            CGMTimerFetchPolicy.shouldFetch(
                pluginIdentifier: "AnotherCGM",
                providesBLEHeartbeat: true
            )
        )
    }

    @Test("Maps Smart lifecycle states into Trio's deduplicated sensor-state log") func mapsSmartSensorObservations() {
        #expect(SmartSensorObservation.reliable.cgmSensorObservation == .reliable)
        #expect(SmartSensorObservation.unavailable.cgmSensorObservation == .unavailable)
        #expect(
            SmartSensorObservation.unreliable(.warmup).cgmSensorObservation ==
                .unreliable(state: "smartWarmup")
        )
        #expect(
            SmartSensorObservation.unreliable(.replacementNoSignal).cgmSensorObservation ==
                .unreliable(state: "smartReplacementNoSignal")
        )
    }
}

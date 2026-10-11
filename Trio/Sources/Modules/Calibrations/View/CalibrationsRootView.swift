import SmartCGMKitUI
import SwiftUI
import Swinject

extension Calibrations {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @State private var shouldConfirmCalibration = false

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            return formatter
        }

        private var manualGlucoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mgdL {
                formatter.maximumIntegerDigits = 3
                formatter.maximumFractionDigits = 0
            } else {
                formatter.maximumIntegerDigits = 2
                formatter.minimumFractionDigits = 0
                formatter.maximumFractionDigits = 1
            }
            formatter.roundingMode = .halfUp
            return formatter
        }

        private var dateFormatter: DateFormatter {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .short
            return formatter
        }

        var body: some View {
            GeometryReader { geo in
                Form {
                    Section(
                        header: Text("Add Calibration"),
                        footer: Text(
                            "Calibration changes the glucose readings used by the algorithm. Use a fingerstick taken at the same time and only when the trend is stable."
                        )
                    ) {
                        if state.isSmartCGM {
                            SmartCalibrationStatusView(
                                glucose: formattedSensorGlucose,
                                timestamp: state.sensorGlucoseDate.map(dateFormatter.string) ?? "–",
                                trend: formattedTrendRate,
                                readinessMessage: state.calibrationReadinessMessage,
                                refresh: state.refreshCalibrationCandidate
                            )
                        }

                        HStack {
                            Text("Fingerstick Glucose")
                            Spacer()
                            TextFieldWithToolBar(
                                text: $state.newCalibration,
                                placeholder: "0",
                                numberFormatter: manualGlucoseFormatter,
                                unitsText: state.units.rawValue
                            )
                        }
                        Button {
                            shouldConfirmCalibration = true
                        }
                        label: { Text("Record Calibration") }
                            .disabled(!state.canAddCalibration)

                        if let message = state.lastActionMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }.listRowBackground(Color.chart)

                    Section(header: Text("Current Adjustment")) {
                        HStack {
                            Text("Slope")
                            Spacer()
                            Text(formatter.string(from: state.slope as NSNumber)!)
                        }
                        HStack {
                            Text("Intercept")
                            Spacer()
                            Text(formatter.string(from: state.intercept as NSNumber)!)
                        }
                    }.listRowBackground(Color.chart)

                    Section(header: Text("Remove Calibrations")) {
                        Button {
                            state.removeLast()
                        }
                        label: { Text("Remove Last") }
                            .disabled(state.calibrations.isEmpty)

                        Button {
                            state.removeAll()
                        }
                        label: { Text("Remove All") }
                            .disabled(state.calibrations.isEmpty)
                        List {
                            ForEach(state.items) { item in
                                HStack {
                                    Text(dateFormatter.string(from: item.calibration.date))
                                    Spacer()
                                    VStack(alignment: .leading) {
                                        Text("raw: \(item.calibration.x)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text("value: \(item.calibration.y)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }

                            }.onDelete(perform: delete)
                        }
                    }.listRowBackground(Color.chart)

                    if state.calibrations.isNotEmpty {
                        Section(header: Text("Chart")) {
                            CalibrationsChart(state: state)
                                .frame(minHeight: geo.size.width)
                        }.listRowBackground(Color.chart)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .onAppear(perform: configureView)
            .confirmationDialog(
                "Apply This Calibration?",
                isPresented: $shouldConfirmCalibration,
                titleVisibility: .visible
            ) {
                Button("Confirm Calibration") {
                    Task {
                        await state.addCalibration()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Future glucose readings received by Trio will be adjusted and may influence treatment."
                )
            }
            .navigationTitle("Calibrations")
            .navigationBarItems(trailing: EditButton().disabled(state.calibrations.isEmpty))
            .navigationBarTitleDisplayMode(.automatic)
        }

        private func delete(at offsets: IndexSet) {
            state.removeAtIndex(offsets[offsets.startIndex])
        }

        private var formattedSensorGlucose: String {
            guard let glucose = state.sensorGlucose else { return "–" }
            if state.units == .mgdL {
                return "\(Int(glucose.rounded())) \(state.units.rawValue)"
            }
            return "\(Decimal(glucose).formattedAsMmolL) \(state.units.rawValue)"
        }

        private var formattedTrendRate: String {
            guard let rate = state.sensorTrendRate else { return "–" }
            if state.units == .mgdL {
                return "\(String(format: "%.1f", rate)) mg/dL/min"
            }
            let converted = Decimal(rate).asMmolL
            return "\(converted) mmol/L/min"
        }
    }
}

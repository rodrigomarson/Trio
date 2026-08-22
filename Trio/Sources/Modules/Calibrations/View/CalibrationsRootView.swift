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
                        header: Text("Adicionar calibração"),
                        footer: Text(
                            "A calibração altera as glicemias usadas pelo algoritmo. Use uma medição de ponta de dedo feita no mesmo momento e somente quando a tendência estiver estável."
                        )
                    ) {
                        if state.isSmartCGM {
                            HStack {
                                Text("Leitura bruta do Smart")
                                Spacer()
                                Text(formattedSensorGlucose)
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Horário do sensor")
                                Spacer()
                                Text(state.sensorGlucoseDate.map(dateFormatter.string) ?? "–")
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Tendência")
                                Spacer()
                                Text(formattedTrendRate)
                                    .foregroundColor(.secondary)
                            }

                            Button("Atualizar leitura do Smart") {
                                state.refreshCalibrationCandidate()
                            }

                            if !state.calibrationReadinessMessage.isEmpty {
                                Text(state.calibrationReadinessMessage)
                                    .font(.footnote)
                                    .foregroundColor(.orange)
                            }
                        }

                        HStack {
                            Text("Glicemia de ponta de dedo")
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
                        label: { Text("Registrar calibração") }
                            .disabled(!state.canAddCalibration)

                        if let message = state.lastActionMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }.listRowBackground(Color.chart)

                    Section(header: Text("Ajuste atual")) {
                        HStack {
                            Text("Inclinação")
                            Spacer()
                            Text(formatter.string(from: state.slope as NSNumber)!)
                        }
                        HStack {
                            Text("Deslocamento")
                            Spacer()
                            Text(formatter.string(from: state.intercept as NSNumber)!)
                        }
                    }.listRowBackground(Color.chart)

                    Section(header: Text("Remover calibrações")) {
                        Button {
                            state.removeLast()
                        }
                        label: { Text("Remover a última") }
                            .disabled(state.calibrations.isEmpty)

                        Button {
                            state.removeAll()
                        }
                        label: { Text("Remover todas") }
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
                        Section(header: Text("Gráfico")) {
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
                "Aplicar esta calibração?",
                isPresented: $shouldConfirmCalibration,
                titleVisibility: .visible
            ) {
                Button("Confirmar calibração") {
                    Task {
                        await state.addCalibration()
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(
                    "As próximas glicemias recebidas pelo Trio serão ajustadas e poderão influenciar o tratamento."
                )
            }
            .navigationTitle("Calibrações")
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

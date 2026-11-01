import SwiftUI

struct ExportView: View {
    @ObservedObject var model: ExportModel

    var body: some View {
        List {
            switch model.phase {
            case .intro, .asking:
                intro
            case .limited(let cut):
                Section {
                    Label("Health is only sharing data from \(Format.day(cut.ref)) onwards with Hëlth, so older data would be left behind.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("That happens when \"Past 30 Days\" was picked on the permission screen. To send everything: delete Hëlth from this iPhone, install it again, tap Send, and this time choose All Recorded Data and Future Data.")
                }
                Section {
                    Button("Send only from \(Format.day(cut.ref)) anyway") { model.reset(); model.start(anyway: true) }
                }
            case .running:
                running
            case .done:
                done
            case .failed(let why):
                Section {
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Button("Try again") { model.start() }
                }
            }
        }
        .navigationTitle("Send")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.phase == .running || model.phase == .asking)
    }

    private var intro: some View {
        Group {
            Section {
                Text("Hëlth reads the Health data on this iPhone, including what your Apple Watch has recorded, and puts it in one file for your other iPhone.")
            }
            Section("Before you start") {
                Bullet(icon: "applewatch", text: "If you have an Apple Watch, keep it on and near this iPhone for a few minutes first, so its latest data is here.")
                Bullet(icon: "iphone.gen3", text: "Hëlth needs to be on the other iPhone too, to open the file.")
                Bullet(icon: "sun.max", text: "Keep Hëlth open with the screen on until it's done. It usually takes a few minutes.")
                Bullet(icon: "clock.arrow.circlepath", text: "If Health asks how much data to share, choose All Recorded Data and Future Data. The other choice sends only the last 30 days.")
            }
            Section {
                Button {
                    model.start()
                } label: {
                    HStack {
                        Spacer()
                        if model.phase == .asking { ProgressView().padding(.trailing, 6) }
                        Text("Allow Health access and start").bold()
                        Spacer()
                    }
                }
                .disabled(model.phase == .asking)
            } footer: {
                Text("On the next screen, tap the button at the top that turns everything on (Turn On All or Select All), then tap Allow or Continue. Hëlth only reads here; it doesn't change anything on this iPhone.")
            }
        }
    }

    private var running: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reading \(model.progress.current)").font(.headline)
                ProgressView(value: Double(model.progress.step), total: Double(max(1, model.progress.steps)))
                Text("\(Format.records(model.progress.records)) so far").foregroundStyle(.secondary).monospacedDigit()
                if model.waiting {
                    Label("Paused while the iPhone is locked. Unlock it to carry on.", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Keep Hëlth open with the screen on.")
        }
    }

    @ViewBuilder
    private var done: some View {
        if let m = model.manifest, let file = model.file {
            let total = m.totals.values.reduce(0) { $0 + $1.count }
            let first = m.totals.values.compactMap(\.first).min()
            let last = m.totals.values.compactMap(\.last).max()
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Ready to send", systemImage: "checkmark.circle.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                    Text("\(Format.records(total)), \(Format.bytes(Files.size(file)))")
                    if let first, let last {
                        Text("From \(Format.day(first)) to \(Format.day(last))").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                ShareLink(item: file) {
                    HStack {
                        Spacer()
                        Label("Send to the other iPhone", systemImage: "square.and.arrow.up").bold()
                        Spacer()
                    }
                }
            } footer: {
                Text("Choose AirDrop, then the other iPhone. The file opens in Hëlth there. If it lands in Files instead, open Hëlth on that iPhone, tap Receive and pick the file.")
            }

            if m.totals.isEmpty {
                Section {
                    Label("No Health data was found. If you turned some categories off on the permission screen, turn them on in the Health app (tap your picture, then Apps > Hëlth), then send again.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("In the file") {
                ForEach(m.totals.sorted { $0.value.count > $1.value.count }.prefix(12), id: \.key) { key, t in
                    LabeledContent(Catalog.name(for: key), value: Format.count(t.count))
                }
                if m.totals.count > 12 {
                    Text("and \(m.totals.count - 12) more kinds").foregroundStyle(.secondary)
                }
            }

            if !m.notes.isEmpty {
                Section("Couldn't read") {
                    ForEach(m.notes, id: \.self) { Text($0).font(.footnote) }
                }
            }

            Section("Your Apple Watch") {
                Text("Anything the Watch records from now on stays on this iPhone. Once the file is on the other iPhone, unpair the Watch here in the Watch app and pair it with the other iPhone.")
            }

            Section {
                Button("Make a new file") { model.reset(); model.start() }
            }
        }
    }
}

struct Bullet: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 22)
            Text(text)
        }
        .padding(.vertical, 2)
    }
}

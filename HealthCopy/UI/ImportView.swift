import SwiftUI

struct ImportView: View {
    @ObservedObject var model: ImportModel
    @State private var picking = false
    @State private var showAll = false

    var body: some View {
        List {
            switch model.phase {
            case .noFile: waiting
            case .reading: reading
            case .loaded, .asking: plan
            case .limited(let cut): limited(cut)
            case .running: running
            case .stopped, .failed: interrupted
            case .done: done
            }
        }
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.phase == .running || model.phase == .asking || model.phase == .reading)
        .toolbar {
            if canChangeFile {
                Button("Other File") { picking = true }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [Files.archiveType, .zip, .xml, .folder, .data]) { result in
            if case .success(let url) = result { model.take(url) }
        }
    }

    /// A file is open and nothing is running, so another one can take its place.
    private var canChangeFile: Bool {
        switch model.phase {
        case .loaded, .stopped, .done, .failed: return true
        default: return false
        }
    }

    // MARK: Waiting for a file

    private var waiting: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Waiting for the file").font(.title3.bold())
                    Text("AirDrop it from the iPhone with the data. It opens here by itself.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            if let error = model.loadError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section("If that iPhone has Hëlth") {
                Step(n: 1, text: "Open Hëlth there and tap **Send**.")
                Step(n: 2, text: "AirDrop the file to this iPhone.")
            }
            Section {
                Step(n: 1, text: "Open the Health app there, tap your picture at the top right, then **Export All Health Data**.")
                Step(n: 2, text: "AirDrop **export.zip** to this iPhone.")
            } header: {
                Text("If it doesn't")
            } footer: {
                Text("The export can take a few minutes to make.")
            }
            Section {
                Button { picking = true } label: {
                    Label("Choose the file", systemImage: "folder")
                }
            } footer: {
                Text("If AirDrop put the file in Files instead (usually in Downloads), choose it here.")
            }
        }
    }

    // MARK: Reading Apple's export

    private var reading: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reading the Health export").font(.headline)
                ProgressView(value: model.reading)
                Text("\(Int(100 * model.reading))%").monospacedDigit().font(.subheadline)
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Keep Hëlth open with the screen on. Nothing goes into Health yet: next you'll see what's in the export.")
        }
    }

    // MARK: Before copying

    private var copyable: [Importer.PlanLine] { model.lines.filter { $0.status == .copy } }
    private var blocked: [Importer.PlanLine] { model.lines.filter { $0.status != .copy } }

    @ViewBuilder
    private var plan: some View {
        if let m = model.manifest {
            let total = copyable.reduce(0) { $0 + $1.count }
            let first = m.totals.values.compactMap(\.first).min()
            let last = m.totals.values.compactMap(\.last).max()
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Format.records(total)) to copy").font(.title3.bold())
                    if let first, let last {
                        Text("From \(Format.day(first)) to \(Format.day(last))")
                    }
                    if model.fromApple {
                        Text("From the Health app's export, made \(Format.moment(m.created))")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Made on an \(m.device) with \(m.system), \(Format.moment(m.created))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            if model.lowOnSpace {
                Section {
                    Label("This iPhone may not have enough free storage. Health needs about \(Format.bytes(model.spaceNeeded)); \(Format.bytes(Files.freeSpace)) is free. Free up some space first (Settings > General > iPhone Storage).", systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    model.start()
                } label: {
                    HStack {
                        Spacer()
                        if model.phase == .asking { ProgressView().padding(.trailing, 6) }
                        Text(model.resumable ? "Continue copying" : "Copy into Health").bold()
                        Spacer()
                    }
                }
                .disabled(model.phase == .asking || total == 0)
            } footer: {
                Text("Health asks for permission next: tap the button at the top that turns everything on (Turn On All or Select All), then Allow or Continue. If it asks how much data to share, choose All Recorded Data.\n\nNothing on this iPhone is changed or replaced, and anything already here is skipped.")
            }

            Section("Will be copied") {
                ForEach(showAll ? copyable : Array(copyable.prefix(10))) { line in
                    LabeledContent(line.name, value: Format.count(line.count))
                }
                if copyable.count > 10 {
                    Button(showAll ? "Show fewer" : "Show all \(copyable.count) kinds") { showAll.toggle() }
                }
            }

            if model.fromApple && !m.notes.isEmpty {
                Section {
                    ForEach(m.notes, id: \.self) { Text($0).font(.subheadline) }
                } header: {
                    Text("Left out")
                } footer: {
                    Text("No app can put these back into Health. The Health app's export also never has heartbeat series, State of Mind entries or the separate parts of multisport workouts, and keeps times to the second. Everything under Will be copied goes in.")
                }
            }

            if !blocked.isEmpty {
                Section {
                    ForEach(blocked) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(line.name, value: Format.count(line.count))
                            Text(line.status == .appleOnly ? "Only Apple can add this" : "Needs a newer iOS on this iPhone")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Can't be copied")
                } footer: {
                    Text("Apple keeps some kinds of data, like Exercise and Stand minutes, for its own apps. Your Apple Watch starts recording them again on this iPhone once it's paired here.")
                }
            }
        }
    }

    // MARK: Limited history

    @ViewBuilder
    private func limited(_ cut: Date) -> some View {
        Section {
            Label("Health only lets Hëlth see this iPhone's data from \(Format.day(cut.ref)) onwards.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("It can still copy everything, but it can't check whether older records are already here, so if some are, they'd end up twice. To fix it, delete Hëlth, install it again, open the file again and choose All Recorded Data and Future Data when Health asks.")
        }
        Section {
            Button("Copy anyway") { model.start(anyway: true) }
        } footer: {
            Text("Fine if this iPhone has nothing from the same dates as the file.")
        }
    }

    // MARK: Copying

    private var running: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Copying \(model.progress.current)").font(.headline)
                ProgressView(value: Double(min(model.progress.done, model.progress.total)), total: Double(model.progress.total))
                HStack {
                    Text("\(Int(100 * Double(model.progress.done) / Double(model.progress.total)))%").monospacedDigit()
                    Spacer()
                    Text(model.remaining).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                if model.waiting {
                    Label("Paused while the iPhone is locked. Unlock it to carry on.", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 6)
            Button("Stop for now", role: .destructive) { model.stop() }
        } footer: {
            Text("Keep Hëlth open with the screen on. If it gets interrupted, open it again and it carries on where it stopped.")
        }
    }

    // MARK: Stopped or failed

    @ViewBuilder
    private var interrupted: some View {
        Section {
            if case .failed(let why) = model.phase {
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Label("Stopped. Nothing is lost; it carries on from here.", systemImage: "pause.circle.fill")
            }
            Button(model.resumable ? "Continue copying" : "Try again") { model.start() }
        }
        summary
    }

    // MARK: Done

    @ViewBuilder
    private var done: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.green)
                Text("Copied \(Format.records(model.copied)) into Health.")
                if model.already > 0 {
                    Text("\(Format.records(model.already)) were already on this iPhone, so they were left as they are.")
                        .foregroundStyle(.secondary)
                }
                if model.failed > 0 {
                    Text("\(Format.records(model.failed)) couldn't be copied. Details below.")
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 6)
            if let url = URL(string: "x-apple-health://") {
                Link("Open Health", destination: url)
            }
        } footer: {
            Text("Copied records show Hëlth as their source in Health, with the original device (such as your Apple Watch) kept in each record's details.")
        }
        if model.failed > 0 {
            Section {
                Button("Try the missing ones again") { model.start(again: true) }
            } footer: {
                Text("Goes through the file again. What's already copied is skipped.")
            }
        }
        summary
    }

    @ViewBuilder
    private var summary: some View {
        let rows = model.results.filter { $0.value.total > 0 }.sorted { $0.value.total > $1.value.total }
        let copied = rows.filter { $0.value.copied + $0.value.already > 0 }
        let problems = rows.filter { $0.value.failed > 0 }
        let skipped = rows.filter { $0.value.skipped > 0 }

        if !copied.isEmpty {
            Section("Copied") {
                ForEach(copied, id: \.key) { key, r in
                    LabeledContent(Catalog.name(for: key)) {
                        VStack(alignment: .trailing) {
                            Text(Format.count(r.copied)).monospacedDigit()
                            if r.already > 0 { Text("\(Format.count(r.already)) already here").font(.caption) }
                        }
                    }
                }
            }
        }
        if !problems.isEmpty {
            Section("Couldn't copy") {
                ForEach(problems, id: \.key) { key, r in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(Catalog.name(for: key), value: Format.count(r.failed))
                        ForEach(r.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        if !skipped.isEmpty {
            Section("Not copied") {
                ForEach(skipped, id: \.key) { key, r in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(Catalog.name(for: key), value: Format.count(r.skipped))
                        if let reason = r.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

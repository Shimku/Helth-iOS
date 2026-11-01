import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var receive: ImportModel
    @StateObject private var remove = RemoveModel()
    @State private var confirmRemove = false
    @State private var way = Way.start

    /// What the iPhone with the data uses to send it.
    enum Way {
        case both, healthApp
        #if DEBUG
        static var start: Way { CommandLine.arguments.contains("-healthapp") ? .healthApp : .both }
        #else
        static let start = Way.both
        #endif
    }

    var body: some View {
        NavigationStack(path: $app.path) {
            ScrollViewReader { scroll in
            List {
                Section {
                    HStack(spacing: 16) {
                        Image("Logo")
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .accessibilityHidden(true)
                        Text("Copies your Health data from one iPhone to another by AirDrop. Nothing is uploaded anywhere.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if receive.resumable {
                    Section {
                        NavigationLink(value: AppModel.Screen.receive) {
                            Label("Continue copying into Health", systemImage: "arrow.clockwise.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    } footer: {
                        Text("The last copy stopped part way. It carries on where it left off.")
                    }
                }

                Section {
                    NavigationLink(value: AppModel.Screen.send) {
                        Choice(icon: "arrow.up", title: "Send from this iPhone",
                               detail: "This is the iPhone with the data.")
                    }
                    NavigationLink(value: AppModel.Screen.receive) {
                        Choice(icon: "arrow.down", title: "Receive on this iPhone",
                               detail: "This is the iPhone the data goes to.")
                    }
                }

                Section {
                    Picker("Where Hëlth is", selection: $way) {
                        Text("Hëlth on both iPhones").tag(Way.both)
                        Text("Hëlth on one iPhone").tag(Way.healthApp)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.vertical, 4)
                    switch way {
                    case .both:
                        Step(n: 1, text: "On the iPhone with the data, open Hëlth and tap **Send**.")
                        Step(n: 2, text: "AirDrop the file to the other iPhone. It opens in Hëlth there.")
                        Step(n: 3, text: "Tap **Copy into Health**. Anything that's already there is skipped.")
                    case .healthApp:
                        Step(n: 1, text: "On the iPhone with the data, open the Health app, tap your picture at the top right, then **Export All Health Data**.")
                        Step(n: 2, text: "AirDrop **export.zip** to the iPhone with Hëlth and open it in Hëlth.")
                        Step(n: 3, text: "Tap **Copy into Health**. Anything that's already there is skipped.")
                    }
                } header: {
                    Text("How it works")
                } footer: {
                    switch way {
                    case .both:
                        Text("Copies the most, including heartbeat series and State of Mind.")
                    case .healthApp:
                        Text("For when the iPhone with the data doesn't have Hëlth. The Health app's export leaves out a few things, like heartbeat series and State of Mind.")
                    }
                }

                Section {
                    Text("Hëlth has no account, no servers and no analytics, and it never goes online. Your data goes from one iPhone to the other by AirDrop and nowhere else.")
                        .id("privacy")
                    Link("Privacy policy", destination: Site.privacy)
                    Link("Help", destination: Site.help)
                } header: {
                    Text("Privacy")
                }

                Section {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        if remove.phase == .working {
                            HStack { ProgressView(); Text("Removing...") }
                        } else {
                            Text("Remove what Hëlth added")
                        }
                    }
                    .disabled(remove.phase == .working)
                } footer: {
                    switch remove.phase {
                    case .done(let n): Text(n == 0 ? "Nothing to remove: Hëlth hasn't added anything on this iPhone." : "Removed \(Format.records(n)) that Hëlth had added.")
                    case .failed(let why): Text(why).foregroundStyle(.red)
                    default: Text("Takes out only what Hëlth copied in on this iPhone. Nothing else in Health is touched.")
                    }
                }
            }
            .navigationTitle("Hëlth")
            .navigationDestination(for: AppModel.Screen.self) { screen in
                switch screen {
                case .send: ExportView(model: app.send)
                case .receive: ImportView(model: app.receive)
                }
            }
            .confirmationDialog("Remove everything Hëlth added to Health on this iPhone?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove.run() }
            } message: {
                Text("Only what this app copied in is removed. You can copy it again afterwards.")
            }
            .onChange(of: remove.phase) { phase in
                if case .done = phase { receive.restore() }
            }
            #if DEBUG
            .task {
                if CommandLine.arguments.contains("-privacy") { scroll.scrollTo("privacy", anchor: .center) }
            }
            #endif
            }
        }
    }
}

struct Choice: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct Step: View {
    let n: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
        .padding(.vertical, 2)
    }
}

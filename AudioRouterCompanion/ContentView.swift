import SwiftUI
import Network

@available(iOS 17.0, *)
struct ContentView: View {
    @StateObject private var vm = ViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("端末")) {
                    HStack {
                        Text(vm.deviceName)
                        Spacer()
                        Text(versionString).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(header: Text("接続先 Mac")) {
                    if vm.peers.isEmpty {
                        Text("Mac を探しています…").foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.peers) { p in
                            HStack {
                                Text(p.name)
                                Spacer()
                                if vm.selectedPeerID == p.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { vm.select(p) }
                        }
                    }
                }
                Section(header: Text("状態")) {
                    Text(vm.status)
                }
                Section {
                    Button { vm.rescan() } label: {
                        Label("再スキャン", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { vm.stopBridge() } label: {
                        Label("切断", systemImage: "stop.circle")
                    }
                }
            }
            .navigationTitle("AudioRouter")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { vm.onAppear() }
        .onDisappear { vm.onDisappear() }
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "v\(v)"
    }
}

@available(iOS 17.0, *)
#Preview { ContentView() }

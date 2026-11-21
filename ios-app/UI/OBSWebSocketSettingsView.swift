/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：原版 WebSocket 设置窗口依赖 Qt。iOS 表单直接读写
 * 原有 Config 和 WebSocketServer，连接二维码由系统 Core Image 绘制。 */

import CoreImage.CIFilterBuiltins
import SwiftUI

struct OBSWebSocketSettingsView: View {
    @State private var enabled = false
    @State private var auth = true
    @State private var alerts = false
    @State private var debug = false
    @State private var port = 4455
    @State private var password = ""
    @State private var address = ""
    @State private var connected: [Client] = []
    @State private var connectInfo = false
    @State private var confirmInfo = false
    @State private var invalid = false

    private struct Client: Identifiable {
        let id: String
        let date: Date
        let counts: String
        let identified: Bool
    }

    var body: some View {
        Form {
            Section(title("Settings.PluginSettingsTitle")) {
                Toggle(title("Settings.ServerEnable"), isOn: $enabled)
                Toggle(title("Settings.AlertsEnable"), isOn: $alerts)
                Toggle(title("Settings.DebugEnable"), isOn: $debug)
            }
            Section(title("Settings.ServerSettingsTitle")) {
                TextField(title("Settings.ServerPort"), value: $port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                Toggle(title("Settings.AuthRequired"), isOn: $auth)
                SecureField(title("Settings.Password"), text: $password).disabled(!auth)
                Button(title("Settings.GeneratePassword")) {
                    password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                }.disabled(!auth)
                Button(OBSLocale.str("Apply")) { apply() }
                Button(title("Settings.ShowConnectInfo")) {
                    if obs_frontend_streaming_active() || obs_frontend_recording_active() || obs_frontend_replay_buffer_active() {
                        confirmInfo = true
                    } else { connectInfo = true }
                }.disabled(!enabled)
            }
            Section(title("SessionTable.Title")) {
                ForEach(connected) { client in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(client.id)
                            Spacer()
                            if client.identified { Image(systemName: "checkmark.shield") }
                        }
                        HStack {
                            Text(client.date, style: .timer)
                            Text(client.counts)
                            Spacer()
                            Button(title("SessionTable.KickButtonText"), role: .destructive) {
                                obs_app_websocket_disconnect(client.id)
                            }.buttonStyle(.borderless)
                        }.font(.caption)
                    }
                }
            }
        }
        .navigationTitle(title("Settings.DialogTitle"))
        .alert(title("Settings.Save.PasswordInvalidErrorTitle"), isPresented: $invalid) {
            Button(OBSLocale.str("OK"), role: .cancel) {}
        } message: {
            Text(auth && password.utf8.count < 6 ? title("Settings.Save.PasswordInvalidErrorMessage") :
                    title("Settings.ServerPort") + " 1024–65535")
        }
        .confirmationDialog(title("Settings.ShowConnectInfoWarningTitle"), isPresented: $confirmInfo) {
            Button(title("Settings.ShowConnectInfo")) { connectInfo = true }
        } message: { Text(title("Settings.ShowConnectInfoWarningInfoText")) }
        .sheet(isPresented: $connectInfo) {
            NavigationStack {
                Form {
                    LabeledContent(title("ConnectInfo.ServerIp"), value: address).textSelection(.enabled)
                    LabeledContent(title("ConnectInfo.ServerPort"), value: String(port))
                    LabeledContent(title("ConnectInfo.ServerPassword"),
                                   value: auth ? password : title("ConnectInfo.ServerPasswordPlaceholderText"))
                        .textSelection(.enabled)
                    Section(title("ConnectInfo.QrTitle")) {
                        if let image = qrImage {
                            Image(uiImage: image).interpolation(.none)
                                .resizable().scaledToFit().frame(width: 200, height: 200)
                                .padding().background(.white)
                        }
                    }
                }
                .navigationTitle(title("ConnectInfo.DialogTitle"))
                .toolbar { Button(OBSLocale.str("Close")) { connectInfo = false } }
            }
        }
        .onAppear { read(all: true) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in read(all: false) }
    }

    private func title(_ key: String) -> String {
        OBSLocale.str("OBSWebSocket." + key, module: "obs-websocket")
    }

    private func apply() {
        guard (1024...65535).contains(port), !auth || password.utf8.count >= 6 else { invalid = true; return }
        let settings = obs_data_create()
        defer { obs_data_release(settings) }
        obs_data_set_bool(settings, "enabled", enabled)
        obs_data_set_bool(settings, "authentication", auth)
        obs_data_set_bool(settings, "alerts", alerts)
        obs_data_set_bool(settings, "debug", debug)
        obs_data_set_int(settings, "port", Int64(port))
        obs_data_set_string(settings, "password", password)
        obs_app_websocket_apply(settings)
    }

    private func read(all: Bool) {
        guard let data = obs_app_websocket_settings() else { return }
        defer { obs_data_release(data) }
        if all {
            enabled = obs_data_get_bool(data, "enabled")
            auth = obs_data_get_bool(data, "authentication")
            alerts = obs_data_get_bool(data, "alerts")
            debug = obs_data_get_bool(data, "debug")
            port = Int(obs_data_get_int(data, "port"))
            password = String(cString: obs_data_get_string(data, "password"))
            address = String(cString: obs_data_get_string(data, "address"))
        }
        let sessions = obs_data_get_array(data, "sessions")
        defer { obs_data_array_release(sessions) }
        connected = (0..<obs_data_array_count(sessions)).compactMap { index in
            guard let session = obs_data_array_item(sessions, index) else { return nil }
            defer { obs_data_release(session) }
            let incoming = obs_data_get_int(session, "incoming")
            let outgoing = obs_data_get_int(session, "outgoing")
            return Client(id: String(cString: obs_data_get_string(session, "address")),
                          date: Date(timeIntervalSince1970: Double(obs_data_get_int(session, "connected"))),
                          counts: "\(incoming)/\(outgoing)", identified: obs_data_get_bool(session, "identified"))
        }
    }

    private var qrImage: UIImage? {
        var url = URLComponents()
        url.scheme = "obsws"
        url.host = address
        url.port = port
        if auth {
            var characters = CharacterSet.alphanumerics
            characters.insert(charactersIn: "-._~")
            url.percentEncodedPath = "/" + (password.addingPercentEncoding(withAllowedCharacters: characters) ?? "")
        }
        guard let value = url.string else { return nil }
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(value.utf8)
        guard let output = generator.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

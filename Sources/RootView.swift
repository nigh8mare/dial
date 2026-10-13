import SwiftUI
import WebKit

struct RootView: View {
    @StateObject private var model = WebModel()

    var body: some View {
        ZStack {
            Color("LaunchBg").ignoresSafeArea()

            LogWebView(model: model)
                .safeAreaInset(edge: .top, spacing: 0) {
                    RecordingBar(recorder: model.recorder)
                }

            if model.isLoading && !model.hasLoadedOnce {
                ProgressView()
                    .controlSize(.large)
            }

            if let message = model.errorText {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .multilineTextAlignment(.center)
                    Button("Try again") { model.reload() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(24)
            }
        }
    }
}

struct LogWebView: UIViewRepresentable {
    let model: WebModel

    func makeUIView(context: Context) -> WKWebViewHost {
        WKWebViewHost(webView: model.webView)
    }

    func updateUIView(_ uiView: WKWebViewHost, context: Context) {}
}

/// Stays on screen on every tab while a visit is being recorded or transcribed.
struct RecordingBar: View {
    @ObservedObject var recorder: VisitRecorder

    var body: some View {
        if recorder.isRecording {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recording \(recorder.patientName)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Keeps going with the screen locked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(clock(recorder.elapsed))
                    .font(.subheadline.monospacedDigit())
                Button("Stop") { recorder.stop() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        } else if let status = recorder.statusText {
            HStack(spacing: 10) {
                ProgressView()
                Text(status).font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

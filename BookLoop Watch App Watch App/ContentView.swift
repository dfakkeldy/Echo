import SwiftUI
import WatchConnectivity
import WatchKit
import Observation
import WidgetKit

@Observable
class WatchViewModel: NSObject, WCSessionDelegate {
    var isPlaying: Bool = false
    var title: String = "No track"
    var thumbnailImage: UIImage? = nil
    var progressFraction: Double = 0.0
    
    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async {
            let defaults = UserDefaults(suiteName: "group.com.bookloop")
            if let crownAction = applicationContext["crownAction"] as? String {
                defaults?.set(crownAction, forKey: "crownAction")
            }
            if let isPlaying = applicationContext["isPlaying"] as? Bool {
                self.isPlaying = isPlaying
                defaults?.set(isPlaying, forKey: "isPlaying")
            }
            if let title = applicationContext["title"] as? String {
                self.title = title
                defaults?.set(title, forKey: "title")
            }
            if let progressFraction = applicationContext["progressFraction"] as? Double {
                self.progressFraction = progressFraction
                defaults?.set(progressFraction, forKey: "progressFraction")
            }
            if let thumbnailData = applicationContext["thumbnailData"] as? Data {
                defaults?.set(thumbnailData, forKey: "thumbnailData")
                if let image = UIImage(data: thumbnailData) {
                    self.thumbnailImage = image
                }
            } else {
                defaults?.removeObject(forKey: "thumbnailData")
                self.thumbnailImage = nil
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    
    func sendCommand(_ command: String, params: [String: Any]? = nil) {
        if WCSession.default.isReachable {
            var message: [String: Any] = ["command": command]
            if let params = params {
                for (key, value) in params {
                    message[key] = value
                }
            }
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { error in
                print("Error sending command: \(error)")
            })
        }
        
        // Haptic feedback
        switch command {
        case "play", "pause", "toggle":
            WKInterfaceDevice.current().play(.click)
        case "next", "skipForward":
            WKInterfaceDevice.current().play(.directionUp)
        case "skipBackward", "previous":
            WKInterfaceDevice.current().play(.directionDown)
        default:
            break
        }
    }
}

struct ContentView: View {
    @State private var viewModel = WatchViewModel()
    @AppStorage("crownAction", store: UserDefaults(suiteName: "group.com.bookloop")) private var crownAction = "volume"
    @State private var crownAccumulator: Double = 0.0
    @State private var lastAccumulator: Double = 0.0
    @FocusState private var isFocused: Bool
    
    var body: some View {
        ZStack {
            // Background
            if let image = viewModel.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.6))
            } else {
                Color.black.ignoresSafeArea()
            }
            
            VStack(spacing: 12) {
                if let image = viewModel.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.title)
                                .foregroundColor(.white)
                        )
                }
                
                Text(viewModel.title)
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal)
                
                HStack(spacing: 20) {
                    Button {
                        viewModel.sendCommand("skipBackward")
                    } label: {
                        Image(systemName: "gobackward.30")
                            .font(.system(size: 20))
                            .frame(width: 38, height: 38)
                            .padding(15)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 4)
                            .frame(width: 52, height: 52)
                        
                        Circle()
                            .trim(from: 0, to: viewModel.progressFraction)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 52, height: 52)
                            .rotationEffect(.degrees(-90))
                        
                        Button {
                            viewModel.sendCommand(viewModel.isPlaying ? "pause" : "play")
                            viewModel.isPlaying.toggle()
                        } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        // Hidden button for the double tap gesture to avoid the UIHostingController warning
                        Button("") {
                            viewModel.sendCommand(viewModel.isPlaying ? "pause" : "play")
                            viewModel.isPlaying.toggle()
                        }
                        .opacity(0)
                        .handGestureShortcut(.primaryAction)
                    }
                    
                    Button {
                        viewModel.sendCommand("next")
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 20))
                            .frame(width: 38, height: 38)
                            .padding(15)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 6)
            }
        }
        .focusable(true)
        .focused($isFocused)
        .digitalCrownRotation($crownAccumulator)
        .onChange(of: crownAccumulator) { oldValue, newValue in
            let delta = newValue - lastAccumulator
            lastAccumulator = newValue
            
            if crownAction == "scrub" {
                viewModel.sendCommand("scrubDelta", params: ["delta": delta])
            } else {
                viewModel.sendCommand("volumeDelta", params: ["delta": delta])
            }
        }
        .onAppear {
            isFocused = true
        }
        .onChange(of: crownAction) { oldValue, newValue in
            isFocused = true
        }
    }
}

#Preview {
    ContentView()
}

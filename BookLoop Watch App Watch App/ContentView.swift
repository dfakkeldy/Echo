import SwiftUI
import WatchConnectivity
import WatchKit
import Observation

@Observable
class WatchViewModel: NSObject, WCSessionDelegate {
    var isPlaying: Bool = false
    var title: String = "No track"
    var thumbnailImage: UIImage? = nil
    
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
            if let isPlaying = applicationContext["isPlaying"] as? Bool {
                self.isPlaying = isPlaying
            }
            if let title = applicationContext["title"] as? String {
                self.title = title
            }
            if let thumbnailData = applicationContext["thumbnailData"] as? Data,
               let image = UIImage(data: thumbnailData) {
                self.thumbnailImage = image
            } else {
                self.thumbnailImage = nil
            }
        }
    }
    
    func sendCommand(_ command: String) {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["command": command], replyHandler: nil, errorHandler: { error in
                print("Error sending command: \(error)")
            })
        }
        
        // Haptic feedback
        switch command {
        case "play":
            WKInterfaceDevice.current().play(.start)
        case "pause":
            WKInterfaceDevice.current().play(.stop)
        case "next", "previous", "skipBackward":
            WKInterfaceDevice.current().play(.click)
        default:
            break
        }
    }
}

struct ContentView: View {
    @State private var viewModel = WatchViewModel()
    
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
                        .fill(Color.gray.opacity(0.3))
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
                            .font(.title2)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button {
                        viewModel.sendCommand(viewModel.isPlaying ? "pause" : "play")
                        viewModel.isPlaying.toggle()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 38))
                            .shadow(color: Color.white.opacity(0.3), radius: 5, x: 0, y: 0)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button {
                        viewModel.sendCommand("next")
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.title2)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.top, 6)
            }
        }
    }
}

#Preview {
    ContentView()
}

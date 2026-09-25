// Adapted from the LiveKit Flutter Broadcast Extension example.
// Original SampleHandler by Alex-Dan Bumbu (2021).
import ReplayKit
import OSLog

let broadcastLogger = OSLog(subsystem: "com.example.hiZoom", category: "Broadcast")

final class SampleHandler: RPBroadcastSampleHandler {
    private var connection: SocketConnection?
    private var uploader: SampleUploader?
    private var connectTimer: DispatchSourceTimer?
    @Atomic private var finished = false
    private let stopNotification = "iOS_BroadcastRequestStop" as CFString

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard
            let appGroupIdentifier = Bundle.main.object(forInfoDictionaryKey: "RTCAppGroupIdentifier") as? String,
            !appGroupIdentifier.isEmpty,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            ),
            let socket = SocketConnection(filePath: container.appendingPathComponent("rtc_SSFD").path)
        else {
            finish("Chưa cấu hình App Group cho chia sẻ màn hình.")
            return
        }
        connection = socket
        uploader = SampleUploader(connection: socket)

        socket.didClose = { [weak self] _ in
            DispatchQueue.main.async { self?.finish("Đã dừng chia sẻ màn hình.") }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { handler.finish("Đã dừng chia sẻ màn hình.") }
            }, stopNotification, nil, .deliverImmediately
        )
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        connectTimer = timer
        let deadline = Date().addingTimeInterval(15)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.finished else { return }
            if self.connection?.open() == true {
                self.connectTimer?.cancel()
                self.connectTimer = nil
            } else if Date() > deadline {
                self.finish("Không kết nối được phòng. Mở Hisale Coaching Hub và thử lại.")
            }
        }
        timer.resume()
    }

    override func processSampleBuffer(_ buffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard !finished else { return }
        switch type {
        case .video:
            uploader?.send(sample: buffer)
        default:
            break
        }
    }

    override func broadcastFinished() { cleanup() }

    private func finish(_ message: String) {
        guard !finished else { return }
        cleanup()
        finishBroadcastWithError(NSError(
            domain: RPRecordingErrorDomain, code: 10001,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    private func cleanup() {
        guard !finished else { return }
        finished = true
        connectTimer?.cancel()
        connectTimer = nil
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(stopNotification), nil
        )
        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
        connection?.didClose = nil
        connection?.close()
        uploader = nil
        connection = nil
    }
}

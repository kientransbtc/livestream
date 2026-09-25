// Adapted from the LiveKit Flutter Broadcast Extension example.
// Original SampleHandler by Alex-Dan Bumbu (2021).
import ReplayKit
import OSLog

let broadcastLogger = OSLog(subsystem: "com.example.hiZoom", category: "Broadcast")

final class SampleHandler: RPBroadcastSampleHandler {
    private var connection: SocketConnection?
    private var audioConnection: SocketConnection?
    private var uploader: SampleUploader?
    private var audioUploader: AudioSampleUploader?
    private var connectTimer: DispatchSourceTimer?
    private var videoConnected = false
    private var audioConnected = false
    private var receivedAppAudio = false
    @Atomic private var finished = false
    private let stopNotification = "iOS_BroadcastRequestStop" as CFString

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard
            let appGroupIdentifier = Bundle.main.object(forInfoDictionaryKey: "RTCAppGroupIdentifier") as? String,
            !appGroupIdentifier.isEmpty,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            ),
            let socket = SocketConnection(filePath: container.appendingPathComponent("rtc_SSFD").path),
            let audioSocket = SocketConnection(filePath: container.appendingPathComponent("rtc_SSFA").path)
        else {
            finish("Chưa cấu hình App Group cho chia sẻ màn hình.")
            return
        }
        connection = socket
        audioConnection = audioSocket
        uploader = SampleUploader(connection: socket)
        audioUploader = AudioSampleUploader(connection: audioSocket)

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
        var audioAttempts = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.finished else { return }
            if !self.videoConnected && self.connection?.open() == true {
                self.videoConnected = true
                os_log(.default, log: broadcastLogger, "Screen video socket connected")
            }
            if !self.audioConnected {
                audioAttempts += 1
                if self.audioConnection?.open() == true {
                    self.audioConnected = true
                    os_log(.default, log: broadcastLogger, "Screen audio socket connected after %d attempts", audioAttempts)
                } else if audioAttempts % 20 == 0 {
                    os_log(.default, log: broadcastLogger, "Screen audio socket not connected yet (%d attempts)", audioAttempts)
                }
            }
            if self.videoConnected && self.audioConnected {
                self.connectTimer?.cancel()
                self.connectTimer = nil
            } else if !self.videoConnected && Date() > deadline {
                // Only a missing video connection ends the broadcast. Audio keeps
                // retrying; sharing the screen without sound beats no share.
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
        case .audioApp:
            if !receivedAppAudio {
                receivedAppAudio = true
                os_log(.default, log: broadcastLogger, "ReplayKit app-audio callback started")
            }
            audioUploader?.send(sampleBuffer: buffer)
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
        audioConnection?.didClose = nil
        audioConnection?.close()
        uploader = nil
        audioUploader = nil
        connection = nil
        audioConnection = nil
    }
}

//
//  SampleUploader.swift
//  Broadcast Extension
//
//  Created by Alex-Dan Bumbu on 22/03/2021.
//  Copyright © 2021 8x8, Inc. All rights reserved.
//

import Foundation
import ReplayKit
import OSLog
import CoreImage
import AVFoundation

private enum Constants {
    static let bufferMaxLength = 10240
}

/// Converts ReplayKit's app-audio samples to the mono 48 kHz Float32 format
/// consumed by the native WebRTC microphone mixer in the containing app.
final class AudioSampleUploader {
    private let connection: SocketConnection
    private let serialQueue = DispatchQueue(label: "org.hisale.broadcast.audioUploader")
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private var isOpen = false
    private var pendingPackets: [Data] = []
    private var currentPacket: Data?
    private var byteIndex = 0
    private let maxQueuedPackets = 10
    private let conversionLock = NSLock()
    private var converter: AVAudioConverter?
    private var loggedConversionError = false
    private var loggedSignal = false

    // Diagnostics, only touched on serialQueue.
    private var packetsQueued = 0
    private var packetsDropped = 0
    private var bytesWritten = 0
    private var lastStatsLog = Date()

    init(connection: SocketConnection) {
        self.connection = connection
        connection.didOpen = { [weak self] in
            self?.serialQueue.async { self?.markOpen("didOpen") }
        }
        connection.streamHasSpaceAvailable = { [weak self] in
            // Like the video uploader, treat "writable" as open: .openCompleted
            // alone is not reliable, and missing it would block audio forever.
            self?.serialQueue.async { self?.markOpen("hasSpaceAvailable") }
        }
    }

    func send(sampleBuffer: CMSampleBuffer) {
        guard let packet = makePacket(from: sampleBuffer) else { return }
        serialQueue.async { [weak self] in
            guard let self else { return }
            if self.pendingPackets.count >= self.maxQueuedPackets {
                self.pendingPackets.removeFirst()
                self.packetsDropped += 1
            }
            self.pendingPackets.append(packet)
            self.packetsQueued += 1
            if !self.isOpen && self.connection.isOutputOpen {
                self.markOpen("streamStatus")
            } else {
                self.writePendingPackets()
            }
            self.logStatsIfNeeded()
        }
    }

    private func markOpen(_ reason: String) {
        if !isOpen {
            isOpen = true
            os_log(.default, log: broadcastLogger, "Screen audio socket writable (%{public}@)", reason)
        }
        writePendingPackets()
    }

    private func logStatsIfNeeded() {
        guard Date().timeIntervalSince(lastStatsLog) >= 5 else { return }
        lastStatsLog = Date()
        os_log(.default, log: broadcastLogger,
               "Screen audio stats: open=%d queued=%d dropped=%d bytesWritten=%d pending=%d",
               isOpen ? 1 : 0, packetsQueued, packetsDropped, bytesWritten, pendingPackets.count)
    }

    private func makePacket(from sampleBuffer: CMSampleBuffer) -> Data? {
        conversionLock.lock()
        defer { conversionLock.unlock() }
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            let inputFormat = AVAudioFormat(streamDescription: streamDescription)
        else {
            logConversionError("Unsupported ReplayKit audio format")
            return nil
        }

        // Keep resampler history between ReplayKit packets. Creating a converter
        // for every packet repeatedly primes it and can discard short buffers.
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.primeMethod = .none
            os_log(.default, log: broadcastLogger, "Screen audio converter: %{public}@", inputFormat.description)
        }
        guard let converter else {
            logConversionError("AVAudioConverter unavailable")
            return nil
        }

        let inputFrameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard inputFrameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount),
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(Double(inputFrameCount) * 48_000 / inputFormat.sampleRate + 256)
              ) else {
            logConversionError("Could not allocate audio buffers")
            return nil
        }

        inputBuffer.frameLength = inputFrameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(inputFrameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            logConversionError("PCM copy failed: \(copyStatus)")
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil, conversionStatus != .error else {
            logConversionError(conversionError?.localizedDescription ?? "AVAudioConverter failed")
            return nil
        }
        guard outputBuffer.frameLength > 0,
              let channel = outputBuffer.floatChannelData?.pointee else {
            return nil
        }
        if !loggedSignal {
            for index in 0..<Int(outputBuffer.frameLength) where abs(channel[index]) > 0.00025 {
                loggedSignal = true
                os_log(.default, log: broadcastLogger, "ReplayKit supplied non-silent app audio")
                break
            }
        }

        let payloadLength = Int(outputBuffer.frameLength) * MemoryLayout<Float>.size
        var framed = Data(capacity: MemoryLayout<UInt32>.size + payloadLength)
        var networkLength = UInt32(payloadLength).bigEndian
        withUnsafeBytes(of: &networkLength) { framed.append(contentsOf: $0) }
        framed.append(Data(bytes: channel, count: payloadLength))
        return framed
    }

    private func logConversionError(_ message: String) {
        guard !loggedConversionError else { return }
        loggedConversionError = true
        os_log(.error, log: broadcastLogger, "Screen audio conversion failed: %{public}@", message)
    }

    private func writePendingPackets() {
        guard isOpen else { return }

        while true {
            if currentPacket == nil {
                guard !pendingPackets.isEmpty else { return }
                currentPacket = pendingPackets.removeFirst()
                byteIndex = 0
            }

            guard let packet = currentPacket, byteIndex < packet.count else {
                currentPacket = nil
                continue
            }

            let written = packet.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                let bytes = baseAddress.advanced(by: byteIndex).assumingMemoryBound(to: UInt8.self)
                return connection.writeToStream(buffer: bytes, maxLength: packet.count - byteIndex)
            }
            guard written > 0 else { return }
            if bytesWritten == 0 {
                os_log(.default, log: broadcastLogger, "First screen audio bytes sent to app: %d", written)
            }
            bytesWritten += written
            byteIndex += written
            if byteIndex == packet.count {
                currentPacket = nil
                byteIndex = 0
            }
        }
    }
}

class SampleUploader {

    private static var imageContext = CIContext(options: nil)

    @Atomic private var isReady = false
    private var connection: SocketConnection

    private var dataToSend: Data?
    private var byteIndex = 0

    private let serialQueue: DispatchQueue

    init(connection: SocketConnection) {
        self.connection = connection
        self.serialQueue = DispatchQueue(label: "org.jitsi.meet.broadcast.sampleUploader")

        setupConnection()
    }

    @discardableResult func send(sample buffer: CMSampleBuffer) -> Bool {
        guard isReady else {
            return false
        }

        isReady = false

        dataToSend = prepare(sample: buffer)
        byteIndex = 0

        serialQueue.async { [weak self] in
            self?.sendDataChunk()
        }

        return true
    }
}

private extension SampleUploader {

    func setupConnection() {
        connection.didOpen = { [weak self] in
            self?.isReady = true
        }
        connection.streamHasSpaceAvailable = { [weak self] in
            self?.serialQueue.async {
                if let success = self?.sendDataChunk() {
                    self?.isReady = !success
                }
            }
        }
    }

    @discardableResult func sendDataChunk() -> Bool {
        guard let dataToSend = dataToSend else {
            return false
        }

        var bytesLeft = dataToSend.count - byteIndex
        var length = bytesLeft > Constants.bufferMaxLength ? Constants.bufferMaxLength : bytesLeft

        length = dataToSend[byteIndex..<(byteIndex + length)].withUnsafeBytes {
            guard let ptr = $0.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }

            return connection.writeToStream(buffer: ptr, maxLength: length)
        }

        if length > 0 {
            byteIndex += length
            bytesLeft -= length

            if bytesLeft == 0 {
                self.dataToSend = nil
                byteIndex = 0
            }
        } else {
            os_log(.debug, log: broadcastLogger, "writeBufferToStream failure")
        }

        return true
    }

    func prepare(sample buffer: CMSampleBuffer) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            os_log(.debug, log: broadcastLogger, "image buffer not available")
            return nil
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)

        // ReplayKit may provide the full device resolution (for example
        // 2532px on the long edge of an iPhone). Downscaling before JPEG
        // encoding keeps the extension responsive and matches the 720p
        // LiveKit screen-share preset used by the Flutter app.
        let sourceWidth = CVPixelBufferGetWidth(imageBuffer)
        let sourceHeight = CVPixelBufferGetHeight(imageBuffer)
        let longestSide = max(sourceWidth, sourceHeight)
        let scaleFactor = max(1.0, Double(longestSide) / 1280.0)
        let width = Int(Double(sourceWidth) / scaleFactor)
        let height = Int(Double(sourceHeight) / scaleFactor)
        let orientation = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)?.uintValue ?? 0

        let scaleTransform = CGAffineTransform(
            scaleX: CGFloat(1.0 / scaleFactor),
            y: CGFloat(1.0 / scaleFactor)
        )
        let bufferData = self.jpegData(from: imageBuffer, scale: scaleTransform)

        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)

        guard let messageData = bufferData else {
            os_log(.debug, log: broadcastLogger, "corrupted image buffer")
            return nil
        }

        let httpResponse = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
        CFHTTPMessageSetHeaderFieldValue(httpResponse, "Content-Length" as CFString, String(messageData.count) as CFString)
        CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Width" as CFString, String(width) as CFString)
        CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Height" as CFString, String(height) as CFString)
        CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Orientation" as CFString, String(orientation) as CFString)

        CFHTTPMessageSetBody(httpResponse, messageData as CFData)

        let serializedMessage = CFHTTPMessageCopySerializedMessage(httpResponse)?.takeRetainedValue() as Data?

        return serializedMessage
    }

    func jpegData(from buffer: CVPixelBuffer, scale scaleTransform: CGAffineTransform) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: scaleTransform)

        guard let colorSpace = image.colorSpace else {
            return nil
        }

        let options: [CIImageRepresentationOption: Float] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82
        ]

        return SampleUploader.imageContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }
}

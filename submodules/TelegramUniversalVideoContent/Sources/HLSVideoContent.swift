import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AVFoundation
import UniversalMediaPlayer
import TelegramAudio
import AccountContext
import PhotoResources
import RangeSet
import TelegramVoip
import ManagedFile
import VideoToolbox
import CoreMedia

public final class HLSVideoContent: UniversalVideoContent {
    public let id: AnyHashable
    public let nativeId: PlatformVideoContentId
    let userLocation: MediaResourceUserLocation
    public let fileReference: FileMediaReference
    public let dimensions: CGSize
    public let duration: Double
    let streamVideo: Bool
    let loopVideo: Bool
    let enableSound: Bool
    let baseRate: Double
    let fetchAutomatically: Bool
    
    public init(id: PlatformVideoContentId, userLocation: MediaResourceUserLocation, fileReference: FileMediaReference, streamVideo: Bool = false, loopVideo: Bool = false, enableSound: Bool = true, baseRate: Double = 1.0, fetchAutomatically: Bool = true) {
        self.id = id
        self.userLocation = userLocation
        self.nativeId = id
        self.fileReference = fileReference
        self.dimensions = self.fileReference.media.dimensions?.cgSize ?? CGSize(width: 480, height: 320)
        self.duration = self.fileReference.media.duration ?? 0.0
        self.streamVideo = streamVideo
        self.loopVideo = loopVideo
        self.enableSound = enableSound
        self.baseRate = baseRate
        self.fetchAutomatically = fetchAutomatically
    }
    
    public func makeContentNode(accountId: AccountRecordId, postbox: Postbox, audioSession: ManagedAudioSession) -> UniversalVideoContentNode & ASDisplayNode {
        return HLSVideoContentNode(accountId: accountId, postbox: postbox, audioSessionManager: audioSession, userLocation: self.userLocation, fileReference: self.fileReference, streamVideo: self.streamVideo, loopVideo: self.loopVideo, enableSound: self.enableSound, baseRate: self.baseRate, fetchAutomatically: self.fetchAutomatically)
    }
    
    public func isEqual(to other: UniversalVideoContent) -> Bool {
        if let other = other as? HLSVideoContent {
            if case let .message(_, stableId, _) = self.nativeId {
                if case .message(_, stableId, _) = other.nativeId {
                    if self.fileReference.media.isInstantVideo {
                        return true
                    }
                }
            }
        }
        return false
    }
}

private final class HLSVideoContentNode: ASDisplayNode, UniversalVideoContentNode {
    private final class HLSServerSource: SharedHLSServer.Source {
        let id: String
        let postbox: Postbox
        let userLocation: MediaResourceUserLocation
        let playlistFiles: [Int: FileMediaReference]
        let qualityFiles: [Int: FileMediaReference]
        
        private var playlistFetchDisposables: [Int: Disposable] = [:]
        
        init(accountId: Int64, fileId: Int64, postbox: Postbox, userLocation: MediaResourceUserLocation, playlistFiles: [Int: FileMediaReference], qualityFiles: [Int: FileMediaReference]) {
            self.id = "\(UInt64(bitPattern: accountId))_\(fileId)"
            self.postbox = postbox
            self.userLocation = userLocation
            self.playlistFiles = playlistFiles
            self.qualityFiles = qualityFiles
        }
        
        deinit {
            for (_, disposable) in self.playlistFetchDisposables {
                disposable.dispose()
            }
        }
        
        func masterPlaylistData() -> Signal<String, NoError> {
            var playlistString: String = "#EXTM3U\n"
            
            for (quality, file) in self.qualityFiles.sorted(by: { $0.key > $1.key }) {
                let width = file.media.dimensions?.width ?? 1280
                let height = file.media.dimensions?.height ?? 720
                let bandwidth: Int = (file.media.size != nil && file.media.duration != nil) ? Int(Double(file.media.size!) / file.media.duration!) * 8 : 1000000
                
                playlistString += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height)\n"
                playlistString += "hls_level_\(quality).m3u8\n"
            }
            return .single(playlistString)
        }
        
        func playlistData(quality: Int) -> Signal<String, NoError> {
            guard let playlistFile = self.playlistFiles[quality] else { return .never() }
            if self.playlistFetchDisposables[quality] == nil {
                self.playlistFetchDisposables[quality] = freeMediaFileResourceInteractiveFetched(postbox: self.postbox, userLocation: self.userLocation, fileReference: playlistFile, resource: playlistFile.media.resource).startStrict()
            }
            
            return self.postbox.mediaBox.resourceData(playlistFile.media.resource)
                |> filter { $0.complete }
                |> map { data -> String in
                    guard data.complete, let data = try? Data(contentsOf: URL(fileURLWithPath: data.path)), var playlistString = String(data: data, encoding: .utf8) else {
                        return ""
                    }
                    let partRegex = try! NSRegularExpression(pattern: "mtproto:([\\d]+)", options: [])
                    for result in partRegex.matches(in: playlistString, range: NSRange(playlistString.startIndex..., in: playlistString)).reversed() {
                        if let range = Range(result.range, in: playlistString), let fileIdRange = Range(result.range(at: 1), in: playlistString) {
                            let fileId = String(playlistString[fileIdRange])
                            playlistString.replaceSubrange(range, with: "partfile\(fileId).mp4")
                        }
                    }
                    return playlistString
                }
        }
        
        func partData(index: Int, quality: Int) -> Signal<Data?, NoError> { return .never() }
    }
    
    private let postbox: Postbox
    private let userLocation: MediaResourceUserLocation
    private let fileReference: FileMediaReference
    private let approximateDuration: Double
    private let intrinsicDimensions: CGSize
    private let audioSessionManager: ManagedAudioSession
    private let audioSessionDisposable = MetaDisposable()
    private var hasAudioSession = false
    private var initializedStatus = false
    private var statusValue = MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: CGSize(), timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true)
    private let _status = ValuePromise<MediaPlayerStatus>()
    var status: Signal<MediaPlayerStatus, NoError> { return self._status.get() }
    private var hlsPlayer: HLSMediaPlayer?
    private var statusTimer: Timer?
    private var playerSource: HLSServerSource?
    
    init(accountId: AccountRecordId, postbox: Postbox, audioSessionManager: ManagedAudioSession, userLocation: MediaResourceUserLocation, fileReference: FileMediaReference, streamVideo: Bool, loopVideo: Bool, enableSound: Bool, baseRate: Double, fetchAutomatically: Bool) {
        self.postbox = postbox
        self.userLocation = userLocation
        self.fileReference = fileReference
        self.approximateDuration = fileReference.media.duration ?? 0.0
        self.audioSessionManager = audioSessionManager
        self.intrinsicDimensions = fileReference.media.dimensions?.cgSize ?? CGSize(width: 480, height: 320)
        
        super.init()

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: self.intrinsicDimensions)
        self.hlsPlayer = HLSMediaPlayer(videoLayer: videoLayer)
        
        self.hlsPlayer?.setVolume(enableSound ? 1.0 : 0.0)
        self.layer.addSublayer(videoLayer)

        self.imageNode = TransformImageNode()
        self.addSubnode(self.imageNode)
        
        self._status.set(self.statusValue)
    }

    func play() {
        guard let playerSource = self.playerSource else { return }
        let assetUrl = "http://127.0.0.1:\(SharedHLSServer.shared.port)/\(playerSource.id)/master.m3u8"
        self.hlsPlayer?.play(streamURL: URL(string: assetUrl)!)
        self.startStatusTimer()
    }

    func pause() {
        self.hlsPlayer?.pause()
        self.stopStatusTimer()
    }

    private func startStatusTimer() {
        self.statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateStatus()
        }
    }

    private func stopStatusTimer() {
        self.statusTimer?.invalidate()
        self.statusTimer = nil
    }

    private func updateStatus() {
        let currentTime = self.hlsPlayer?.currentTime ?? 0.0
        self.statusValue = MediaPlayerStatus(
            generationTimestamp: CACurrentMediaTime(),
            duration: self.approximateDuration,
            dimensions: CGSize(),
            timestamp: currentTime.isFinite ? currentTime : 0.0,
            baseRate: self.baseRate,
            seekId: self.seekId,
            status: .playing,
            soundEnabled: true
        )
        self._status.set(self.statusValue)
    }

    func setSoundEnabled(_ value: Bool) {
        self.hlsPlayer?.setVolume(value ? 1.0 : 0.0)
    }

    func togglePlayPause() {
        if self.hlsPlayer?.isPlaying ?? false {
            self.pause()
        } else {
            self.play()
        }
    }
}


private final class HLSMediaPlayer {
    private let audioEngine = AVAudioEngine()
    private let audioPlayerNode = AVAudioPlayerNode()
    private var videoLayer: CALayer?
    private var decompressionSession: VTDecompressionSession?
    private var segmentBuffer: [Data] = []
    private var isPlaying = false

    init(videoLayer: CALayer?) {
        self.videoLayer = videoLayer
        setupAudioEngine()
        if videoLayer != nil {
            setupVideoLayer()
        }
    }
    
    // MARK: - Setup
    
    private func setupAudioEngine() {
        let mainMixer = audioEngine.mainMixerNode
        audioEngine.attach(audioPlayerNode)
        audioEngine.connect(audioPlayerNode, to: mainMixer, format: nil)
        try? audioEngine.start()
    }
    
    private func setupVideoLayer() {
        guard let videoLayer = videoLayer else { return }
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.isOpaque = true
    }

    // MARK: - Playback Controls
    
    func play(streamURL: URL) {
        loadAndPlayStream(from: streamURL)
        isPlaying = true
    }
    
    func pause() {
        stopAllProcessing()
        isPlaying = false
    }

    func setVolume(_ volume: Float) {
        audioPlayerNode.volume = volume
    }

    var currentTime: Double {
        // This would return the time based on segments played
        // For now, it simulates playback time since player initialization
        return isPlaying ? CFAbsoluteTimeGetCurrent() : 0
    }

    // MARK: - Stream Loading
    
    private func loadAndPlayStream(from url: URL) {
        let segmentURLs = parseMediaPlaylist(from: url)
        for segmentURL in segmentURLs {
            downloadSegment(from: segmentURL) { [weak self] data in
                guard let data = data else { return }
                self?.bufferSegment(data)
                self?.processNextSegment()
            }
        }
    }

    private func stopAllProcessing() {
        segmentBuffer.removeAll()
        decompressionSession = nil
        audioPlayerNode.stop()
        isPlaying = false
    }

    // MARK: - Segment Processing
    
    private func processNextSegment() {
        guard let segmentData = segmentBuffer.first else { return }
        segmentBuffer.removeFirst()
        
        if let formatDescription = getVideoFormatDescription(from: segmentData) {
            if decompressionSession == nil {
                createDecompressionSession(formatDescription: formatDescription)
            }
            processDecodedVideoFrame(segmentData, formatDescription: formatDescription)  // Video
        } else {
            processDecodedAudio(segmentData)  // Audio
        }
    }

    private func createDecompressionSession(formatDescription: CMFormatDescription) {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if status == noErr {
            decompressionSession = session
        }
    }

    private func processDecodedAudio(_ data: Data) {
        guard let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
              let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(data.count) / 2) else {
            return
        }
        
        audioBuffer.frameLength = audioBuffer.frameCapacity
        let audioBufferPointer = audioBuffer.int16ChannelData
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let bufferPointer = bytes.bindMemory(to: Int16.self).baseAddress!
            for channel in 0..<Int(audioFormat.channelCount) {
                audioBufferPointer?[channel].assign(from: bufferPointer, count: Int(audioBuffer.frameLength))
            }
        }

        audioPlayerNode.scheduleBuffer(audioBuffer, completionHandler: nil)
        if !audioPlayerNode.isPlaying {
            audioPlayerNode.play()
        }
    }

    private func processDecodedVideoFrame(_ data: Data, formatDescription: CMFormatDescription) {
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: UnsafeMutableRawPointer(mutating: (data as NSData).bytes),
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        if status == noErr, let sampleBuffer = sampleBuffer {
            VTDecompressionSessionDecodeFrame(
                decompressionSession!,
                sampleBuffer: sampleBuffer,
                flags: [],
                frameRefcon: nil,
                infoFlagsOut: nil
            )
        }
    }

    private func displayDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        DispatchQueue.main.async {
            self.videoLayer?.contents = pixelBuffer
        }
    }

    // MARK: - Utilities
    
    private func getVideoFormatDescription(from data: Data) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        let parameterSetPointers: [UnsafePointer<UInt8>] = [UnsafePointer<UInt8>(data.bytes)]
        let parameterSetSizes: [Int] = [data.count]
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSetPointers.count,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDescription
        )
        return status == noErr ? formatDescription : nil
    }

    private func parseMediaPlaylist(from url: URL) -> [URL] {
        var segmentURLs: [URL] = []
        if let playlist = try? String(contentsOf: url) {
            let lines = playlist.components(separatedBy: "\n")
            for line in lines where line.hasSuffix(".ts") || line.hasSuffix(".aac") {
                if let segmentURL = URL(string: line) {
                    segmentURLs.append(segmentURL)
                }
            }
        }
        return segmentURLs
    }

    private func downloadSegment(from url: URL, completion: @escaping (Data?) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { data, _, error in
            guard error == nil, let data = data else {
                completion(nil)
                return
            }
            completion(data)
        }
        task.resume()
    }

    private func bufferSegment(_ data: Data) {
        segmentBuffer.append(data)
    }
}
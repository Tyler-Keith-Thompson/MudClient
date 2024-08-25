//
//  MSPService.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/18/24.
//

import DependencyInjection
import Afluent
import Foundation
import AVFoundation
import CryptoKit

class AudioPlayer: @unchecked Sendable {
    let lock = NSRecursiveLock()
    let player: AVAudioPlayer
    
    init(player: AVAudioPlayer) {
        self.player = player
    }
    
    func prepareToPlay() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return player.prepareToPlay()
    }

    func play() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return player.play()
    }

    @available(macOS 10.7, *)
    func play(atTime time: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return player.play(atTime: time)
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        player.pause()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        player.stop()
    }

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return player.isPlaying
    }

    var numberOfChannels: Int {
        lock.lock()
        defer { lock.unlock() }
        return player.numberOfChannels
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return player.duration
    }
    
    open var data: Data? {
        lock.lock()
        defer { lock.unlock() }
        return player.data
    }

    @available(macOS 10.7, *)
    var pan: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.pan
        } set {
            lock.lock()
            defer { lock.unlock() }
            player.pan = newValue
        }
    }

    var volume: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.volume
        } set {
            lock.lock()
            defer { lock.unlock() }
            player.volume = newValue
        }
    }

    @available(macOS 10.12, *)
    func setVolume(_ volume: Float, fadeDuration duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        player.setVolume(volume, fadeDuration: duration)
    }

    @available(macOS 10.8, *)
    var enableRate: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.enableRate
        } set {
            lock.lock()
            defer { lock.unlock() }
            player.enableRate = newValue
        }
    }

    @available(macOS 10.8, *)
    var rate: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.rate
        } set {
            lock.lock()
            defer { lock.unlock() }
            player.rate = newValue
        }
    }

    var currentTime: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.currentTime
        } set {
            lock.lock()
            defer { lock.unlock() }
            player.currentTime = newValue
        }
    }
    
    open var numberOfLoops: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.numberOfLoops
        } set {
            lock.lock()
            defer { lock.unlock() }
            player.numberOfLoops = newValue
        }
    }

    @available(macOS 10.7, *)
    var settings: [String : Any] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.settings
        }
    }

    @available(macOS 10.12, *)
    var format: AVAudioFormat {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.format
        }
    }

    open var isMeteringEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return player.isMeteringEnabled
        } set {
            lock.lock()
            defer { lock.unlock() }
            player.isMeteringEnabled = newValue
        }
    }

    func updateMeters() {
        lock.lock()
        defer { lock.unlock() }
        player.updateMeters()
    }

    func peakPower(forChannel channelNumber: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return player.peakPower(forChannel: channelNumber)
    }

    func averagePower(forChannel channelNumber: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return player.averagePower(forChannel: channelNumber)
    }
}

final class MSPService: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let cache = AsynchronousUnitOfWorkCache()
    let lock = NSRecursiveLock()
    var players = [AVAudioPlayer]()
    
    func _player(data: Data) throws -> AudioPlayer {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        lock.lock()
        players.append(player)
        lock.unlock()
        return AudioPlayer(player: player)
    }
    
    func player(_ url: URL, volume: Float = 1, loops: Int = 0) -> some AsynchronousUnitOfWork<AudioPlayer> {
        downloadOrRetrieve(url)
            .tryMap { hash, data in
                let player = try self._player(data: data)
                player.volume = volume
                player.numberOfLoops = loops
                return player
            }
    }
    
    func downloadOrRetrieve(_ url: URL) -> some AsynchronousUnitOfWork<(String, Data)> {
        DeferredTask {
            // see if data is already downloaded
            let stableHash = Insecure.MD5.hash(data: Data(url.path().utf8))
            let ext = url.pathExtension
            let documentDirectory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let fileUrl = documentDirectory.appending(path: stableHash.hexEncodedString()).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: fileUrl.path) {
                return (stableHash.hexEncodedString(), try Data(contentsOf: fileUrl))
            } else {
                let data = try Data(contentsOf: url)
                try data.write(to: fileUrl, options: .atomic)
                return (stableHash.hexEncodedString(), data)
            }
        }
        .shareFromCache(cache, strategy: .cacheUntilCompletionOrCancellation, keys: url)
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        lock.lock()
        defer { lock.unlock() }
        players.removeAll { $0 === player }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        players.removeAll { $0 === player }
    }
}

extension Container {
    static let mspService = Factory(scope: .cached) { MSPService() }
}

extension Digest {
    @inline(__always) static var bitCount: Int { byteCount * 8 }

    @inline(__always) func truncateBitLen(_ bitLen: Int) -> Data {
        let byteLen = (bitLen + 7) / 8
        let data = Data(self)
        guard byteLen <= data.count else {
            return data
        }

        var result = data.prefix(byteLen)

        if bitLen % 8 != 0 {
            let lastByteIndex = byteLen - 1
            let mask: UInt8 = ~(0xFF >> (UInt(bitLen) % 8))
            result[lastByteIndex] &= mask
        }

        return result
    }
}

extension Digest {
    @inline(__always) func hexEncodedString() -> String {
        String(unsafeUninitializedCapacity: 2 * Self.byteCount) { ptr -> Int in
            if var p = ptr.baseAddress {
                for byte in self {
                    let highNibble = byte >> 4
                    let lowNibble = byte & 0x0F

                    p[0] = highNibble < 10 ? (highNibble + 48) : (highNibble + 87)
                    p[1] = lowNibble < 10 ? (lowNibble + 48) : (lowNibble + 87)

                    p += 2
                }
            }
            return 2 * Self.byteCount
        }
    }
}

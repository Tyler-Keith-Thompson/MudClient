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

final class MSPService: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let cache = AsynchronousUnitOfWorkCache()
    let lock = NSRecursiveLock()
    var players = [AVAudioPlayer]()
    
    func _play(data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        lock.lock()
        players.append(player)
        lock.unlock()
        player.play()
    }
    
    func play(_ url: URL) -> some AsynchronousUnitOfWork<Void> {
        downloadOrRetrieve(url)
            .tryMap { hash, data in
                try self._play(data: data)
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

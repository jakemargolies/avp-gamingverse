import AVFAudio
import RealityKit

/// Table sounds, synthesized in code so the project needs no audio files. Played from entities,
/// so they come from where they happen in the room.
@MainActor
final class SoundBank {
    enum Sound: CaseIterable {
        case cardFlick, cardFlip, chipClack, chipShower, knock, swish, boom, winChime, yourTurn
    }

    private var resources: [Sound: AudioResource] = [:]
    private static let sampleRate = 44_100.0

    init() {
        for sound in Sound.allCases {
            let samples = Self.synthesize(sound)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() {
                buffer.floatChannelData![0][index] = sample
            }
            resources[sound] = try? AudioBufferResource(buffer: buffer)
        }
    }

    func play(_ sound: Sound, from entity: Entity, gain: Double = 0) {
        guard let resource = resources[sound] else { return }
        let controller = entity.playAudio(resource)
        controller.gain = gain
    }

    // MARK: - Synthesis

    private static func synthesize(_ sound: Sound) -> [Float] {
        switch sound {
        case .cardFlick:
            return noise(duration: 0.08, decay: 55, highpass: true, amplitude: 0.5)
        case .cardFlip:
            return mixed(duration: 0.12, [
                (0, noise(duration: 0.05, decay: 80, highpass: true, amplitude: 0.35)),
                (0.04, noise(duration: 0.06, decay: 70, highpass: true, amplitude: 0.45)),
            ])
        case .chipClack:
            return mixed(duration: 0.12, [(0, clack(amplitude: 0.6)), (0.022, clack(amplitude: 0.35))])
        case .chipShower:
            var hits: [(Double, [Float])] = []
            for index in 0..<10 {
                hits.append((Double(index) * 0.035 + Double.random(in: 0...0.02), clack(amplitude: Float.random(in: 0.25...0.5))))
            }
            return mixed(duration: 0.5, hits)
        case .knock:
            return mixed(duration: 0.3, [(0, thump()), (0.13, thump())])
        case .swish:
            return swish(duration: 0.3)
        case .boom:
            let length = Int(1.4 * sampleRate)
            var phase = 0.0
            return (0..<length).map { index in
                let t = Double(index) / sampleRate
                phase += 2 * .pi * (85 - 45 * min(t / 1.2, 1)) / sampleRate
                return Float(sin(phase) * exp(-t * 2.5) * 0.9)
            }
        case .winChime:
            let notes = [523.25, 659.25, 783.99, 1046.5]
            return mixed(duration: 2.0, notes.enumerated().map { index, frequency in
                (Double(index) * 0.11, tone(frequency, duration: 1.6, decay: 2.8, amplitude: 0.28))
            })
        case .yourTurn:
            return mixed(duration: 0.8, [
                (0, tone(880, duration: 0.6, decay: 7, amplitude: 0.2)),
                (0.12, tone(1318.5, duration: 0.6, decay: 7, amplitude: 0.2)),
            ])
        }
    }

    private static func noise(duration: Double, decay: Double, highpass: Bool, amplitude: Float) -> [Float] {
        var previous: Float = 0
        return (0..<Int(duration * sampleRate)).map { index in
            let t = Double(index) / sampleRate
            let sample = Float.random(in: -1...1)
            let filtered = highpass ? sample - previous : sample
            previous = sample
            return filtered * amplitude * Float(exp(-t * decay))
        }
    }

    /// A ceramic chip hitting another: a few bright, quickly decaying partials.
    private static func clack(amplitude: Float) -> [Float] {
        let partials = [3100.0, 4650.0, 6200.0].map { $0 * Double.random(in: 0.95...1.05) }
        return (0..<Int(0.06 * sampleRate)).map { index in
            let t = Double(index) / sampleRate
            let ring = partials.enumerated().reduce(0.0) { sum, partial in
                sum + sin(2 * .pi * partial.element * t) / Double(partial.offset + 1)
            }
            return Float(ring * exp(-t * 110)) * amplitude
        }
    }

    /// Knuckles on felt: a low, muffled thud.
    private static func thump() -> [Float] {
        var smoothed: Float = 0
        return (0..<Int(0.12 * sampleRate)).map { index in
            let t = Double(index) / sampleRate
            smoothed += (Float.random(in: -1...1) - smoothed) * 0.05
            return (Float(sin(2 * .pi * 120 * t)) * 0.7 + smoothed * 2) * Float(exp(-t * 40)) * 0.8
        }
    }

    private static func swish(duration: Double) -> [Float] {
        var smoothed: Float = 0
        return (0..<Int(duration * sampleRate)).map { index in
            let t = Double(index) / sampleRate
            smoothed += (Float.random(in: -1...1) - smoothed) * 0.25
            return smoothed * Float(sin(.pi * t / duration)) * 0.35
        }
    }

    private static func tone(_ frequency: Double, duration: Double, decay: Double, amplitude: Float) -> [Float] {
        (0..<Int(duration * sampleRate)).map { index in
            let t = Double(index) / sampleRate
            let attack = min(t / 0.005, 1)
            let wave = sin(2 * .pi * frequency * t) + 0.3 * sin(4 * .pi * frequency * t)
            return Float(wave * attack * exp(-t * decay)) * amplitude
        }
    }

    /// Sums sounds placed at offsets (in seconds) into one buffer.
    private static func mixed(duration: Double, _ parts: [(offset: Double, samples: [Float])]) -> [Float] {
        var output = [Float](repeating: 0, count: Int(duration * sampleRate))
        for part in parts {
            let start = Int(part.offset * sampleRate)
            for (index, sample) in part.samples.enumerated() where start + index < output.count {
                output[start + index] += sample
            }
        }
        return output
    }
}

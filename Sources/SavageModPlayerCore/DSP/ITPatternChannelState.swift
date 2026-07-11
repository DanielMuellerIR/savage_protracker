// IT trennt den logischen Pattern-Kanal von der klingenden Stimme. In M5 ist
// beiden noch genau eine Vordergrundstimme zugeordnet; der eigene Zustand hält
// aber bereits Channel Volume und Effekt-Memory, damit M7 Hintergrundstimmen
// ergänzen kann, ohne diese kanalbezogenen Werte zu vervielfachen.
public final class ITPatternChannelState: Sendable {
    public let channelIndex: Int
    nonisolated(unsafe) public var channelVolume: Float
    nonisolated(unsafe) public var channelPanning: Float
    nonisolated(unsafe) public var foregroundVoiceIndex: Int
    nonisolated(unsafe) public var isMuted: Bool
    nonisolated(unsafe) public var isSoloed: Bool

    // Index 1...26 entspricht A...Z. Das Array wird vor dem Audiostart einmal
    // angelegt; Zugriffe im Renderpfad ändern nur vorhandene Integerwerte.
    nonisolated(unsafe) private var effectMemory: [UInt8]

    public init(
        channelIndex: Int = 0,
        channelVolume: Int,
        channelPanning: Float = 0.5,
        foregroundVoiceIndex: Int? = nil,
        isMuted: Bool = false,
        isSoloed: Bool = false
    ) {
        self.channelIndex = channelIndex
        self.channelVolume = Float(max(0, min(64, channelVolume)))
        self.channelPanning = max(0, min(1, channelPanning))
        self.foregroundVoiceIndex = foregroundVoiceIndex ?? channelIndex
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.effectMemory = [UInt8](repeating: 0, count: 27)
    }

    @inline(__always)
    public func remembered(command: Int, parameter: Int, memoryCommand: Int? = nil) -> Int {
        let slot = memoryCommand ?? command
        guard (1...26).contains(slot) else { return parameter }
        if parameter != 0 {
            effectMemory[slot] = UInt8(truncatingIfNeeded: parameter)
            return parameter
        }
        return Int(effectMemory[slot])
    }
}

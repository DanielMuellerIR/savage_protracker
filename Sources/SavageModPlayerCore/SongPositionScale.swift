import Foundation

// Pure Positions-Arithmetik für den Song-Positions-Slider.
//
// Warum liegt das im Core (und nicht in der App-View)? Damit es headless
// testbar ist. Der Länge-1-Crash (2026-07-09) war genau hier: der Slider nutzte
// `in: 0...(length-1)`; bei einem Modul mit nur EINER Position (length == 1)
// wurde daraus der LEERE Bereich `0...0` → SwiftUIs `Slider` löst dann eine
// precondition aus und die App stürzt ab. Die eigentliche Slider-View ist nicht
// headless reproduzierbar, aber diese reine Arithmetik ist es — und sie hält die
// Invariante fest, die den Crash verhindert: der Bereich ist NIE leer.
public enum SongPositionScale {
    // Ergebnis für eine Slider-Ansicht über die Song-Positionen eines Moduls.
    public struct Bounds: Equatable {
        // Slider-Wertebereich; garantiert nicht leer (lowerBound < upperBound).
        public let range: ClosedRange<Double>
        // Aktueller Wert, in den Bereich geklemmt.
        public let value: Double
        // Bedienbar nur, wenn es mehr als eine Position zum Wählen gibt.
        public let isEnabled: Bool
    }

    // positionCount = Anzahl der Song-Positionen (`Mod.length`), current = aktuelle Position.
    public static func bounds(positionCount: Int, current: Int) -> Bounds {
        let lastPosition = max(0, positionCount - 1)
        // Obergrenze mindestens 1, damit 0...upper nie leer ist (Länge ≤ 1 → 0...1).
        let range = 0.0...Double(max(1, lastPosition))
        let value = Double(min(max(0, current), lastPosition))
        return Bounds(range: range, value: value, isEnabled: positionCount > 1)
    }
}

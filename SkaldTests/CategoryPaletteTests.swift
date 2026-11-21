import Foundation
import SkaldCore
import Testing
@testable import Skald

/// Machado, Oliveira and Fernandes (2009), severity 1.0, applied in linear RGB; the distance is Euclidean in sRGB.
private struct Simulation {
    let matrix: [[Double]]

    static let none = Simulation(matrix: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
    static let protanopia = Simulation(matrix: [
        [0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998],
    ])
    static let deuteranopia = Simulation(matrix: [
        [0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881],
    ])
    static let tritanopia = Simulation(matrix: [
        [1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900],
    ])

    func simulate(_ colour: CategoryPalette.RGB) -> [Double] {
        let linear = [colour.red, colour.green, colour.blue].map(linearise)
        return matrix.map { row in
            let value = zip(row, linear).reduce(0) { $0 + $1.0 * $1.1 }
            return encode(min(max(value, 0), 1))
        }
    }

    func distance(_ a: CategoryPalette.RGB, _ b: CategoryPalette.RGB) -> Double {
        let (x, y) = (simulate(a), simulate(b))
        return zip(x, y).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }
}

private func linearise(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}

private func encode(_ value: Double) -> Double {
    value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
}

private func luminance(_ colour: CategoryPalette.RGB) -> Double {
    0.2126 * linearise(colour.red) + 0.7152 * linearise(colour.green) + 0.0722 * linearise(colour.blue)
}

private func contrast(_ a: CategoryPalette.RGB, _ b: CategoryPalette.RGB) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

struct CategoryPaletteTests {
    @Test func everyPairStaysApartUnderEachDeficiency() {
        let pairs: [(IssueCategory, IssueCategory)] = [(.spelling, .grammar), (.spelling, .punctuation), (.grammar, .punctuation)]
        for matrix in [Simulation.none, .protanopia, .deuteranopia, .tritanopia] {
            for (a, b) in pairs {
                #expect(matrix.distance(CategoryPalette.rgb(a), CategoryPalette.rgb(b)) >= 0.35)
            }
        }
    }

    @Test func everyColourReadsOnALightAndOnADarkBackground() {
        for category in IssueCategory.allCases {
            #expect(contrast(CategoryPalette.rgb(category), .init(hex: 0xFFFFFF)) >= 3.2)
            #expect(contrast(CategoryPalette.rgb(category), .init(hex: 0x1E1E1E)) >= 3.2)
        }
        #expect(IssueCategory.allCases.filter(CategoryPalette.isDotted) == [.punctuation])
    }

    @Test func theColoursAreThePlansValues() {
        #expect(CategoryPalette.rgb(.spelling) == .init(hex: 0xD55E00))
        #expect(CategoryPalette.rgb(.grammar) == .init(hex: 0x0072B2))
        #expect(CategoryPalette.rgb(.punctuation) == .init(hex: 0x8B5CF6))
    }
}

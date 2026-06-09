//
//  ColorHexTests.swift
//  StampCameraTests
//
//  Color(hex:) decodes 0xRRGGBB into sRGB components.
//

import Testing
import SwiftUI
import UIKit
@testable import StampCamera

struct ColorHexTests {

    private func rgb(_ hex: UInt32) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: hex)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    @Test func pureChannels() {
        let red = rgb(0xFF0000)
        #expect(abs(red.r - 1) < 0.01 && red.g < 0.01 && red.b < 0.01)
        let green = rgb(0x00FF00)
        #expect(green.r < 0.01 && abs(green.g - 1) < 0.01 && green.b < 0.01)
        let blue = rgb(0x0000FF)
        #expect(blue.r < 0.01 && blue.g < 0.01 && abs(blue.b - 1) < 0.01)
    }

    @Test func blackAndWhite() {
        let black = rgb(0x000000)
        #expect(black.r < 0.01 && black.g < 0.01 && black.b < 0.01)
        let white = rgb(0xFFFFFF)
        #expect(abs(white.r - 1) < 0.01 && abs(white.g - 1) < 0.01 && abs(white.b - 1) < 0.01)
    }

    @Test func arbitraryColor() {
        // 0x6B8E5A — one of the album cover tints
        let c = rgb(0x6B8E5A)
        #expect(abs(c.r - 0x6B / 255.0) < 0.01)
        #expect(abs(c.g - 0x8E / 255.0) < 0.01)
        #expect(abs(c.b - 0x5A / 255.0) < 0.01)
    }
}

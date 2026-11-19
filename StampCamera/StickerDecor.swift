//
//  StickerDecor.swift
//  StampCamera
//
//  사진 앱 스티커에 없는 손질 — 테두리(굵기 · 색)와 스티커에 얹는 글자.
//  원본에서 다시 만들 때마다 마지막에 입히므로(CollectionStore.finalizeLook) 모양 · 움직임 · 색감을
//  바꿔도 사라지지 않고, 움직이는 스티커는 모든 프레임에 똑같이 입혀진다.
//

import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct StickerDecor: Equatable {
    enum Outline: String, CaseIterable, Identifiable {
        case none, thin, medium, thick
        var id: String { rawValue }
        /// 긴 변에 대한 테두리 두께 비율
        var ratio: CGFloat {
            switch self {
            case .none: return 0
            case .thin: return 0.018
            case .medium: return 0.032
            case .thick: return 0.05
            }
        }
        var title: String {
            switch self {
            case .none: return String(localized: "없음")
            case .thin: return String(localized: "얇게")
            case .medium: return String(localized: "보통")
            case .thick: return String(localized: "두껍게")
            }
        }
    }

    var outline: Outline = .none
    var color: UInt32 = 0xFFFFFF
    var label: String = ""

    static let palette: [UInt32] = [0xFFFFFF, 0x1C1C1E, 0xFFD60A, 0xFF6FAE, 0x5AC8FA, 0x34C759]

    var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isPlain: Bool { outline == .none && trimmedLabel.isEmpty }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    private static func isLight(_ hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6
    }

    /// 테두리와 글자를 입힌 새 그림. 테두리가 있으면 그 두께만큼 캔버스가 넓어진다
    /// (같은 크기의 프레임에는 같은 크기의 결과 — 움직임이 흔들리지 않는다).
    func apply(to image: UIImage) -> UIImage {
        guard !isPlain, let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let long = max(w, h)
        let radius = (outline.ratio * long).rounded()
        let pad = radius > 0 ? radius + 2 : 0
        let canvas = CGSize(width: w + 2 * pad, height: h + 2 * pad)

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        // 1) 그림 + 글자 (글자도 테두리를 함께 두르도록 팽창 전에 그린다)
        let art = UIGraphicsImageRenderer(size: canvas, format: fmt).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(x: pad, y: pad, width: w, height: h))
            drawLabel(in: CGRect(x: pad, y: pad, width: w, height: h), long: long)
        }
        guard radius > 0, let artCG = art.cgImage else { return art }

        // 2) 실루엣을 테두리 색으로 칠해 radius 만큼 부풀리고, 그 위에 그림을 얹는다
        let src = CIImage(cgImage: artCG)
        let c = CIColor(color: Self.uiColor(color))
        let tint = CIFilter.colorMatrix()
        tint.inputImage = src
        tint.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        tint.biasVector = CIVector(x: c.red, y: c.green, z: c.blue, w: 0)
        let grow = CIFilter.morphologyMaximum()
        grow.inputImage = tint.outputImage
        grow.radius = Float(radius)
        guard let ring = grow.outputImage else { return art }
        // 반투명 가장자리가 테두리를 얇게 만들지 않도록 알파를 단단하게
        let solid = ring.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        let out = src.composited(over: solid).cropped(to: src.extent)
        guard let result = Self.context.createCGImage(out, from: src.extent) else { return art }
        return UIImage(cgImage: result)
    }

    /// 아래쪽 가운데에 굵은 둥근 글자. 테두리 색 외곽선 + 대비되는 채움으로 어떤 배경에도 읽힌다.
    private func drawLabel(in rect: CGRect, long: CGFloat) {
        let text = trimmedLabel
        guard !text.isEmpty else { return }
        let strokeColor = outline == .none ? UIColor.white : Self.uiColor(color)
        let fill = Self.isLight(outline == .none ? 0xFFFFFF : color)
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) : .white
        var size = long * 0.13
        let maxWidth = rect.width * 0.92
        func attributed(_ s: CGFloat) -> NSAttributedString {
            var font = UIFont.systemFont(ofSize: s, weight: .black)
            if let rounded = font.fontDescriptor.withDesign(.rounded) {
                font = UIFont(descriptor: rounded, size: s)
            }
            return NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: fill,
                .strokeColor: strokeColor,
                .strokeWidth: -12,     // 음수 = 채우고 외곽선도
            ])
        }
        var str = attributed(size)
        while str.size().width > maxWidth, size > long * 0.04 {
            size *= 0.9
            str = attributed(size)
        }
        let sz = str.size()
        let origin = CGPoint(x: rect.midX - sz.width / 2,
                             y: rect.maxY - sz.height - rect.height * 0.04)
        str.draw(at: origin)
    }
}

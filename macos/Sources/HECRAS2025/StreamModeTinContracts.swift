import CoreGraphics
import Foundation

struct StreamModeTinAssetReference: Codable, Equatable, Hashable, Sendable {
    let sessionID: UUID
    let sequence: Int64
    let assetID: UUID
    let sha256: String
}

struct StreamModeTinAssetRequest: Encodable, Sendable {
    let asset: StreamModeTinAssetReference
}

struct StreamModeTinSessionReleaseRequest: Encodable, Sendable {
    let sessionID: UUID
}

struct StreamModeTinOptionsRequest: Encodable, Sendable {
    let assets: [StreamModeTinAssetReference]
    let selectedProfileIndex: Int
}

struct StreamModeTinOptionDescriptor: Decodable, Equatable, Identifiable, Sendable {
    let name: String
    let label: String
    let description: String
    let valueKind: String
    var currentValue: String
    let defaultValue: String
    let enumValues: [String]
    let enabledIf: String?
    let isEnabled: Bool
    let isDebug: Bool
    let sourceEffect: String

    var id: String { name }
}

struct StreamModeTinOptionsResult: Decodable, Equatable, Sendable {
    let assets: [StreamModeTinAssetReference]
    let selectedProfileIndex: Int
    let options: [StreamModeTinOptionDescriptor]
}

struct StreamModeTinViewport: Encodable, Equatable, Hashable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let pixelWidth: Int
    let pixelHeight: Int

    var isValid: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite &&
            minX < maxX && minY < maxY && pixelWidth > 0 && pixelHeight > 0
    }
}

struct StreamModeTinOptionAssignment: Encodable, Sendable {
    let name: String
    let value: String
}

struct StreamModeTinRenderRequest: Encodable, Sendable {
    let assets: [StreamModeTinAssetReference]
    let selectedProfileIndex: Int
    let requestID: UUID
    let viewport: StreamModeTinViewport
    let options: [StreamModeTinOptionAssignment]
}

struct StreamModeTinLabel: Decodable, Equatable, Sendable {
    let text: String
    let x: Double
    let y: Double
    let rotation: Double
}

struct StreamModeTinRenderResult: Decodable, Equatable, Sendable {
    let assets: [StreamModeTinAssetReference]
    let selectedProfileIndex: Int
    let requestID: UUID
    let width: Int
    let height: Int
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let rgbaBase64: String
    let labels: [StreamModeTinLabel]

    var rasterViewport: StreamModeTinViewport {
        StreamModeTinViewport(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
            pixelWidth: width, pixelHeight: height)
    }

    private var hasValidMetadata: Bool {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 4_194_304, rasterViewport.isValid,
              !assets.isEmpty, assets.indices.contains(selectedProfileIndex),
              assets.allSatisfy({ $0.sessionID == assets[0].sessionID && $0.sequence >= 0 && $0.sha256.count == 64 }) else { return false }
        return labels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.rotation.isFinite }
    }

    var isValid: Bool {
        guard hasValidMetadata, let data = Data(base64Encoded: rgbaBase64) else { return false }
        return data.count == width * height * 4
    }

    func makeImage() -> CGImage? {
        guard hasValidMetadata,
              let data = Data(base64Encoded: rgbaBase64), data.count == width * height * 4,
              let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct StreamModeTinAssetReleaseResult: Decodable, Sendable {
    let released: Bool
}

struct StreamModeTinSessionReleaseResult: Decodable, Sendable {
    let released: Bool
}

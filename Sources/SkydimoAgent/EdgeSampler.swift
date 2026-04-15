import CoreVideo
import CoreGraphics
import Foundation

struct CropRect: Sendable {
    let top: Double
    let bottom: Double
    let left: Double
    let right: Double

    static let none = CropRect(top: 0.0, bottom: 1.0, left: 0.0, right: 1.0)

    var isValid: Bool {
        return bottom > top && right > left && top >= 0.0 && bottom <= 1.0 && left >= 0.0 && right <= 1.0
    }
}

struct EdgeSampler: Sendable {
    let pixelRects: [PixelRect]
    let cropRect: CropRect

    init(width: Int, height: Int, cropRect: CropRect = .none) {
        self.cropRect = cropRect
        self.pixelRects = Self.buildPixelRects(width: width, height: height, cropRect: cropRect)
    }

    private func srgbToLinear(_ srgb: Double) -> Double {
        let normalized = srgb / 255.0
        let linear = pow(normalized, 2.2)
        return linear * 255.0
    }

    func sample(pixelBuffer: CVPixelBuffer, brightness: Double) -> [RGB] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return Array(repeating: .off, count: Constants.ledCount)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return sampleBGRA(bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow, brightness: brightness)
    }

    static func detectLetterbox(pixelBuffer: CVPixelBuffer, threshold: Int = 20) -> CropRect? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Detect top black bar
        var topBorder = 0
        for y in 0..<(height / 3) {
            var blackPixels = 0
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: 4) {
                let pixel = row.advanced(by: x * 4)
                let brightness = (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
                if brightness < threshold {
                    blackPixels += 1
                }
            }
            if blackPixels > width / 8 {
                topBorder = y
            } else {
                break
            }
        }

        // Detect bottom black bar
        var bottomBorder = height
        for y in stride(from: height - 1, to: height * 2 / 3, by: -1) {
            var blackPixels = 0
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: 4) {
                let pixel = row.advanced(by: x * 4)
                let brightness = (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
                if brightness < threshold {
                    blackPixels += 1
                }
            }
            if blackPixels > width / 8 {
                bottomBorder = y + 1
            } else {
                break
            }
        }

        // Only return crop rect if significant bars detected
        let barHeight = topBorder + (height - bottomBorder)
        if barHeight > height / 10 {
            return CropRect(
                top: Double(topBorder) / Double(height),
                bottom: Double(bottomBorder) / Double(height),
                left: 0.0,
                right: 1.0
            )
        }

        return nil
    }

    func sampleBGRA(bytes: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, brightness: Double) -> [RGB] {
        let scale = max(0.0, brightness)

        return pixelRects.map { rect in
            let x0 = max(0, min(width - 1, rect.x0))
            let y0 = max(0, min(height - 1, rect.y0))
            let x1 = max(x0 + 1, min(width, rect.x1))
            let y1 = max(y0 + 1, min(height, rect.y1))
            let rectWidth = max(1, x1 - x0)
            let rectHeight = max(1, y1 - y0)
            let sampleStepX = max(1, Int(ceil(Double(rectWidth) / 8.0)))
            let sampleStepY = max(1, Int(ceil(Double(rectHeight) / 8.0)))

            var blueTotal = 0.0
            var greenTotal = 0.0
            var redTotal = 0.0
            var count = 0

            var y = y0
            while y < y1 {
                let row = bytes.advanced(by: y * bytesPerRow)
                var x = x0
                while x < x1 {
                    let pixel = row.advanced(by: x * 4)
                    blueTotal += Double(pixel[0])
                    greenTotal += Double(pixel[1])
                    redTotal += Double(pixel[2])
                    count += 1
                    x += sampleStepX
                }
                y += sampleStepY
            }

            guard count > 0 else { return .off }

            let divisor = Double(count)
            let avgRed = redTotal / divisor
            let avgGreen = greenTotal / divisor
            let avgBlue = blueTotal / divisor

            // Apply gamma correction: sRGB to linear
            let linearRed = srgbToLinear(avgRed)
            let linearGreen = srgbToLinear(avgGreen)
            let linearBlue = srgbToLinear(avgBlue)

            return RGB(
                red: UInt8(clamping: Int((linearRed * scale).rounded())),
                green: UInt8(clamping: Int((linearGreen * scale).rounded())),
                blue: UInt8(clamping: Int((linearBlue * scale).rounded()))
            )
        }
    }

    private static func buildPixelRects(width: Int, height: Int, cropRect: CropRect) -> [PixelRect] {
        edgeLayout(cropRect: cropRect).map { rect in
            let x0 = max(0, min(width - 1, Int(rect.x0 * Double(width))))
            let y0 = max(0, min(height - 1, Int(rect.y0 * Double(height))))
            let x1 = max(x0 + 1, min(width, Int(rect.x1 * Double(width))))
            let y1 = max(y0 + 1, min(height, Int(rect.y1 * Double(height))))
            return PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
        }
    }

    private static func edgeLayout(cropRect: CropRect) -> [SampleRect] {
        let xCenters = computeCenters(count: Constants.topCount, marginSpaces: Constants.horizontalMarginSpaces)
        let yCenters = computeCenters(count: Constants.leftCount, marginSpaces: Constants.verticalMarginSpaces)
        let xBounds = computeBounds(centers: xCenters)
        let yBounds = computeBounds(centers: yCenters)

        // Apply crop rect to the bounds
        let cropTop = cropRect.top
        let cropBottom = cropRect.bottom
        let cropLeft = cropRect.left
        let cropRight = cropRect.right

        let verticalRange = cropBottom - cropTop
        let horizontalRange = cropRight - cropLeft

        let topBand = cropTop + yBounds[0] * verticalRange
        let bottomBand = cropTop + yBounds[yBounds.count - 1] * verticalRange
        let leftBand = cropLeft + xBounds[0] * horizontalRange
        let rightBand = cropLeft + xBounds[xBounds.count - 1] * horizontalRange

        let top = stride(from: Constants.topCount - 1, through: 0, by: -1).map {
            let x0 = cropLeft + xBounds[$0] * horizontalRange
            let x1 = cropLeft + xBounds[$0 + 1] * horizontalRange
            return SampleRect(x0: x0, y0: cropTop, x1: x1, y1: topBand)
        }
        let bottom = (0 ..< Constants.bottomCount).map {
            let x0 = cropLeft + xBounds[$0] * horizontalRange
            let x1 = cropLeft + xBounds[$0 + 1] * horizontalRange
            return SampleRect(x0: x0, y0: bottomBand, x1: x1, y1: cropBottom)
        }
        let left = (0 ..< Constants.leftCount).map {
            let y0 = cropTop + yBounds[$0] * verticalRange
            let y1 = cropTop + yBounds[$0 + 1] * verticalRange
            return SampleRect(x0: cropLeft, y0: y0, x1: leftBand, y1: y1)
        }
        let right = stride(from: Constants.rightCount - 1, through: 0, by: -1).map {
            let y0 = cropTop + yBounds[$0] * verticalRange
            let y1 = cropTop + yBounds[$0 + 1] * verticalRange
            return SampleRect(x0: rightBand, y0: y0, x1: cropRight, y1: y1)
        }

        return right + top + left + bottom
    }

    private static func computeCenters(count: Int, marginSpaces: Double) -> [Double] {
        guard count > 1 else { return [0.5] }
        let step = 1.0 / (Double(count - 1) + 2.0 * marginSpaces)
        return (0 ..< count).map { marginSpaces * step + Double($0) * step }
    }

    private static func computeBounds(centers: [Double]) -> [Double] {
        guard centers.count > 1 else { return [0.0, 1.0] }
        var bounds = Array(repeating: 0.0, count: centers.count + 1)
        let firstGap = centers[1] - centers[0]
        let lastGap = centers[centers.count - 1] - centers[centers.count - 2]
        bounds[0] = max(0.0, centers[0] - firstGap / 2.0)
        bounds[bounds.count - 1] = min(1.0, centers[centers.count - 1] + lastGap / 2.0)
        for index in 1 ..< centers.count {
            bounds[index] = (centers[index - 1] + centers[index]) / 2.0
        }
        return bounds
    }
}

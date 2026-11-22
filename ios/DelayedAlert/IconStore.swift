import SwiftUI
import UIKit

/// Holds the optional custom notification image. nil means "use the default app icon".
final class IconStore: ObservableObject {
    @Published var image: UIImage?

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom_icon.png")
    }
    private var url: URL { Self.fileURL }

    static func loadSaved() -> UIImage? {
        guard let d = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: d)
    }

    init() {
        if let d = try? Data(contentsOf: url) { image = UIImage(data: d) }
    }

    func set(_ data: Data) {
        guard let src = UIImage(data: data) else { return }
        let side: CGFloat = 256
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            let k = side / min(src.size.width, src.size.height)
            let w = src.size.width * k, h = src.size.height * k
            src.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        guard let png = square.pngData() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
        image = square
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        image = nil
    }
}

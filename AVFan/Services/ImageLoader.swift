import SwiftUI
import UIKit
import ImageIO

/// Loads the original decoded bitmap. Crop is applied at display time
/// (`HeroFrontWindow` / `HomeAnchoredFill`), never pre-baked into a new raster.
actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 220
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func load(_ urlString: String?, maxPixelSize: Int = 2048, timeout: TimeInterval = 20) async -> UIImage? {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        let key = "\(urlString)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[key as String] { return await existing.value }

        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue(SiteClient.mobileSafariUA, forHTTPHeaderField: "User-Agent")
            request.setValue("https://avfan.com/", forHTTPHeaderField: "Referer")
            request.setValue("image/jpeg,image/webp,image/avif,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<400).contains(status), !data.isEmpty else { return nil }
                return downsample(data, maxPixelSize: maxPixelSize)
            } catch {
                return nil
            }
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image {
            cache.setObject(image, forKey: key, cost: pixelCost(image))
        }
        return image
    }

    private func pixelCost(_ image: UIImage) -> Int {
        let w = image.cgImage?.width ?? Int(image.size.width)
        let h = image.cgImage?.height ?? Int(image.size.height)
        return max(1, w * h * 4)
    }

    private func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let limit = max(maxPixelSize, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
        return UIImage(data: data)
    }
}

/// Visible front window in the original bitmap (Build 332 display-time crop).
enum HeroFrontWindow {
    struct Placement: Equatable {
        var drawnSize: CGSize
        var offset: CGSize
        var window: CGRect
        var jacket: Bool
        var visiblePixelSize: CGSize
    }

    static func cropRect(image: UIImage, source: String?, validatedJacket: Bool = false) -> CGRect? {
        guard let source, let cg = image.cgImage else { return nil }
        return FrontPosterPolicy.cropRect(width: cg.width, height: cg.height,
                                          source: source, validatedJacket: validatedJacket)
    }

    static func placement(image: UIImage, source: String?, container: CGSize,
                          anchorY: CGFloat = 0.22, validatedJacket: Bool = false) -> Placement {
        let iw = max(image.size.width, 1)
        let ih = max(image.size.height, 1)
        let pw = max(CGFloat(image.cgImage?.width ?? Int((iw * image.scale).rounded())), 1)
        let ph = max(CGFloat(image.cgImage?.height ?? Int((ih * image.scale).rounded())), 1)
        let sx = iw / pw
        let sy = ih / ph
        let window: CGRect
        let jacket: Bool
        if let rect = cropRect(image: image, source: source, validatedJacket: validatedJacket) {
            let uiY = (ph - rect.origin.y - rect.height) * sy
            window = CGRect(x: rect.origin.x * sx, y: uiY, width: rect.width * sx, height: rect.height * sy)
            jacket = true
        } else {
            window = CGRect(x: 0, y: 0, width: iw, height: ih)
            jacket = false
        }
        let scale = max(container.width / max(window.width, 1), container.height / max(window.height, 1))
        let drawn = CGSize(width: iw * scale, height: ih * scale)
        let dww = window.width * scale
        let dwh = window.height * scale
        let x: CGFloat
        if jacket {
            x = -window.minX * scale + (container.width - dww) / 2
        } else if iw > ih {
            x = container.width - drawn.width
        } else {
            x = (container.width - drawn.width) / 2
        }
        let y = -window.minY * scale - (dwh - container.height) * anchorY
        let visible = CGSize(width: (window.width / sx), height: (window.height / sy))
        return Placement(drawnSize: drawn, offset: CGSize(width: x, height: y),
                         window: window, jacket: jacket, visiblePixelSize: visible)
    }
}

/// aspectFill of the visible front window, painting the original decoded bitmap
/// (zero pixel reprocessing). Landscape jackets are windowed at display time.
struct HomeAnchoredFill: View {
    let image: UIImage
    let size: CGSize
    var source: String? = nil
    var anchorY: CGFloat = 0.22
    var allowUpscale: Bool = true

    var body: some View {
        let p = HeroFrontWindow.placement(image: image, source: source, container: size, anchorY: anchorY)
        let interpolation: Image.Interpolation = shouldUpscale(p, container: size) ? .high : .medium
        Image(uiImage: image)
            .resizable()
            .interpolation(interpolation)
            .frame(width: p.drawnSize.width, height: p.drawnSize.height)
            .offset(x: p.offset.width, y: p.offset.height)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }

    /// Do not treat a small thumb as HQ: skip aggressive upscaling when the
    /// visible front is much smaller than the display box.
    private func shouldUpscale(_ p: HeroFrontWindow.Placement, container: CGSize) -> Bool {
        if allowUpscale { return true }
        let needed = max(container.width, container.height) * (UIScreen.main.scale)
        return max(p.visiblePixelSize.width, p.visiblePixelSize.height) >= needed * 0.72
    }
}

@MainActor
final class PosterImageModel: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false
    private var token = 0

    func load(url: String?, displayPoints: CGSize, allowUpscale: Bool) {
        token += 1
        let current = token
        image = nil
        failed = false
        guard let url, !url.isEmpty else {
            failed = true
            return
        }
        let scale = UIScreen.main.scale
        let longest = Int(max(displayPoints.width, displayPoints.height) * scale)
        // Never request more pixels than needed, but keep HQ jackets sharp.
        // Small thumbs stay at their native size (no invented HQ source).
        let cap = allowUpscale ? max(longest, 1200) : min(max(longest, 400), 900)
        Task {
            let loaded = await ImageLoader.shared.load(url, maxPixelSize: cap)
            guard current == token else { return }
            if let loaded {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// Front-cropped cover that paints the original bitmap with a 332 crop window.
struct CoverImage: View {
    let url: String?
    var anchorY: CGFloat = 0.22
    var allowUpscale: Bool = false
    var validatedJacket: Bool = false

    @StateObject private var model = PosterImageModel()
    @State private var lastURL: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                placeholder
                if let image = model.image {
                    HomeAnchoredFill(image: image, size: proxy.size, source: url,
                                     anchorY: anchorY, allowUpscale: allowUpscale)
                } else if !model.failed {
                    ProgressView().tint(.secondary)
                }
            }
            .onAppear { reload(size: proxy.size) }
            .onChange(of: url) { _, _ in reload(size: proxy.size) }
        }
    }

    private func reload(size: CGSize) {
        if lastURL != url || model.image == nil {
            lastURL = url
            model.load(url: url, displayPoints: size, allowUpscale: allowUpscale)
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.14))
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
    }
}

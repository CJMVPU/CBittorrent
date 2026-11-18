import AppKit
import RealityKit
import Metal

/// Scene geometry and native control frames share top-left window coordinates.
enum DeckLayout {
    static let window = NSRect(x: 0, y: 0, width: 932, height: 650)
    static let barHeight: CGFloat = 28
    static let title = NSRect(x: 16, y: 10, width: 900, height: barHeight)
    static let page = NSRect(x: 16, y: (window.height - 541) / 2, width: 900, height: 541)
    static let status = NSRect(x: 16, y: window.height - title.minY - barHeight, width: 900, height: barHeight)
}

@MainActor
private struct DeckScene {
    // The deck is stationary. Render once at Retina resolution, even while transfers refresh.
    func render(showsStatus: Bool) async throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        let width = Int(DeckLayout.window.width) * 2
        let height = Int(DeckLayout.window.height) * 2
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.featureUnsupported) }
        let renderer = try RealityRenderer()
        renderer.cameraSettings.colorBackground = .color(Titanium.background.cgColor)
        let camera = Entity()
        var lens = OrthographicCameraComponent()
        lens.scaleDirection = .vertical
        // Orthographic scale is the half-height of the visible area in meters.
        lens.scale = Float(DeckLayout.window.height) / 2000
        lens.near = 0.01
        lens.far = 3
        camera.components.set(lens)
        camera.position.z = 1
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let light = DirectionalLight()
        light.light.intensity = 1400
        light.look(at: .zero, from: [-1, 3, 4], relativeTo: nil)
        renderer.entities.append(light)
        renderer.entities.append(slab(DeckLayout.window, depth: 8, radius: 3, z: -8, color: Titanium.background))
        renderer.entities.append(slab(DeckLayout.page.insetBy(dx: -2, dy: -2), depth: 6, radius: 3, z: 0, color: Titanium.chrome))
        for rect in showsStatus ? [DeckLayout.title, DeckLayout.status] : [DeckLayout.title] {
            let foot = slab(rect.offsetBy(dx: 0, dy: 2), depth: 4, radius: 2, z: 0, color: Titanium.background)
            renderer.entities.append(foot)
            let beam = slab(rect, depth: 8, radius: 4, z: 5, color: Titanium.rail)
            renderer.entities.append(beam)
        }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        defer { withExtendedLifetime(renderer) {} }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output,
                    onComplete: { _ in continuation.resume() })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let stride = width * 4
        var pixels = Data(count: stride * height)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: stride,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let bitmap = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmap,
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CocoaError(.coderInvalidValue) }
        return image
    }

    private func slab(_ rect: NSRect, depth: Float, radius: Float, z: Float, color: NSColor) -> ModelEntity {
        let size = SIMD3(Float(rect.width), Float(rect.height), depth) / 1000
        let mesh = MeshResource.generateBox(size: size, cornerRadius: radius / 1000)
        let material = SimpleMaterial(color: color, roughness: 0.65, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = SIMD3(Float(rect.midX - DeckLayout.window.midX),
                                Float(DeckLayout.window.midY - rect.midY), z) / 1000
        return entity
    }
}

final class WindowDeck: SurfaceView {
    let page = SurfaceView(frame: DeckLayout.page, radius: 5)

    init(showsStatus: Bool) {
        super.init(frame: DeckLayout.window, color: Titanium.background)
        let backdrop = NSImageView(frame: bounds)
        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.setAccessibilityElement(false)
        addSubview(backdrop)
        Task { [weak backdrop] in
            do {
                let image = try await DeckScene().render(showsStatus: showsStatus)
                backdrop?.image = NSImage(cgImage: image, size: DeckLayout.window.size)
            } catch {
                NSLog("Unable to render window deck: %@", error.localizedDescription)
            }
        }
        page.layer?.masksToBounds = true
        addSubview(page)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

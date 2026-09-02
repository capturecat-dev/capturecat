import AppKit
import Metal
import QuartzCore

/// Offscreen CA compositing via CARenderer — renders a layer tree the way
/// the window server does (3D transforms, masks, shadows included).
enum CARendererSnapshot {
    static func render(layer: CALayer, size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0,
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc),
              let queue = device.makeCommandQueue() else { return nil }

        let renderer = CARenderer(mtlTexture: texture, options: nil)
        // The renderer maps its bounds onto the full texture — render the
        // layer subtree at 2× by scaling bounds.
        renderer.layer = layer
        renderer.bounds = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        // A LAYOUT-affecting mutation + flush forces the tree to commit into
        // THIS renderer's context (an opacity nudge gets coalesced away and
        // the standalone CARenderer sees an empty tree — observed as blank
        // captures). 0.0001pt is invisible at capture resolution.
        let priorTransform = layer.transform
        layer.transform = CATransform3DConcat(priorTransform, CATransform3DMakeTranslation(0.0001, 0, 0))
        CATransaction.flush()

        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil as UnsafeMutablePointer<CVTimeStamp>?)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        layer.transform = priorTransform
        CATransaction.flush()

        // CARenderer commits to its own queue; give the GPU a beat, then a
        // queue barrier for good measure before CPU readback.
        usleep(60_000)
        if let cb = queue.makeCommandBuffer() {
            cb.commit()
            cb.waitUntilCompleted()
        }

        let bpr = w * 4
        var data = Data(count: bpr * h)
        data.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: bpr,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

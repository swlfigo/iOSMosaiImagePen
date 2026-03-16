import Metal
import UIKit

class TileMetalRenderer {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // 遮罩管线 — 写入 R8 遮罩纹理
    let maskPipeline: MTLRenderPipelineState
    // Tile 合成管线 — 使用 imageblock 在 tile memory 中合成
    let tileCompositePipeline: MTLRenderPipelineState
    // Tile kernel — 在 tile memory 中执行最终混合
    let tileKernelPipeline: MTLRenderPipelineState
    // 烘焙管线 — 渲染到离屏纹理
    let bakePipeline: MTLRenderPipelineState

    var maskTexture: MTLTexture!
    var originalTexture: MTLTexture!
    var bakedTexture: MTLTexture!
    var patternTexture: MTLTexture?
    var mosaicBlockSize: Float = 20.0
    var usePatternTexture: Bool = false
    var zoomScale: CGFloat = 1.0
    var panOffset: CGPoint = .zero

    // Tile 渲染需要的 imageblock 大小
    let imageblockSampleLength: Int

    // 缓存的 memoryless 纹理（仅存在于 tile memory，零显存开销）
    private var mosaicMemorylessTex: MTLTexture?
    private var maskMemorylessTex: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        let library = device.makeDefaultLibrary()!

        // ---- 遮罩管线 ----
        let maskDesc = MTLRenderPipelineDescriptor()
        maskDesc.vertexFunction = library.makeFunction(name: "mask_vertex")
        maskDesc.fragmentFunction = library.makeFunction(name: "mask_fragment")
        maskDesc.colorAttachments[0].pixelFormat = .r8Unorm
        self.maskPipeline = try! device.makeRenderPipelineState(descriptor: maskDesc)

        // ---- Tile 合成管线 ----
        // 关键区别：输出到多个 color attachment，对应 imageblock 中的各字段
        let tileDesc = MTLRenderPipelineDescriptor()
        tileDesc.vertexFunction = library.makeFunction(name: "tile_composite_vertex")
        tileDesc.fragmentFunction = library.makeFunction(name: "tile_composite_fragment")
        // color(0) = baked (half4) → 最终输出到屏幕的 attachment
        tileDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // color(1) = mosaic (half4) → 仅存在于 imageblock，不需要 store
        tileDesc.colorAttachments[1].pixelFormat = .rgba16Float
        // color(2) = mask (half) → 仅存在于 imageblock，不需要 store
        tileDesc.colorAttachments[2].pixelFormat = .r16Float
        self.tileCompositePipeline = try! device.makeRenderPipelineState(descriptor: tileDesc)

        // ---- Tile Kernel 管线 ----
        let tileKernelDesc = MTLTileRenderPipelineDescriptor()
        tileKernelDesc.tileFunction = library.makeFunction(name: "tile_blend_kernel")!
        tileKernelDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        tileKernelDesc.colorAttachments[1].pixelFormat = .rgba16Float
        tileKernelDesc.colorAttachments[2].pixelFormat = .r16Float
        self.tileKernelPipeline = try! device.makeRenderPipelineState(tileDescriptor: tileKernelDesc, options: [], reflection: nil)

        // 计算 imageblock 每个样本需要的内存大小
        self.imageblockSampleLength = tileKernelPipeline.imageblockSampleLength

        // ---- 烘焙管线 ----
        let bakeDesc = MTLRenderPipelineDescriptor()
        bakeDesc.vertexFunction = library.makeFunction(name: "bake_vertex")
        bakeDesc.fragmentFunction = library.makeFunction(name: "bake_fragment")
        bakeDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        self.bakePipeline = try! device.makeRenderPipelineState(descriptor: bakeDesc)
    }

    // MARK: - 纹理初始化

    func setupMaskTexture(width: Int, height: Int) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        maskTexture = device.makeTexture(descriptor: desc)
        clearMask()
    }

    func loadTexture(from image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let w = cgImage.width, h = cgImage.height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        originalTexture = device.makeTexture(descriptor: desc)

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &pixels, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        originalTexture.replace(region: MTLRegionMake2D(0, 0, w, h),
                                mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)

        setupMaskTexture(width: w, height: h)
        setupBakedTexture(width: w, height: h)
    }

    private func setupBakedTexture(width: Int, height: Int) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        bakedTexture = device.makeTexture(descriptor: desc)

        guard let buf = commandQueue.makeCommandBuffer(),
              let blit = buf.makeBlitCommandEncoder() else { return }
        blit.copy(from: originalTexture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: bakedTexture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin())
        blit.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()
    }

    func loadPatternTexture(from image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let w = cgImage.width, h = cgImage.height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        patternTexture = device.makeTexture(descriptor: desc)

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &pixels, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        patternTexture!.replace(region: MTLRegionMake2D(0, 0, w, h),
                                mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        usePatternTexture = true
    }

    func clearPatternTexture() {
        patternTexture = nil
        usePatternTexture = false
    }

    // MARK: - 烘焙（保留当前笔触到底图）

    func bakeCurrentState() {
        guard let original = originalTexture, let baked = bakedTexture, let mask = maskTexture,
              let buf = commandQueue.makeCommandBuffer() else { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: baked.width, height: baked.height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        guard let newBaked = device.makeTexture(descriptor: desc) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = newBaked
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        let quad: [CompositeVertex] = [
            .init(position: SIMD2(-1, -1), texCoord: SIMD2(0, 1)),
            .init(position: SIMD2( 1, -1), texCoord: SIMD2(1, 1)),
            .init(position: SIMD2(-1,  1), texCoord: SIMD2(0, 0)),
            .init(position: SIMD2( 1,  1), texCoord: SIMD2(1, 0)),
        ]
        var uniforms = Uniforms(
            mosaicBlockSize: mosaicBlockSize,
            textureSize: SIMD2(Float(original.width), Float(original.height)),
            usePatternTexture: usePatternTexture ? 1 : 0)

        if let enc = buf.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(bakePipeline)
            enc.setVertexBytes(quad, length: quad.count * MemoryLayout<CompositeVertex>.stride, index: 0)
            enc.setFragmentTexture(original, index: 0)
            enc.setFragmentTexture(mask, index: 1)
            enc.setFragmentTexture(patternTexture ?? original, index: 2)
            enc.setFragmentTexture(baked, index: 3)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        buf.commit()
        buf.waitUntilCompleted()

        bakedTexture = newBaked
        clearMask()
    }

    func clearMask() {
        guard let mask = maskTexture,
              let buf = commandQueue.makeCommandBuffer() else { return }
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = mask
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        desc.colorAttachments[0].storeAction = .store
        let enc = buf.makeRenderCommandEncoder(descriptor: desc)!
        enc.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()
    }

    // MARK: - 等比适配

    func imageRect(in viewSize: CGSize) -> CGRect {
        guard let tex = originalTexture else { return CGRect(origin: .zero, size: viewSize) }
        let imgAR = CGFloat(tex.width) / CGFloat(tex.height)
        let viewAR = viewSize.width / viewSize.height

        if imgAR > viewAR {
            let h = viewSize.width / imgAR
            return CGRect(x: 0, y: (viewSize.height - h) / 2, width: viewSize.width, height: h)
        } else {
            let w = viewSize.height * imgAR
            return CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: viewSize.height)
        }
    }

    func zoomedImageRect(in viewSize: CGSize) -> CGRect {
        let base = imageRect(in: viewSize)
        let cx = viewSize.width / 2
        let cy = viewSize.height / 2
        return CGRect(
            x: (base.origin.x - cx) * zoomScale + cx + panOffset.x,
            y: (base.origin.y - cy) * zoomScale + cy + panOffset.y,
            width: base.width * zoomScale,
            height: base.height * zoomScale
        )
    }

    // MARK: - 几何辅助方法

    func circleVertices(center: SIMD2<Float>,
                        radiusX: Float, radiusY: Float,
                        segments: Int = 32) -> [SIMD2<Float>] {
        var v: [SIMD2<Float>] = []
        v.reserveCapacity(segments * 3)
        for i in 0..<segments {
            let a1 = Float(i) / Float(segments) * 2 * .pi
            let a2 = Float(i + 1) / Float(segments) * 2 * .pi
            v.append(center)
            v.append(SIMD2(center.x + radiusX * cos(a1), center.y + radiusY * sin(a1)))
            v.append(SIMD2(center.x + radiusX * cos(a2), center.y + radiusY * sin(a2)))
        }
        return v
    }

    func interpolate(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var result = [points[0]]
        for i in 1..<points.count {
            let p = points[i - 1], c = points[i]
            let d = hypot(c.x - p.x, c.y - p.y)
            if d > spacing {
                let steps = Int(ceil(d / spacing))
                for j in 1...steps {
                    let t = CGFloat(j) / CGFloat(steps)
                    result.append(CGPoint(x: p.x + (c.x - p.x) * t,
                                          y: p.y + (c.y - p.y) * t))
                }
            } else {
                result.append(c)
            }
        }
        return result
    }

    func pointToMaskNDC(_ pt: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
        let rect = zoomedImageRect(in: viewSize)
        let u = Float((pt.x - rect.origin.x) / rect.width)
        let v = Float((pt.y - rect.origin.y) / rect.height)
        return SIMD2(u * 2 - 1, 1 - v * 2)
    }

    // MARK: - 渲染

    /// 渲染画笔笔触：先写遮罩，再用 tile-based 合成输出
    func renderBrushPoints(_ points: [CGPoint], brushSize: Float,
                           viewSize: CGSize, drawable: CAMetalDrawable) {
        guard !points.isEmpty, let mask = maskTexture else { return }

        let rect = zoomedImageRect(in: viewSize)
        let spacing = CGFloat(brushSize) * 0.3
        let filled = interpolate(points, spacing: spacing)

        let rx = brushSize / Float(rect.width)
        let ry = brushSize / Float(rect.height)
        var verts: [SIMD2<Float>] = []
        for pt in filled {
            let ndc = pointToMaskNDC(pt, viewSize: viewSize)
            verts.append(contentsOf: circleVertices(center: ndc, radiusX: rx, radiusY: ry))
        }
        guard !verts.isEmpty,
              let buf = commandQueue.makeCommandBuffer() else { return }

        // 第一步 — 遮罩渲染通道（与原项目相同，写入独立 R8 纹理）
        let maskPass = MTLRenderPassDescriptor()
        maskPass.colorAttachments[0].texture = mask
        maskPass.colorAttachments[0].loadAction = .load
        maskPass.colorAttachments[0].storeAction = .store
        if let enc = buf.makeRenderCommandEncoder(descriptor: maskPass) {
            enc.setRenderPipelineState(maskPipeline)
            let byteLength = verts.count * MemoryLayout<SIMD2<Float>>.stride
            if byteLength <= 4096 {
                enc.setVertexBytes(verts, length: byteLength, index: 0)
            } else {
                guard let vertexBuffer = device.makeBuffer(bytes: verts, length: byteLength, options: .storageModeShared) else {
                    enc.endEncoding()
                    return
                }
                enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
            enc.endEncoding()
        }

        // 第二步 — Tile-based 合成渲染
        encodeTileComposite(buf: buf, drawable: drawable, viewSize: viewSize)
        buf.present(drawable)
        buf.commit()
    }

    /// 渲染完整画面（无新笔触，仅刷新显示）
    func renderFullFrame(drawable: CAMetalDrawable, viewSize: CGSize) {
        guard let buf = commandQueue.makeCommandBuffer() else { return }
        encodeTileComposite(buf: buf, drawable: drawable, viewSize: viewSize)
        buf.present(drawable)
        buf.commit()
    }

    /// 创建或复用 memoryless 纹理（尺寸变化时重建）
    private func ensureMemorylessTexture(_ tex: inout MTLTexture?,
                                          pixelFormat: MTLPixelFormat,
                                          width: Int, height: Int) -> MTLTexture? {
        if let t = tex, t.width == width, t.height == height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .memoryless
        tex = device.makeTexture(descriptor: desc)
        return tex
    }

    /// 编码 Tile-based 合成渲染通道
    /// 与原项目的 encodeComposite 对比：
    /// - 原项目：fragment shader 直接输出最终颜色
    /// - Tile 方案：fragment shader 写入 imageblock → tile kernel 在 tile memory 中合成 → 输出
    private func encodeTileComposite(buf: MTLCommandBuffer, drawable: CAMetalDrawable, viewSize: CGSize) {
        guard let original = originalTexture, let mask = maskTexture, let baked = bakedTexture else { return }

        let pass = MTLRenderPassDescriptor()

        // color(0) — 最终输出到屏幕，也是 imageblock 中 baked 字段的存储位置
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store  // tile kernel 写入的结果需要 store 到屏幕

        // color(1) — mosaic 数据，仅在 imageblock 中使用，不需要写回显存
        // 必须分配 memoryless 纹理：仅存在于 tile memory，零显存开销
        let drawableSize = drawable.texture
        pass.colorAttachments[1].texture = ensureMemorylessTexture(
            &mosaicMemorylessTex, pixelFormat: .rgba16Float,
            width: drawableSize.width, height: drawableSize.height)
        pass.colorAttachments[1].loadAction = .clear       // 关键修复：clear 确保 tile memory 初始为零
        pass.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[1].storeAction = .dontCare   // 不 store = 不写回显存 = 节省带宽

        // color(2) — mask 数据，仅在 imageblock 中使用
        pass.colorAttachments[2].texture = ensureMemorylessTexture(
            &maskMemorylessTex, pixelFormat: .r16Float,
            width: drawableSize.width, height: drawableSize.height)
        pass.colorAttachments[2].loadAction = .clear
        pass.colorAttachments[2].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[2].storeAction = .dontCare

        // 设置 imageblock 每个样本的内存大小
        pass.imageblockSampleLength = imageblockSampleLength

        // 计算缩放后的图片显示区域
        let rect = zoomedImageRect(in: viewSize)
        let left   = Float(rect.minX / viewSize.width) * 2 - 1
        let right  = Float(rect.maxX / viewSize.width) * 2 - 1
        let top    = 1 - Float(rect.minY / viewSize.height) * 2
        let bottom = 1 - Float(rect.maxY / viewSize.height) * 2

        let quad: [CompositeVertex] = [
            .init(position: SIMD2(left,  bottom), texCoord: SIMD2(0, 1)),
            .init(position: SIMD2(right, bottom), texCoord: SIMD2(1, 1)),
            .init(position: SIMD2(left,  top),    texCoord: SIMD2(0, 0)),
            .init(position: SIMD2(right, top),    texCoord: SIMD2(1, 0)),
        ]
        var uniforms = Uniforms(
            mosaicBlockSize: mosaicBlockSize,
            textureSize: SIMD2(Float(original.width), Float(original.height)),
            usePatternTexture: usePatternTexture ? 1 : 0)

        guard let enc = buf.makeRenderCommandEncoder(descriptor: pass) else { return }

        // 第一步：Fragment shader 采样纹理 → 写入 imageblock
        enc.setRenderPipelineState(tileCompositePipeline)
        enc.setVertexBytes(quad, length: quad.count * MemoryLayout<CompositeVertex>.stride, index: 0)
        enc.setFragmentTexture(original, index: 0)
        enc.setFragmentTexture(mask, index: 1)
        enc.setFragmentTexture(patternTexture ?? original, index: 2)
        enc.setFragmentTexture(baked, index: 3)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // 第二步：Tile kernel 在 tile memory 中完成合成
        // 注意：这一步和上一步在同一个 render pass 内，数据通过 imageblock 传递
        enc.setRenderPipelineState(tileKernelPipeline)
        enc.dispatchThreadsPerTile(enc.tileWidth > 0
            ? MTLSize(width: enc.tileWidth, height: enc.tileHeight, depth: 1)
            : MTLSize(width: 32, height: 32, depth: 1))

        enc.endEncoding()
    }

    // MARK: - 遮罩快照（用于撤销/重做）

    func snapshotMask() -> MTLTexture? {
        guard let src = maskTexture,
              let buf = commandQueue.makeCommandBuffer(),
              let blit = buf.makeBlitCommandEncoder() else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: src.pixelFormat, width: src.width, height: src.height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let dst = device.makeTexture(descriptor: desc) else { return nil }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()
        return dst
    }

    func exportImage() -> UIImage? {
        bakeCurrentState()
        guard let baked = bakedTexture else { return nil }

        let w = baked.width, h = baked.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let readable = device.makeTexture(descriptor: desc),
              let buf = commandQueue.makeCommandBuffer(),
              let blit = buf.makeBlitCommandEncoder() else { return nil }

        blit.copy(from: baked, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: readable, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin())
        blit.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()

        let bytesPerRow = 4 * w
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        readable.getBytes(&pixels, bytesPerRow: bytesPerRow,
                          from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func restoreMask(from snapshot: MTLTexture) {
        guard let dst = maskTexture,
              let buf = commandQueue.makeCommandBuffer(),
              let blit = buf.makeBlitCommandEncoder() else { return }
        blit.copy(from: snapshot, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: snapshot.width, height: snapshot.height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()
    }
}

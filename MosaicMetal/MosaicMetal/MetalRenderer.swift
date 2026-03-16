import Metal
import UIKit

class MetalRenderer {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let maskPipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let bakePipeline: MTLRenderPipelineState

    var maskTexture: MTLTexture!
    var originalTexture: MTLTexture!
    var bakedTexture: MTLTexture!
    var patternTexture: MTLTexture?
    var mosaicBlockSize: Float = 20.0
    var usePatternTexture: Bool = false
    var zoomScale: CGFloat = 1.0
    var panOffset: CGPoint = .zero

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        let library = device.makeDefaultLibrary()!

        // 遮罩管线 — 输出格式为 R8Unorm（单通道灰度纹理，用于记录画笔涂抹区域）
        let maskDesc = MTLRenderPipelineDescriptor()
        maskDesc.vertexFunction = library.makeFunction(name: "mask_vertex")
        maskDesc.fragmentFunction = library.makeFunction(name: "mask_fragment")
        maskDesc.colorAttachments[0].pixelFormat = .r8Unorm
        self.maskPipeline = try! device.makeRenderPipelineState(descriptor: maskDesc)

        // 合成管线 — 输出到屏幕（BGRA8格式，CAMetalLayer 默认格式）
        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.vertexFunction = library.makeFunction(name: "composite_vertex")
        compDesc.fragmentFunction = library.makeFunction(name: "composite_fragment")
        compDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.compositePipeline = try! device.makeRenderPipelineState(descriptor: compDesc)

        // 烘焙管线 — 渲染到离屏 RGBA8 纹理（用于保存当前状态到底图）
        let bakeDesc = MTLRenderPipelineDescriptor()
        bakeDesc.vertexFunction = library.makeFunction(name: "composite_vertex")
        bakeDesc.fragmentFunction = library.makeFunction(name: "composite_fragment")
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

        // 通过 CGContext 将图片像素数据上传到 GPU 纹理
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

        // 使用 Blit 编码器将原图复制到烘焙纹理作为初始底图
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

    /// 将当前合成结果（底图 + 遮罩 + 当前样式）烘焙到新的底图纹理，然后清空遮罩。
    /// 用于切换马赛克样式时保留之前的笔触效果。
    func bakeCurrentState() {
        guard let original = originalTexture, let baked = bakedTexture, let mask = maskTexture,
              let buf = commandQueue.makeCommandBuffer() else { return }

        // 创建新纹理用于渲染（GPU 不允许同时读写同一纹理）
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: baked.width, height: baked.height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        guard let newBaked = device.makeTexture(descriptor: desc) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = newBaked
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        // 全纹理四边形（在图像空间内渲染，无需等比适配）
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

    /// 清空遮罩纹理（将所有像素清零）
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

    /// 计算图片在视图中等比显示的矩形区域（Aspect Fit）
    func imageRect(in viewSize: CGSize) -> CGRect {
        guard let tex = originalTexture else { return CGRect(origin: .zero, size: viewSize) }
        let imgAR = CGFloat(tex.width) / CGFloat(tex.height)
        let viewAR = viewSize.width / viewSize.height

        if imgAR > viewAR {
            // 图片更宽，以视图宽度为准
            let h = viewSize.width / imgAR
            return CGRect(x: 0, y: (viewSize.height - h) / 2, width: viewSize.width, height: h)
        } else {
            // 图片更高，以视图高度为准
            let w = viewSize.height * imgAR
            return CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: viewSize.height)
        }
    }

    /// 计算缩放平移后图片在视图中的显示区域
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

    /// 生成三角扇形圆形顶点（用于画笔圆点），坐标为 NDC 标准化设备坐标
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

    /// 在触摸点之间进行插值，避免快速滑动时笔触出现断裂
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

    /// 将触摸点坐标转换为遮罩纹理的 NDC 坐标（相对于图片显示区域，考虑缩放与平移）
    func pointToMaskNDC(_ pt: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
        let rect = zoomedImageRect(in: viewSize)
        let u = Float((pt.x - rect.origin.x) / rect.width)
        let v = Float((pt.y - rect.origin.y) / rect.height)
        return SIMD2(u * 2 - 1, 1 - v * 2)
    }

    // MARK: - 渲染

    /// 渲染画笔笔触：先将笔触圆点绘制到遮罩纹理，再执行合成渲染输出到屏幕
    func renderBrushPoints(_ points: [CGPoint], brushSize: Float,
                           viewSize: CGSize, drawable: CAMetalDrawable) {
        guard !points.isEmpty, let mask = maskTexture else { return }

        let rect = zoomedImageRect(in: viewSize)
        let spacing = CGFloat(brushSize) * 0.3
        let filled = interpolate(points, spacing: spacing)

        // 将画笔大小从视图坐标转换为 NDC 坐标系下的半径
        let rx = brushSize / Float(rect.width)
        let ry = brushSize / Float(rect.height)
        var verts: [SIMD2<Float>] = []
        for pt in filled {
            let ndc = pointToMaskNDC(pt, viewSize: viewSize)
            verts.append(contentsOf: circleVertices(center: ndc, radiusX: rx, radiusY: ry))
        }
        guard !verts.isEmpty,
              let buf = commandQueue.makeCommandBuffer() else { return }

        // 第一步 — 遮罩渲染通道：将画笔圆点写入遮罩纹理
        let maskPass = MTLRenderPassDescriptor()
        maskPass.colorAttachments[0].texture = mask
        maskPass.colorAttachments[0].loadAction = .load   // 保留已有遮罩数据
        maskPass.colorAttachments[0].storeAction = .store
        if let enc = buf.makeRenderCommandEncoder(descriptor: maskPass) {
            enc.setRenderPipelineState(maskPipeline)
            let byteLength = verts.count * MemoryLayout<SIMD2<Float>>.stride
            if byteLength <= 4096 {
                // 数据量小于 4KB 时直接通过 setVertexBytes 传递（避免创建 MTLBuffer 的开销）
                enc.setVertexBytes(verts, length: byteLength, index: 0)
            } else {
                // 数据量超过 4KB 时必须使用 MTLBuffer（Metal 限制 setVertexBytes 最大 4KB）
                guard let vertexBuffer = device.makeBuffer(bytes: verts, length: byteLength, options: .storageModeShared) else {
                    enc.endEncoding()
                    return
                }
                enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
            enc.endEncoding()
        }

        // 第二步 — 合成渲染通道：将原图 + 遮罩 + 马赛克效果合成输出到屏幕
        encodeComposite(buf: buf, drawable: drawable, viewSize: viewSize)
        buf.present(drawable)
        buf.commit()
    }

    /// 渲染完整画面（无新笔触，仅刷新显示）
    func renderFullFrame(drawable: CAMetalDrawable, viewSize: CGSize) {
        guard let buf = commandQueue.makeCommandBuffer() else { return }
        encodeComposite(buf: buf, drawable: drawable, viewSize: viewSize)
        buf.present(drawable)
        buf.commit()
    }

    /// 编码合成渲染通道：将原图、遮罩、马赛克纹理合成并输出到 drawable
    private func encodeComposite(buf: MTLCommandBuffer, drawable: CAMetalDrawable, viewSize: CGSize) {
        guard let original = originalTexture, let mask = maskTexture, let baked = bakedTexture else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        // 等比适配四边形：将图片显示区域映射到 NDC 坐标（考虑缩放与平移）
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

        if let enc = buf.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setVertexBytes(quad, length: quad.count * MemoryLayout<CompositeVertex>.stride, index: 0)
            enc.setFragmentTexture(original, index: 0)
            enc.setFragmentTexture(mask, index: 1)
            enc.setFragmentTexture(patternTexture ?? original, index: 2)
            enc.setFragmentTexture(baked, index: 3)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
    }

    // MARK: - 遮罩快照（用于撤销/重做）

    /// 创建当前遮罩纹理的快照副本（GPU 端 Blit 拷贝）
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

    /// 将当前画面导出为 UIImage（先烘焙当前笔触，再从 GPU 读取像素数据）
    func exportImage() -> UIImage? {
        bakeCurrentState()
        guard let baked = bakedTexture else { return nil }

        let w = baked.width, h = baked.height
        // 需要创建 shared 存储模式的纹理副本，才能从 GPU 读取像素到 CPU
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

        // 从 GPU 纹理读取像素数据到 CPU 内存，然后通过 CGContext 生成 UIImage
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

    /// 从快照恢复遮罩纹理（用于撤销操作）
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

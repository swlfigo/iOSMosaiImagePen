import UIKit
import Metal
import QuartzCore

class MosaicCanvasView: UIView {

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private(set) var renderer: MetalRenderer!
    private var displayLink: CADisplayLink?
    private var needsRedraw = false

    var brushSize: Float = 20.0
    private var currentStrokePoints: [CGPoint] = []
    private var maskSnapshotBeforeStroke: MTLTexture?

    // MARK: - 撤销管理

    private let mosaicUndoManager = UndoManager()
    override var undoManager: UndoManager? { mosaicUndoManager }
    override var canBecomeFirstResponder: Bool { true }

    // MARK: - 初始化

    func setup(device: MTLDevice, image: UIImage) {
        displayLink?.invalidate()

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = UIScreen.main.scale

        renderer = MetalRenderer(device: device)
        renderer.loadTexture(from: image)

        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
        needsRedraw = true
        becomeFirstResponder()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // 视图移出窗口时销毁 CADisplayLink，避免循环引用（CADisplayLink 强持有 target）
        if newWindow == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.drawableSize = CGSize(
            width: bounds.width * metalLayer.contentsScale,
            height: bounds.height * metalLayer.contentsScale)
        needsRedraw = true
    }

    @objc private func tick() {
        guard needsRedraw, let drawable = metalLayer.nextDrawable() else { return }
        needsRedraw = false
        renderer.renderFullFrame(drawable: drawable, viewSize: bounds.size)
    }

    // MARK: - 触摸事件

    private var hasDrawnInCurrentStroke = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self), renderer != nil else { return }
        // 笔触开始前保存遮罩快照，用于撤销时恢复
        maskSnapshotBeforeStroke = renderer.snapshotMask()
        currentStrokePoints = [pt]
        hasDrawnInCurrentStroke = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self), renderer != nil else { return }
        currentStrokePoints.append(pt)
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.renderBrushPoints(currentStrokePoints, brushSize: brushSize,
                                   viewSize: bounds.size, drawable: drawable)
        hasDrawnInCurrentStroke = true
        currentStrokePoints = [pt]
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 只有实际绘制了内容才注册撤销操作（避免单击产生空操作）
        if hasDrawnInCurrentStroke {
            registerStrokeUndo()
        }
        currentStrokePoints = []
        maskSnapshotBeforeStroke = nil
        hasDrawnInCurrentStroke = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 触摸取消时恢复到笔触开始前的遮罩状态（丢弃未完成的笔触）
        if let snapshot = maskSnapshotBeforeStroke {
            renderer?.restoreMask(from: snapshot)
            needsRedraw = true
        }
        currentStrokePoints = []
        maskSnapshotBeforeStroke = nil
        hasDrawnInCurrentStroke = false
    }

    // MARK: - 撤销 / 重做

    private func registerStrokeUndo() {
        guard let before = maskSnapshotBeforeStroke,
              let after = renderer.snapshotMask() else { return }
        registerSwap(restoreTo: before, opposite: after)
    }

    /// 递归注册撤销/重做操作：恢复到 restoreTo 纹理，同时注册反向操作实现重做
    private func registerSwap(restoreTo: MTLTexture, opposite: MTLTexture) {
        mosaicUndoManager.registerUndo(withTarget: self) { target in
            target.renderer.restoreMask(from: restoreTo)
            target.needsRedraw = true
            target.registerSwap(restoreTo: opposite, opposite: restoreTo)
        }
    }

    func performUndo() {
        mosaicUndoManager.undo()
    }

    func performRedo() {
        mosaicUndoManager.redo()
    }

    var canUndo: Bool { mosaicUndoManager.canUndo }
    var canRedo: Bool { mosaicUndoManager.canRedo }

    func setNeedsRedraw() {
        needsRedraw = true
    }

    func clearUndoHistory() {
        mosaicUndoManager.removeAllActions()
    }

    deinit { displayLink?.invalidate() }
}

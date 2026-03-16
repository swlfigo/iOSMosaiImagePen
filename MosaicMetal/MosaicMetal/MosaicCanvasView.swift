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

        setupGestures()

        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
        needsRedraw = true
        becomeFirstResponder()
    }

    // MARK: - 缩放与平移手势

    private var pinchGesture: UIPinchGestureRecognizer!
    private var panGesture: UIPanGestureRecognizer!

    private func setupGestures() {
        pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = self
        addGestureRecognizer(panGesture)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard renderer != nil else { return }
        switch gesture.state {
        case .changed:
            let center = gesture.location(in: self)
            let oldScale = renderer.zoomScale
            let newScale = min(max(1.0, oldScale * gesture.scale), 10.0)
            let r = newScale / oldScale

            let cx = bounds.width / 2
            let cy = bounds.height / 2
            renderer.panOffset = CGPoint(
                x: (center.x - cx) * (1 - r) + renderer.panOffset.x * r,
                y: (center.y - cy) * (1 - r) + renderer.panOffset.y * r
            )
            renderer.zoomScale = newScale
            gesture.scale = 1.0
            needsRedraw = true
        case .ended, .cancelled:
            snapBackIfNeeded()
        default: break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard renderer != nil, renderer.zoomScale > 1.0 else { return }
        if gesture.state == .changed {
            let t = gesture.translation(in: self)
            renderer.panOffset = CGPoint(
                x: renderer.panOffset.x + t.x,
                y: renderer.panOffset.y + t.y
            )
            gesture.setTranslation(.zero, in: self)
            needsRedraw = true
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard renderer != nil else { return }
        if renderer.zoomScale > 1.05 {
            // 双击恢复原始大小
            renderer.zoomScale = 1.0
            renderer.panOffset = .zero
            needsRedraw = true
        } else {
            // 双击放大到 3 倍，以点击位置为中心
            let center = gesture.location(in: self)
            let newScale: CGFloat = 3.0
            let r = newScale / renderer.zoomScale
            let cx = bounds.width / 2
            let cy = bounds.height / 2
            renderer.panOffset = CGPoint(
                x: (center.x - cx) * (1 - r) + renderer.panOffset.x * r,
                y: (center.y - cy) * (1 - r) + renderer.panOffset.y * r
            )
            renderer.zoomScale = newScale
            needsRedraw = true
        }
    }

    private func snapBackIfNeeded() {
        if renderer.zoomScale <= 1.05 {
            renderer.zoomScale = 1.0
            renderer.panOffset = .zero
            needsRedraw = true
        }
    }

    func resetZoom() {
        renderer?.zoomScale = 1.0
        renderer?.panOffset = .zero
        needsRedraw = true
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

// MARK: - UIGestureRecognizerDelegate

extension MosaicCanvasView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 允许捏合和双指平移手势同时识别
        let gestures: [UIGestureRecognizer?] = [pinchGesture, panGesture]
        let isOurs = gestures.contains(where: { $0 === gestureRecognizer })
        let otherIsOurs = gestures.contains(where: { $0 === otherGestureRecognizer })
        return isOurs && otherIsOurs
    }
}

import UIKit
import Metal

class ViewController: UIViewController {

    private let canvasView = TileCanvasView()
    private let slider = UISlider()
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let sizeLabel = UILabel()
    private var styleButtons: [UIButton] = []

    private let styleNames = ["Pixel", "Style1", "Style2", "Style3"]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCanvas()
        setupToolbar()
        setupStyleBar()
    }

    private func setupCanvas() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let image = UIImage(named: "cat") else {
            fatalError("Metal not supported or image not found")
        }

        // 检查是否支持 Tile Shaders（需要 Apple GPU Family 4+，即 A11/iPhone 8 以上）
        if !device.supportsFamily(.apple4) {
            let alert = UIAlertController(
                title: "不支持 Tile Shaders",
                message: "当前设备 GPU 不支持 Tile Shaders，需要 A11 (iPhone 8) 或更新的芯片。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好的", style: .default))
            present(alert, animated: true)
            return
        }

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        canvasView.setup(device: device, image: image)
    }

    private func setupToolbar() {
        let toolbar = UIStackView()
        toolbar.axis = .horizontal
        toolbar.spacing = 12
        toolbar.alignment = .center
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.tag = 100

        undoButton.setTitle("Undo", for: .normal)
        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)

        redoButton.setTitle("Redo", for: .normal)
        redoButton.addTarget(self, action: #selector(redoTapped), for: .touchUpInside)

        sizeLabel.text = "20"
        sizeLabel.textColor = .white
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        sizeLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true

        slider.minimumValue = 5
        slider.maximumValue = 50
        slider.value = 20
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        let brushLabel = UILabel()
        brushLabel.text = "Brush:"
        brushLabel.textColor = .white
        brushLabel.font = .systemFont(ofSize: 14)

        let saveButton = UIButton(type: .system)
        saveButton.setTitle("Save", for: .normal)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(redoButton)
        toolbar.addArrangedSubview(saveButton)
        toolbar.addArrangedSubview(UIView())
        toolbar.addArrangedSubview(brushLabel)
        toolbar.addArrangedSubview(slider)
        toolbar.addArrangedSubview(sizeLabel)

        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    private func setupStyleBar() {
        let styleBar = UIStackView()
        styleBar.axis = .horizontal
        styleBar.spacing = 8
        styleBar.alignment = .center
        styleBar.distribution = .fillEqually
        styleBar.translatesAutoresizingMaskIntoConstraints = false

        for (i, name) in styleNames.enumerated() {
            let btn = UIButton(type: .system)
            btn.setTitle(name, for: .normal)
            btn.tag = i
            btn.addTarget(self, action: #selector(styleTapped(_:)), for: .touchUpInside)
            btn.backgroundColor = i == 0 ? .systemBlue : .darkGray
            btn.setTitleColor(.white, for: .normal)
            btn.layer.cornerRadius = 6
            btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            styleBar.addArrangedSubview(btn)
            styleButtons.append(btn)
        }

        let toolbar = view.viewWithTag(100)!
        view.addSubview(styleBar)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: styleBar.topAnchor, constant: -8),

            styleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            styleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            styleBar.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -8),
            styleBar.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @objc private func undoTapped() { canvasView.performUndo() }
    @objc private func redoTapped() { canvasView.performRedo() }

    @objc private func saveTapped() {
        guard let image = canvasView.renderer.exportImage() else { return }
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(imageSaved(_:error:context:)), nil)
    }

    @objc private func imageSaved(_ image: UIImage, error: Error?, context: UnsafeMutableRawPointer?) {
        let title = error == nil ? "保存成功" : "保存失败"
        let msg = error?.localizedDescription ?? "图片已保存到相册"
        let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }

    @objc private func sliderChanged() {
        let val = roundf(slider.value)
        canvasView.brushSize = val
        sizeLabel.text = "\(Int(val))"
    }

    @objc private func styleTapped(_ sender: UIButton) {
        let index = sender.tag

        for btn in styleButtons {
            btn.backgroundColor = btn.tag == index ? .systemBlue : .darkGray
        }

        canvasView.renderer.bakeCurrentState()
        canvasView.clearUndoHistory()

        if index == 0 {
            canvasView.renderer.clearPatternTexture()
        } else {
            if let patternImage = UIImage(named: "mosai\(index)") {
                canvasView.renderer.loadPatternTexture(from: patternImage)
            }
        }
        canvasView.setNeedsRedraw()
    }
}

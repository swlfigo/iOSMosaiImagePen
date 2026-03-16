import Foundation
import simd

/// 合成渲染通道的顶点数据
struct CompositeVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

/// 传递给着色器的 Uniform 参数
struct Uniforms {
    var mosaicBlockSize: Float
    var textureSize: SIMD2<Float>
    var usePatternTexture: Int32
}

/// 画笔笔触数据
struct BrushStroke {
    let points: [CGPoint]
    let brushSize: Float
}

import Foundation
import simd

/// 合成渲染通道的顶点数据，与 Metal 着色器中的 CompositeVertexIn 结构体对应
struct CompositeVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

/// 传递给合成片段着色器的 Uniform 参数，与 Metal 着色器中的 Uniforms 结构体对应
struct Uniforms {
    var mosaicBlockSize: Float       // 马赛克块大小（像素）
    var textureSize: SIMD2<Float>    // 纹理尺寸（宽, 高）
    var usePatternTexture: Int32     // 0 = 像素化马赛克, 1 = 图案纹理
}

/// 画笔笔触数据
struct BrushStroke {
    let points: [CGPoint]
    let brushSize: Float
}

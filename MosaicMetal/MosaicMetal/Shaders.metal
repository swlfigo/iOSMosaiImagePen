#include <metal_stdlib>
using namespace metal;

// ========== 遮罩渲染通道 ==========

vertex float4 mask_vertex(const device float2* positions [[buffer(0)]],
                          uint vid [[vertex_id]]) {
    return float4(positions[vid], 0.0, 1.0);
}

fragment half mask_fragment() {
    return 1.0h;
}

// ========== 合成渲染通道 ==========

struct CompositeVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct CompositeVertexIn {
    float2 position;
    float2 texCoord;
};

vertex CompositeVertexOut composite_vertex(const device CompositeVertexIn* vertices [[buffer(0)]],
                                           uint vid [[vertex_id]]) {
    CompositeVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

struct Uniforms {
    float mosaicBlockSize;    // 马赛克块大小
    float2 textureSize;       // 纹理尺寸
    int usePatternTexture;    // 0 = 像素化马赛克, 1 = 图案纹理
};

fragment float4 composite_fragment(CompositeVertexOut in [[stage_in]],
                                    texture2d<float> originalTexture [[texture(0)]],
                                    texture2d<half> maskTexture [[texture(1)]],
                                    texture2d<float> patternTexture [[texture(2)]],
                                    texture2d<float> bakedTexture [[texture(3)]],
                                    constant Uniforms& uniforms [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    constexpr sampler maskSampler(mag_filter::nearest, min_filter::nearest);
    float2 uv = in.texCoord;
    half maskVal = maskTexture.sample(maskSampler, uv).r;

    if (maskVal > 0.0h) {
        if (uniforms.usePatternTexture != 0) {
            // 使用图案纹理作为马赛克效果
            return patternTexture.sample(texSampler, uv);
        } else {
            // 像素化马赛克：将UV坐标对齐到块中心，实现像素化效果
            float2 blockCount = uniforms.textureSize / uniforms.mosaicBlockSize;
            float2 mosaicUV = (floor(uv * blockCount) + 0.5) / blockCount;
            return originalTexture.sample(texSampler, mosaicUV);
        }
    } else {
        // 未被遮罩覆盖的区域，显示已烘焙的底图
        return bakedTexture.sample(texSampler, uv);
    }
}

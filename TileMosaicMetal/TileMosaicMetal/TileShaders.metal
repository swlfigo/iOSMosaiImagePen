#include <metal_stdlib>
using namespace metal;

// ========== 共享结构体 ==========

struct Uniforms {
    float mosaicBlockSize;
    float2 textureSize;
    int usePatternTexture;
};

struct CompositeVertexIn {
    float2 position;
    float2 texCoord;
};

struct CompositeVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// ========== Imageblock 结构体 ==========
// 每个像素在 tile memory 中存储的数据

struct TileData {
    half4 baked   [[color(0)]];   // 底图颜色（已烘焙的历史笔触）→ 对应 color attachment 0
    half4 mosaic  [[color(1)]];   // 马赛克效果颜色（像素化或图案）→ 对应 color attachment 1
    half  mask    [[color(2)]];   // 遮罩值（0 = 未涂, 1 = 已涂）→ 对应 color attachment 2
};

// ========== 遮罩渲染通道（与原项目相同） ==========
// 遮罩渲染独立于 tile 合成，因为它写入的是独立的 R8 纹理

vertex float4 mask_vertex(const device float2* positions [[buffer(0)]],
                          uint vid [[vertex_id]]) {
    return float4(positions[vid], 0.0, 1.0);
}

fragment half mask_fragment() {
    return 1.0h;
}

// ========== Tile 合成渲染通道 ==========

// 第一步：Vertex shader — 传递顶点位置和纹理坐标
vertex CompositeVertexOut tile_composite_vertex(const device CompositeVertexIn* vertices [[buffer(0)]],
                                                uint vid [[vertex_id]]) {
    CompositeVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

// 第二步：Fragment shader — 采样所有纹理，将数据写入 imageblock
// 这是 tile-based rendering 的关键：数据写入 tile memory 而不是直接输出颜色
struct TileFragmentOut {
    half4 baked   [[color(0)]];   // 对应 imageblock 的 baked 字段
    half4 mosaic  [[color(1)]];   // 对应 imageblock 的 mosaic 字段
    half  mask    [[color(2)]];   // 对应 imageblock 的 mask 字段
};

fragment TileFragmentOut tile_composite_fragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<half> originalTexture [[texture(0)]],
    texture2d<half> maskTexture [[texture(1)]],
    texture2d<half> patternTexture [[texture(2)]],
    texture2d<half> bakedTexture [[texture(3)]],
    constant Uniforms& uniforms [[buffer(0)]])
{
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    constexpr sampler maskSampler(mag_filter::nearest, min_filter::nearest);

    float2 uv = in.texCoord;
    half maskVal = maskTexture.sample(maskSampler, uv).r;

    // 采样底图
    half4 bakedColor = bakedTexture.sample(texSampler, uv);

    // 计算马赛克效果颜色
    half4 mosaicColor;
    if (uniforms.usePatternTexture != 0) {
        mosaicColor = patternTexture.sample(texSampler, uv);
    } else {
        // 像素化马赛克：将UV坐标对齐到块中心
        float2 blockCount = uniforms.textureSize / uniforms.mosaicBlockSize;
        float2 mosaicUV = (floor(uv * blockCount) + 0.5) / blockCount;
        mosaicColor = originalTexture.sample(texSampler, mosaicUV);
    }

    // 将所有数据写入 imageblock（tile memory）
    TileFragmentOut out;
    out.baked = bakedColor;
    out.mosaic = mosaicColor;
    out.mask = maskVal;
    return out;
}

// 第三步：Tile shader（kernel）— 在 tile memory 中完成最终合成
// 这是 tile-based rendering 的核心优势所在：
// 合成计算完全在片上高速 tile memory 中完成，无需访问外部显存
kernel void tile_blend_kernel(imageblock<TileData> block [[imageblock]],
                              ushort2 tid [[thread_position_in_threadgroup]]) {
    TileData data = block.read(tid);

    // 根据遮罩值混合底图和马赛克效果
    half4 result;
    if (data.mask > 0.0h) {
        result = data.mosaic;
    } else {
        result = data.baked;
    }

    // 将合成结果写回 imageblock 的 baked 字段
    // 最终由 render pass 的 store action 写入 color attachment（屏幕）
    data.baked = result;
    block.write(data, tid);
}

// ========== 烘焙渲染通道 ==========
// 用于保存当前状态到底图纹理（切换样式时保留笔触），不使用 tile 优化

vertex CompositeVertexOut bake_vertex(const device CompositeVertexIn* vertices [[buffer(0)]],
                                      uint vid [[vertex_id]]) {
    CompositeVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

fragment float4 bake_fragment(CompositeVertexOut in [[stage_in]],
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
            return patternTexture.sample(texSampler, uv);
        } else {
            float2 blockCount = uniforms.textureSize / uniforms.mosaicBlockSize;
            float2 mosaicUV = (floor(uv * blockCount) + 0.5) / blockCount;
            return originalTexture.sample(texSampler, mosaicUV);
        }
    } else {
        return bakedTexture.sample(texSampler, uv);
    }
}

# Metal 马赛克画笔技术详解

本文档详细解释这个项目中用到的所有 Metal 概念，适合完全不了解 Metal 的读者。

---

## 目录

1. [Metal 是什么](#1-metal-是什么)
2. [核心概念总览](#2-核心概念总览)
3. [GPU vs CPU：为什么用 Metal](#3-gpu-vs-cpu为什么用-metal)
4. [Metal 设备与命令队列](#4-metal-设备与命令队列)
5. [渲染管线（Render Pipeline）](#5-渲染管线render-pipeline)
6. [着色器（Shaders）](#6-着色器shaders)
7. [纹理（Textures）](#7-纹理textures)
8. [坐标系统：NDC 与 UV](#8-坐标系统ndc-与-uv)
9. [双通道渲染架构](#9-双通道渲染架构)
10. [马赛克效果的实现原理](#10-马赛克效果的实现原理)
11. [画笔绘制流程](#11-画笔绘制流程)
12. [烘焙机制](#12-烘焙机制)
13. [撤销/重做的实现](#13-撤销重做的实现)
14. [图片导出流程](#14-图片导出流程)
15. [CAMetalLayer vs MTKView](#15-cametallayer-vs-mtkview)
16. [文件结构与职责](#16-文件结构与职责)

---

## 1. Metal 是什么

Metal 是 Apple 提供的底层 GPU 编程框架。你可以把 GPU 想象成一个超级工厂：

- **CPU**（中央处理器）像一个超级聪明的工人，一次做一件事，但做得很灵活
- **GPU**（图形处理器）像几千个普通工人同时工作，每人做简单的事，但因为人多所以总体速度很快

在图像处理中，每个像素都需要计算颜色。一张 1920×1080 的图片有 200 多万个像素。如果让 CPU 一个个算，太慢了。GPU 可以同时处理几千个像素，速度快几个数量级。

Metal 就是你向 GPU 下达指令的方式——告诉它"怎么画"、"画什么"、"用什么颜色"。

---

## 2. 核心概念总览

把整个 Metal 渲染流程想象成一个工厂的流水线：

```
原材料（纹理/顶点数据）
    ↓
工厂入口（MTLDevice）
    ↓
任务清单（MTLCommandBuffer）
    ↓
流水线工人（MTLRenderCommandEncoder）
    ↓
流水线规则（MTLRenderPipelineState）
    ↓
加工步骤1：顶点着色器（vertex shader）— 决定形状画在哪
    ↓
加工步骤2：片段着色器（fragment shader）— 决定每个像素什么颜色
    ↓
成品出厂（渲染到屏幕或纹理）
```

---

## 3. GPU vs CPU：为什么用 Metal

原来的 OC 版本使用 Core Graphics（CPU 渲染），新版使用 Metal（GPU 渲染），区别在于：

| 方面 | Core Graphics (CPU) | Metal (GPU) |
|------|-------------------|-------------|
| 处理方式 | 逐像素串行处理 | 数千像素并行处理 |
| 马赛克计算 | 每次触摸都重新处理整张图 | 只更新遮罩区域，合成由 GPU 实时完成 |
| 内存 | 需要完整的位图副本 | 纹理存在 GPU 显存中，不占 CPU 内存 |
| 实时预览 | 有延迟感 | 60fps 流畅 |

---

## 4. Metal 设备与命令队列

### MTLDevice — GPU 设备

```swift
let device = MTLCreateSystemDefaultDevice()!
```

`MTLDevice` 代表你手机上的那块 GPU 芯片。所有 Metal 操作都从它开始：创建纹理、创建管线、创建命令队列，都需要通过它。

**类比**：`MTLDevice` 就像工厂的总经理，你要用工厂的任何资源，都要找他批准。

### MTLCommandQueue — 命令队列

```swift
let commandQueue = device.makeCommandQueue()!
```

命令队列是一个"任务排队处"。你把一个个命令缓冲（CommandBuffer）扔进去，GPU 会按顺序执行。

### MTLCommandBuffer — 命令缓冲

```swift
let buf = commandQueue.makeCommandBuffer()!
```

命令缓冲是一次完整的"任务单"。一个命令缓冲里可以包含多个渲染通道。写完所有指令后，调用 `buf.commit()` 提交给 GPU 执行。

**类比**：
- 命令队列 = 传送带
- 命令缓冲 = 传送带上的一个箱子
- 渲染通道 = 箱子里的一份具体工作指令

---

## 5. 渲染管线（Render Pipeline）

### 什么是渲染管线

渲染管线定义了 GPU 渲染时的"规则"——用哪个顶点着色器、用哪个片段着色器、输出什么格式的像素。

```swift
let pipelineDesc = MTLRenderPipelineDescriptor()
pipelineDesc.vertexFunction = library.makeFunction(name: "mask_vertex")      // 顶点着色器
pipelineDesc.fragmentFunction = library.makeFunction(name: "mask_fragment")  // 片段着色器
pipelineDesc.colorAttachments[0].pixelFormat = .r8Unorm                      // 输出像素格式
let pipeline = try! device.makeRenderPipelineState(descriptor: pipelineDesc)
```

**类比**：管线就像一条已经调好的生产线。你设好了用哪些机器（着色器）、生产什么规格的产品（像素格式），然后这条线就可以反复使用了。

### 本项目的三条管线

| 管线 | 顶点着色器 | 片段着色器 | 输出格式 | 用途 |
|------|-----------|-----------|----------|------|
| 遮罩管线 | mask_vertex | mask_fragment | R8Unorm（单通道灰度） | 记录画笔涂过的区域 |
| 合成管线 | composite_vertex | composite_fragment | BGRA8Unorm（屏幕格式） | 合成最终画面输出到屏幕 |
| 烘焙管线 | composite_vertex | composite_fragment | RGBA8Unorm（标准RGBA） | 将当前状态保存为底图 |

为什么合成管线和烘焙管线用相同的着色器但不同的格式？因为屏幕的 `CAMetalLayer` 要求 BGRA 格式，而存储用的纹理用 RGBA 格式。管线的输出格式必须和渲染目标的格式匹配。

### MTLRenderPipelineDescriptor 的像素格式

```
.r8Unorm     → 单通道，每像素 1 字节，值范围 0.0~1.0（适合遮罩：只需要"有/没有"的信息）
.bgra8Unorm  → 4 通道（蓝绿红透明），每像素 4 字节，CAMetalLayer 默认格式
.rgba8Unorm  → 4 通道（红绿蓝透明），每像素 4 字节，标准图片存储格式
```

---

## 6. 着色器（Shaders）

着色器是运行在 GPU 上的小程序，使用 Metal Shading Language（MSL）编写，语法类似 C++。

### 顶点着色器（Vertex Shader）

顶点着色器的工作是：**告诉 GPU 每个顶点画在屏幕上的哪个位置。**

```metal
vertex float4 mask_vertex(const device float2* positions [[buffer(0)]],
                          uint vid [[vertex_id]]) {
    return float4(positions[vid], 0.0, 1.0);
}
```

逐行解释：
- `vertex` — 声明这是一个顶点着色器
- `float4` — 返回类型，一个四维向量 (x, y, z, w)
- `const device float2* positions [[buffer(0)]]` — 从 CPU 传来的顶点位置数组，`[[buffer(0)]]` 表示绑定到第 0 号缓冲区槽位
- `uint vid [[vertex_id]]` — GPU 自动提供的当前顶点索引
- `return float4(positions[vid], 0.0, 1.0)` — 取出当前顶点的 2D 坐标，补上 z=0（2D不需要深度）和 w=1（标准齐次坐标）

**类比**：顶点着色器就像一个"定位员"，你给他一堆坐标点，他告诉 GPU "这个三角形的三个角在屏幕上的 A、B、C 位置"。

### 片段着色器（Fragment Shader）

片段着色器的工作是：**决定每个像素应该显示什么颜色。**

GPU 在画一个三角形时，会先用顶点着色器确定三角形的三个角在哪，然后对三角形内部的每一个像素都调用一次片段着色器来决定颜色。

#### 遮罩片段着色器

```metal
fragment half mask_fragment() {
    return 1.0h;  // 直接返回白色（表示"这里被画笔涂过了"）
}
```

这是最简单的片段着色器。所有被画笔覆盖的像素都写入 1.0（白色），没有被覆盖的地方保持 0.0（黑色）。

#### 合成片段着色器

```metal
fragment float4 composite_fragment(CompositeVertexOut in [[stage_in]],
                                    texture2d<float> originalTexture [[texture(0)]],
                                    texture2d<half> maskTexture [[texture(1)]],
                                    texture2d<float> patternTexture [[texture(2)]],
                                    texture2d<float> bakedTexture [[texture(3)]],
                                    constant Uniforms& uniforms [[buffer(0)]]) {
```

参数说明：
- `[[stage_in]]` — 从顶点着色器插值过来的数据（位置和纹理坐标）
- `[[texture(0)]]` 到 `[[texture(3)]]` — 四张纹理，分别绑定到第 0-3 号纹理槽位
- `[[buffer(0)]]` — Uniform 参数（马赛克块大小、纹理尺寸、是否使用图案纹理）

核心逻辑：

```metal
if (maskVal > 0.0h) {
    // 这个像素被画笔涂过了 → 显示马赛克效果
    if (uniforms.usePatternTexture != 0) {
        return patternTexture.sample(texSampler, uv);  // 图案纹理模式
    } else {
        // 像素化马赛克模式（下一节详细解释）
        float2 blockCount = uniforms.textureSize / uniforms.mosaicBlockSize;
        float2 mosaicUV = (floor(uv * blockCount) + 0.5) / blockCount;
        return originalTexture.sample(texSampler, mosaicUV);
    }
} else {
    // 这个像素没被涂过 → 显示底图（原图或之前烘焙的结果）
    return bakedTexture.sample(texSampler, uv);
}
```

### Sampler（采样器）

```metal
constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
constexpr sampler maskSampler(mag_filter::nearest, min_filter::nearest);
```

采样器决定从纹理读取颜色时如何处理坐标"不正好对齐像素"的情况：
- `linear`（线性插值）：取周围几个像素的加权平均值，图片显示更平滑
- `nearest`（最近邻）：直接取最近的一个像素，适合遮罩这种只需要 0/1 的值

---

## 7. 纹理（Textures）

纹理就是 GPU 端的图片。和 CPU 端的 `UIImage` 不同，纹理存储在 GPU 显存中，GPU 可以高速读写。

### 创建纹理

```swift
let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm,    // 像素格式
    width: w, height: h,        // 尺寸
    mipmapped: false)            // 是否生成多级缩略图
desc.usage = [.shaderRead, .renderTarget]  // 用途
desc.storageMode = .private                // 存储模式
let texture = device.makeTexture(descriptor: desc)
```

### Usage（用途）

| 用途 | 含义 |
|------|------|
| `.shaderRead` | 着色器可以从这个纹理读取像素（作为输入） |
| `.renderTarget` | 渲染管线可以往这个纹理写入像素（作为输出） |

一个纹理可以同时有多个用途。比如遮罩纹理既需要被写入（遮罩通道的输出），又需要被读取（合成通道的输入）。

### StorageMode（存储模式）

| 模式 | 位置 | 读写 | 适用场景 |
|------|------|------|----------|
| `.private` | 仅在 GPU 显存 | 只有 GPU 能访问 | 渲染用纹理（最高效） |
| `.shared` | CPU 和 GPU 都能访问 | 两端都能读写 | 需要 CPU 读取像素数据时（如导出图片） |

### 本项目中的纹理

| 纹理 | 格式 | 存储模式 | 用途 |
|------|------|----------|------|
| `originalTexture` | RGBA8 | shared（默认） | 用户选择的原始图片，只读 |
| `maskTexture` | R8（灰度） | private | 记录画笔涂抹区域，可读可写 |
| `bakedTexture` | RGBA8 | private | 底图（初始为原图副本，切换样式时更新） |
| `patternTexture` | RGBA8 | shared（默认） | 图案纹理素材，只读 |

### 将图片上传到 GPU

CPU 端的 `UIImage` 无法直接被 GPU 使用，需要先提取像素数据，再上传：

```swift
// 1. 通过 CGContext 将图片解码为原始像素数组
var pixels = [UInt8](repeating: 0, count: w * h * 4)  // RGBA，每像素 4 字节
let ctx = CGContext(data: &pixels, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

// 2. 将像素数据上传到 GPU 纹理
texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
```

---

## 8. 坐标系统：NDC 与 UV

Metal 使用两套坐标系统，理解它们是理解整个渲染流程的关键。

### NDC（标准化设备坐标）

NDC 是 GPU 的"屏幕坐标"，范围是：
- X 轴：-1（左边）到 +1（右边）
- Y 轴：-1（下边）到 +1（上边）

```
        +1 (顶部)
         |
-1 ------+------ +1
(左边)   |        (右边)
        -1 (底部)
```

顶点着色器的返回值就是 NDC 坐标。如果你返回 `(0, 0)`，这个顶点就在屏幕正中间。

### UV 坐标（纹理坐标）

UV 坐标用于从纹理中采样颜色，范围是：
- U 轴：0（左边）到 1（右边）
- V 轴：0（顶部）到 1（底部）

```
(0,0)-------(1,0)
  |           |
  |   纹理    |
  |           |
(0,1)-------(1,1)
```

注意 V 轴方向和 NDC 的 Y 轴相反！这也是为什么代码中的四边形顶点要把 NDC 的 top 对应 texCoord 的 (0,0)：

```swift
// NDC 左上角 → 纹理左上角
.init(position: SIMD2(left,  top),    texCoord: SIMD2(0, 0))
// NDC 左下角 → 纹理左下角
.init(position: SIMD2(left,  bottom), texCoord: SIMD2(0, 1))
```

### UIKit 触摸坐标 → NDC 坐标的转换

用户手指触摸的坐标是 UIKit 坐标系（原点在左上角，Y 轴向下），需要转换为 NDC：

```swift
func pointToMaskNDC(_ pt: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
    let rect = imageRect(in: viewSize)
    // 先算出触摸点在图片显示区域内的归一化位置 (0~1)
    let u = Float((pt.x - rect.origin.x) / rect.width)
    let v = Float((pt.y - rect.origin.y) / rect.height)
    // 转换为 NDC：u * 2 - 1 把 [0,1] 映射到 [-1,1]
    //             1 - v * 2 把 [0,1] 映射到 [1,-1]（翻转 Y 轴）
    return SIMD2(u * 2 - 1, 1 - v * 2)
}
```

---

## 9. 双通道渲染架构

这个项目的核心设计是"双通道渲染"——每次画笔移动时，GPU 执行两步操作：

### 第一步：遮罩通道（Mask Pass）

**目标**：在遮罩纹理上画出画笔涂过的区域

```
输入：画笔位置（一系列圆形的顶点坐标）
输出：遮罩纹理（白色 = 涂过，黑色 = 没涂过）

遮罩纹理示意图：
┌─────────────────────┐
│ ■■                  │  ■ = 白色（被涂过）
│  ■■■                │  · = 黑色（未涂过）
│   ■■■■              │
│    ■■■              │
│                     │
└─────────────────────┘
```

- loadAction = `.load`（保留之前画过的内容，不清空）
- 使用三角扇形组成圆形画笔形状
- 每个圆形由 32 个三角形组成

### 第二步：合成通道（Composite Pass）

**目标**：将所有纹理合成为最终画面

```
输入：原图 + 遮罩 + 马赛克纹理 + 底图
输出：屏幕画面

合成逻辑（片段着色器对每个像素执行）：
if 遮罩[当前像素] == 白色:
    if 使用图案纹理:
        输出 = 图案纹理[当前像素]
    else:
        输出 = 原图的像素化版本（马赛克）
else:
    输出 = 底图[当前像素]
```

### 渲染通道描述符（MTLRenderPassDescriptor）

每个渲染通道需要一个描述符，告诉 GPU 渲染到哪个纹理、如何初始化：

```swift
let pass = MTLRenderPassDescriptor()
pass.colorAttachments[0].texture = targetTexture    // 渲染目标
pass.colorAttachments[0].loadAction = .clear         // 开始前清空
pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1) // 清空为黑色
pass.colorAttachments[0].storeAction = .store        // 渲染完保存结果
```

- `loadAction`：
  - `.clear`：开始前用 clearColor 填充（合成通道用这个，因为要重新画整个画面）
  - `.load`：保留之前的内容（遮罩通道用这个，因为要在已有遮罩上继续添加）
- `storeAction`：
  - `.store`：渲染完保存结果到纹理
  - `.dontCare`：不需要保存（例如某些中间结果）

---

## 10. 马赛克效果的实现原理

### 像素化马赛克

像素化马赛克的原理很简单：把图片分成一个个小方块，每个方块内所有像素都显示该方块中心点的颜色。

```
原图（每个字母代表一个像素的颜色）：      马赛克后（每个块用中心颜色填充）：
A B C D E F                              B B D D F F
G H I J K L        →                    B B D D F F
M N O P Q R                              N N P P R R
S T U V W X                              N N P P R R
```

在着色器中：

```metal
float2 blockCount = uniforms.textureSize / uniforms.mosaicBlockSize;
// blockCount = 例如 (96, 54)，表示图片被分成 96×54 个马赛克块

float2 mosaicUV = (floor(uv * blockCount) + 0.5) / blockCount;
// 分解这行代码：
// uv * blockCount     → 把 UV (0~1) 映射到块坐标 (0~96)
// floor(...)          → 取整，得到当前像素属于哪个块（例如 (3, 7)）
// + 0.5               → 移到块的中心点（(3.5, 7.5)）
// / blockCount        → 转回 UV 坐标

return originalTexture.sample(texSampler, mosaicUV);
// 用块中心的 UV 去采样原图，所以一整个块内的所有像素都读取同一个颜色
```

### 图案纹理马赛克

更简单——直接用预先准备的图案纹理替换被遮罩覆盖的区域：

```metal
return patternTexture.sample(texSampler, uv);
```

图案纹理是预先制作好的马赛克效果图片（如方块拼贴、磨砂玻璃等风格），与原图尺寸相同。

---

## 11. 画笔绘制流程

当用户手指在屏幕上滑动时：

### 1. 触摸事件捕获

```
touchesBegan → 保存遮罩快照（用于撤销）
touchesMoved → 每次移动都触发一次渲染
touchesEnded → 注册撤销操作
```

### 2. 触摸点插值

手指快速滑动时，iOS 不会每个像素都报告触摸点，可能有间隔。如果不处理，画笔笔触会断断续续。

```swift
func interpolate(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint]
```

这个方法在相邻触摸点之间插入额外的点，保证间距不超过 `spacing`（设为画笔大小的 30%）。

### 3. 圆形画笔顶点生成

每个触摸点在遮罩纹理上画一个圆。圆形由 32 个三角形拼成（三角扇形）：

```
        *   *
      * · · · *
    * · · · · · *
    * · · O · · *     O = 圆心（触摸点）
    * · · · · · *     · = 三角形覆盖的像素
      * · · · *       * = 圆周上的顶点
        *   *

每个三角形 = (圆心, 圆周点A, 圆周点B)
32 个三角形 × 3 个顶点 = 96 个顶点/每个圆
```

### 4. setVertexBytes vs MTLBuffer

将顶点数据从 CPU 传到 GPU 有两种方式：

```swift
if byteLength <= 4096 {
    // 小于 4KB：直接内联传递，零开销
    enc.setVertexBytes(verts, length: byteLength, index: 0)
} else {
    // 大于 4KB：必须创建 MTLBuffer（Metal 硬性限制）
    let vertexBuffer = device.makeBuffer(bytes: verts, length: byteLength, options: .storageModeShared)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
}
```

`setVertexBytes` 的 4KB 限制是 Metal API 的硬性规定。当画笔产生大量圆形时（快速滑动），顶点数据可能超过这个限制。

---

## 12. 烘焙机制

### 为什么需要烘焙

当用户切换马赛克样式时（比如从像素化切换到图案纹理），之前画过的笔触应该保留。但如果直接切换，之前的遮罩区域会用新样式渲染，旧效果就丢失了。

**解决方案**：切换样式前，将当前画面"拍照"保存为新的底图，然后清空遮罩重新开始。

```
切换前：
原图 + 遮罩(旧笔触) + 旧样式 → 合成画面

烘焙：将合成画面保存为新底图

切换后：
原图 + 遮罩(空) + 新样式 → 新底图（包含旧效果）
                              ↑ 新笔触用新样式
                              ↑ 未涂抹区域显示新底图（保留了旧效果）
```

### 不能直接读写同一纹理

GPU 的一个重要限制：**不能在同一个渲染通道中，既从一个纹理读取数据，又向同一个纹理写入数据。**

所以烘焙时必须创建一个新纹理作为渲染目标：

```swift
// 创建新纹理
let newBaked = device.makeTexture(descriptor: desc)

// 渲染到新纹理（从旧的 bakedTexture 读取）
// ... 渲染通道 ...

// 替换引用
bakedTexture = newBaked  // 旧纹理被 ARC 释放
```

---

## 13. 撤销/重做的实现

### 遮罩快照

撤销的核心思路是：每笔开始前保存遮罩的快照，撤销时恢复快照。

```swift
// 笔触开始前
maskSnapshotBeforeStroke = renderer.snapshotMask()  // GPU 端拷贝遮罩纹理

// 笔触结束后
let before = maskSnapshotBeforeStroke  // 笔触前的遮罩
let after = renderer.snapshotMask()    // 笔触后的遮罩
```

### GPU 端纹理拷贝（Blit 编码器）

```swift
func snapshotMask() -> MTLTexture? {
    // 创建一个新纹理
    let dst = device.makeTexture(descriptor: desc)

    // 使用 Blit 编码器在 GPU 端复制纹理（不需要数据传回 CPU）
    let blit = buf.makeBlitCommandEncoder()
    blit.copy(from: src, ..., to: dst, ...)
    blit.endEncoding()
    buf.commit()
    buf.waitUntilCompleted()
    return dst
}
```

`BlitCommandEncoder`（块传输编码器）专门用于 GPU 端的数据拷贝操作，比通过 CPU 中转快得多。

### 递归撤销/重做模式

```swift
func registerSwap(restoreTo: MTLTexture, opposite: MTLTexture) {
    mosaicUndoManager.registerUndo(withTarget: self) { target in
        // 撤销时：恢复 before 遮罩
        target.renderer.restoreMask(from: restoreTo)
        target.needsRedraw = true
        // 同时注册反向操作（用于重做）
        target.registerSwap(restoreTo: opposite, opposite: restoreTo)
    }
}
```

这个递归模式的巧妙之处在于：
- 撤销时恢复 before 遮罩，同时注册 "恢复 after 遮罩" 的操作（供重做用）
- 重做时恢复 after 遮罩，同时注册 "恢复 before 遮罩" 的操作（供再次撤销用）

---

## 14. 图片导出流程

将 GPU 纹理导出为 UIImage 的流程：

```
1. 烘焙当前状态 → bakedTexture 包含完整的合成结果

2. 创建 shared 存储模式的纹理副本
   （因为 bakedTexture 是 private 模式，CPU 无法直接读取）

3. GPU 端 Blit 拷贝：bakedTexture → readable 纹理

4. 从 readable 纹理读取像素到 CPU 内存
   readable.getBytes(&pixels, ...)

5. 通过 CGContext 将像素数组转为 CGImage → UIImage
```

为什么这么复杂？因为 GPU 和 CPU 的内存是隔离的。private 模式的纹理只存在于 GPU 显存中，CPU 看不到。必须先拷贝到 shared 模式的纹理，然后才能用 `getBytes` 把像素数据拉回 CPU 内存。

---

## 15. CAMetalLayer vs MTKView

本项目选择使用 `CAMetalLayer` 而非 `MTKView`，原因是为了更深入理解 Metal 的底层工作方式。

### MTKView（高级封装）

Apple 提供的便捷视图类，封装了：
- 自动创建 `CAMetalLayer`
- 自动管理 drawable 的获取和呈现
- 内置帧率控制（`preferredFramesPerSecond`）
- 自动调用 `draw` 方法

### CAMetalLayer（底层方式）

本项目直接使用 `CAMetalLayer`：

```swift
class MosaicCanvasView: UIView {
    // 让 UIView 的 layer 变成 CAMetalLayer
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}
```

需要自己管理的事情：
- 设置 `metalLayer.device`、`pixelFormat`、`contentsScale`
- 在 `layoutSubviews` 中更新 `drawableSize`
- 使用 `CADisplayLink` 控制帧率
- 手动获取 `metalLayer.nextDrawable()`
- 手动管理 `displayLink` 的生命周期（避免循环引用）

### CADisplayLink 与脏标记

```swift
private var needsRedraw = false

@objc private func tick() {
    guard needsRedraw, let drawable = metalLayer.nextDrawable() else { return }
    needsRedraw = false
    renderer.renderFullFrame(drawable: drawable, viewSize: bounds.size)
}
```

`CADisplayLink` 每帧（1/60 秒）调用一次 `tick`，但只有 `needsRedraw = true` 时才真正渲染。这避免了画面没有变化时的无效渲染，节省 GPU 和电量。

### 循环引用问题

`CADisplayLink` 会强持有它的 `target`（即 MosaicCanvasView），导致循环引用：

```
MosaicCanvasView → displayLink → MosaicCanvasView（循环！）
```

`deinit` 永远不会被调用，因为 `displayLink` 始终持有 view。解决方案是在视图移出窗口时主动断开：

```swift
override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil {
        displayLink?.invalidate()  // 断开 displayLink 对 view 的引用
        displayLink = nil
    }
}
```

---

## 16. 文件结构与职责

```
MosaicMetal/
├── Shaders.metal          # GPU 着色器代码（遮罩通道 + 合成通道）
├── BrushStroke.swift       # CPU/GPU 共享的数据结构定义
├── MetalRenderer.swift     # Metal 渲染引擎（管线、纹理、渲染逻辑）
├── MosaicCanvasView.swift  # 画布视图（触摸事件、CADisplayLink、撤销管理）
├── ViewController.swift    # UI 界面（工具栏、样式切换、保存功能）
├── AppDelegate.swift       # 应用生命周期
├── SceneDelegate.swift     # 窗口场景管理
└── Info.plist              # 应用配置（相册权限声明等）
```

### 数据流

```
用户触摸屏幕
    ↓
MosaicCanvasView 捕获触摸点
    ↓
MetalRenderer.renderBrushPoints()
    ├── 第一步：遮罩通道 → 更新 maskTexture
    └── 第二步：合成通道 → 输出到 CAMetalLayer drawable → 显示在屏幕
    ↓
触摸结束 → 注册 UndoManager 操作（保存遮罩快照）
```

### 等比适配（Aspect Fit）

图片和屏幕通常不是相同比例。等比适配保证图片完整显示在屏幕内，不被裁剪也不变形：

```swift
func imageRect(in viewSize: CGSize) -> CGRect {
    let imgAR = CGFloat(tex.width) / CGFloat(tex.height)  // 图片宽高比
    let viewAR = viewSize.width / viewSize.height          // 视图宽高比

    if imgAR > viewAR {
        // 图片更"扁"：以视图宽度为准，高度居中
        let h = viewSize.width / imgAR
        return CGRect(x: 0, y: (viewSize.height - h) / 2, width: viewSize.width, height: h)
    } else {
        // 图片更"长"：以视图高度为准，宽度居中
        let w = viewSize.height * imgAR
        return CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: viewSize.height)
    }
}
```

这个矩形被用在两个地方：
1. **合成通道的四边形顶点**：只在图片显示区域内渲染，两侧/上下留黑
2. **触摸坐标转换**：将触摸点映射到图片内部的相对位置，而非整个视图

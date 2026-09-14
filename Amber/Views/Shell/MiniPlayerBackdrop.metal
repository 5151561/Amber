//  MiniPlayerBackdrop.metal
//  迷你播放器窗底衬第二支（Metal 动态背景）的三支着色器。
//  宿主见 MiniPlayerBackdropMetalView.swift，数值 token 见 MusicMetrics.Backdrop。
//
//  ★★ 证据分界（整份文件最重要的一句）★★
//
//  `Uniforms` 的**布局与取值**是 [实测]：368 字节、字段顺序、
//  saturation 2.0 / floor 0.07 / ceiling 0.97 / 三层周期系数 120·90·70 /
//  三层平移 (0,0,0)·(−0.5,0.7,0)·(−0.95,−0.7,0) 全部来自
//  backdrop 规格 §1.2 / §四 / §十的实测。
//
//  但**怎么用这些数**在原版里没挖出来：spec §七 第 2 项白纸黑字写着
//  「着色器如何用 floor/ceiling/padding 做网格扭曲仍需着色器本身的分析」，
//  §10.1 只钉住了「宿主侧没有每帧矩阵数学，运动全在着色器内」。
//  所以**下面每一行数学都是 [推]**——自拟的、简单稳当的一种实现，
//  能让每个 [实测] uniform 都落到它名字所指的那件事上，但不保证与原版逐像素同构。
//  逐个 [推] 点在各自函数前列了清单。

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms

/// stride 0x50 = 80 字节（`float4x4` + `float` + 对齐补白）。[实测] spec §1.2
struct BackdropModel {
    float4x4 mtx;      //单位阵，第 4 列换成本层平移 [实测] spec §十
    float timeScale;   //★ 周期（秒），不是速率——数越大转得越慢 [实测]
};

/// 368 字节。字段顺序 = 着色器的声明顺序 [MSL]，偏移 = 实测写入点 [实测]。
/// `float4 padding` 落在（16 对齐），models 从起、stride 0x50，
/// `0x120 + 0x50 = 0x170` 正好吃满 —— 两侧对齐的收口证据。
struct BackdropUniforms {
    float4x4 viewMatrix;          //[实测] 恒单位阵，宿主每帧不写
    float time;                   //[实测] 累加 1/fps，不取模
    float textureTransitionMix;   //[实测] 1 → 0 线性，0.5 秒
    float meshWarpTimeScale;      //[实测] = speed × 3.5
    float saturation;             //[实测] 上屏那趟 2.0
    float whiteScrimAlpha;        //[实测] 浅色支，恒 0.25
    float blackScrimAlpha;        //[实测] 深色支，= 0.7 − 0.4p
    float factorForDarkMode;      //[实测] 深色 0.2 / 浅色 0
    float factorForLightMode;     //[实测] 深色 0 / 浅色 0.38 或 0.08
    float floorValue;             //[实测] 0.07
    float ceilingValue;           //[实测] 0.97
    float4 padding;               //[推] 原版无写入方（静态全零）；Amber 借 xy 传画布像素宽高
    BackdropModel models[3];      //[实测] 三层同一封面、不同锚位、不同周期
};

struct BackdropVaryings {
    float4 position [[position]];
    float2 ndc;
};

/// 铺满画布的 triangle strip，四个角。顶点缓冲一个都不用（vertex_id 直接查表）。
constant float2 kQuad[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

/// [推] 三层的叠加不透明度：后层压前层，越靠后越淡。
/// 原版这个数没挖出来（不在 uniform 里，多半写死在着色器里）。
/// 取值理由：层 0 必须 1.0 才能保证画布被盖满（它是唯一居中不偏的一层，
/// 另外两层各偏出去大半张），1/2 层取 0.55/0.45 让三层都看得见又不糊成一坨。
constant float kLayerAlpha[3] = { 1.0, 0.55, 0.45 };

constant float kTwoPi = 6.28318530718;

/// [推] 封面方图铺满画布要放大多少。`length(aspect, 1)` 是画布半对角线，
/// 保证任意旋转角下方图都盖得住；再乘 1.2 留一点余量，
/// 免得三层各自偏移之后露出采样边缘（采样器是 clamp-to-edge，露出来就是拉丝）。
constant float kCoverSlack = 1.2;

// MARK: - 离屏趟：三层旋转封面

/// 全屏四边形。旋转全部放到片元里按纹理坐标做，顶点这里什么都不用算。
vertex BackdropVaryings backdrop_rotation_vertex(uint vid [[vertex_id]]) {
    BackdropVaryings out;
    float2 p = kQuad[vid];
    out.position = float4(p, 0.0, 1.0);
    out.ndc = p;
    return out;
}

/// 一层封面：按本层平移挪锚位、按本层周期转、采样封面（交叉淡化两张）。
///
/// [实测] 用到的：`models[i].mtx` 的平移列、`models[i].timeScale`（周期秒）、
///       `time`、`textureTransitionMix`。
/// [推] 自拟的：
///   1. 「周期」怎么变成角度 —— 取 `θ = 2π·time / timeScale`，即 timeScale 秒转满一圈。
///      这是「周期」二字唯一自然的读法，也对得上 spec §3.1「s 顶到 5.0 = 慢十倍」。
///   2. 旋转发生在**方形化后的 NDC**（x 先乘宽高比），否则非方形画布上会转出椭圆。
///   3. 覆盖倍率 kCoverSlack、层不透明度 kLayerAlpha。
///   4. 交叉淡化的方向：mix=1 全 source（旧图），mix=0 全 destination（新图）。
fragment float4 backdrop_rotation_fragment(BackdropVaryings in [[stage_in]],
                                           constant uint &layerIndex [[buffer(0)]],
                                           constant BackdropUniforms &u [[buffer(1)]],
                                           texture2d<float> source [[texture(0)]],
                                           texture2d<float> destination [[texture(1)]],
                                           sampler smp [[sampler(0)]]) {
    float w = max(u.padding.x, 1.0);
    float h = max(u.padding.y, 1.0);
    float aspect = w / h;

    // 方形化：x 乘宽高比，之后这个域里的「圆」才是圆。
    float2 p = float2(in.ndc.x * aspect, in.ndc.y);

    BackdropModel m = u.models[min(layerIndex, 2u)];
    // [实测] spec §十：平移藏在单位阵的第 4 列 {tx, ty, tz, 1}，量纲同 NDC。
    p -= m.mtx[3].xy;

    float theta = kTwoPi * u.time / max(m.timeScale, 0.001);
    float c = cos(theta);
    float s = sin(theta);
    float2 r = float2(p.x * c - p.y * s, p.x * s + p.y * c);

    float cover = length(float2(aspect, 1.0)) * kCoverSlack;
    float2 uv = r / cover * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;                       // Metal 纹理原点在左上

    float mixv = clamp(u.textureTransitionMix, 0.0, 1.0);
    float4 src = source.sample(smp, uv);
    float4 dst = destination.sample(smp, uv);
    float4 color = mix(dst, src, mixv);
    color.a = kLayerAlpha[min(layerIndex, 2u)];
    return color;
}

// MARK: - 上屏趟：饱和度 / 亮度钳位 / 明暗因子 / 纱罩

vertex BackdropVaryings backdrop_pinch_vertex(uint vid [[vertex_id]]) {
    BackdropVaryings out;
    float2 p = kQuad[vid];
    out.position = float4(p, 0.0, 1.0);
    out.ndc = p;
    return out;
}

/// [推] 网格扭曲的振幅：uv 域 1%。原版这个数没挖出来（spec §七 第 2 项）。
/// 取小值的理由：这一趟采的是已经糊到看不出边界的图，扭大了只会让整块背景晃，
/// 而实机上这层背景是**静止到几乎看不出在动**的（三层周期 700…1200 秒）。
constant float kMeshWarpAmplitude = 0.01;

/// BT.601 luma 权重。与 CPU 侧 `MusicMetrics.Backdrop.fixedPointLuma` 同一套系数
/// （那边是定点 2.14 的 4915/9667/1802）。[实测] spec §八
constant float3 kLumaWeights = float3(0.299, 0.587, 0.114);

/// 上屏。顺序照 spec §四 的伪代码：饱和度 → 亮度钳位 → 明暗因子 → 纱罩。
///
/// [实测] 用到的：`saturation`(2.0)、`floorValue`(0.07)、`ceilingValue`(0.97)、
///       `factorForDarkMode`、`factorForLightMode`、`blackScrimAlpha`、`whiteScrimAlpha`、
///       `meshWarpTimeScale`(= speed × 3.5)。
/// [推] 自拟的：
///   1. 网格扭曲的形状与振幅（spec §七 第 2 项明说未解），这里做成两条正弦推 uv；
///      `meshWarpTimeScale` 同样按「周期秒」读，与三层 timeScale 一致。
///   2. floor/ceiling 是**亮度**钳位（spec §四 原话「亮度钳位区间」），
///      所以按 luma 算缩放系数再乘回三通道，而不是逐通道 clamp——
///      逐通道会把有色像素扯掉色相。纯黑（luma≈0）没法「提亮到 floor」，原样放过。
///   3. 两个 scrim 无条件都叠：宿主保证不生效的那一支每帧写 0
///      （spec §四 里只有生效那一支被写，另一支停在 uniforms 的初值 0）。
fragment float4 backdrop_pinch_fragment(BackdropVaryings in [[stage_in]],
                                        constant BackdropUniforms &u [[buffer(1)]],
                                        texture2d<float> blurred [[texture(0)]],
                                        sampler smp [[sampler(0)]]) {
    float2 uv = in.ndc * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;

    float phase = kTwoPi * u.time / max(u.meshWarpTimeScale, 0.001);
    uv += float2(sin(phase + uv.y * 3.0), cos(phase + uv.x * 3.0)) * kMeshWarpAmplitude;
    uv = clamp(uv, 0.0, 1.0);

    float3 color = blurred.sample(smp, uv).rgb;

    // ① 饱和度（[实测] 2.0）
    float luma = dot(color, kLumaWeights);
    color = max(mix(float3(luma), color, u.saturation), 0.0);

    // ② 亮度钳进 [floor, ceiling]（[实测] 0.07 / 0.97）
    float l = dot(color, kLumaWeights);
    float target = clamp(l, u.floorValue, u.ceilingValue);
    color *= (l > 0.0001) ? (target / l) : 1.0;
    color = clamp(color, 0.0, 1.0);

    // ③ 明暗因子（[实测] 深色 0.2 混黑 / 浅色 0.38 或 0.08 混白）
    color = mix(color, float3(0.0), clamp(u.factorForDarkMode, 0.0, 1.0));
    color = mix(color, float3(1.0), clamp(u.factorForLightMode, 0.0, 1.0));

    // ④ 纱罩（[实测] 深色 0.7 − 0.4p / 浅色恒 0.25）
    color = mix(color, float3(0.0), clamp(u.blackScrimAlpha, 0.0, 1.0));
    color = mix(color, float3(1.0), clamp(u.whiteScrimAlpha, 0.0, 1.0));

    return float4(color, 1.0);
}

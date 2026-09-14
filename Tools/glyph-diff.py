#!/usr/bin/env python3
"""按窗口坐标逐区域比对两张窗口截图的**外观**：字形外框、等效白度、边缘锐度。

为什么需要它：AX 只报 hit box。两个 App 的按钮盒子可以逐像素对齐，而图标字号、
颜色不透明度、悬浮时是否虚化，AX 一个字都不说。实测里正是这三项差得最明显——
上一首键大了三成、未激活的随机键亮出一大截、悬浮残影该糊的没糊。

三项指标：
  外框     autocontrast 归一化后过半阈值的包围盒 → 图标画多大（与亮度无关）
  等效白度 (峰值 - 底色) / (255 - 底色) → 前景相对背景的不透明度，可直接对到
           systemPrimary 0.85 / secondary 0.55 / tertiary 0.25 这类语义色上
  边缘锐度 归一化后的水平梯度均值 → 是否被虚化。只降不透明度时这项几乎不变，
           加了 blur 才会掉下去（实测 Music 悬浮态标题 26.3 → 4.0）

用法：
  # 直接给两张 PNG 和区域表
  python3 Tools/glyph-diff.py music.png am.png --regions regions.json

  # 区域也可以写在命令行：名字:x,y,w,h（窗口坐标 point）
  python3 Tools/glyph-diff.py a.png b.png -r "播放:536.5,859,36,36" -r "音量:1126.5,859,36,36"

  # 从 ui-spec.swift 的 JSON 里按 AX 标识取框（两侧标识不同名时用 参考=候选）
  python3 Tools/glyph-diff.py music.json am.json \\
      --pairs "shuffleButton=shuffle" --pairs "volumeButton=speaker.wave.3.fill"

截图两种来源都认：`screencapture -x -l`（带阴影留白，用 alpha 定位窗口）
与 `screencapture -x -o -l`（无留白）。

读结果时注意：**文本区域的外框差异多半只是文案不同**（“有太多不能講”六个字比
“又到天黑”四个字宽），这种时候看白度与锐度即可；图标区域才该逐项都对上。
计时类的观察别用 AX 轮询——高频遍历 AX 树会卡住目标 App 的主线程，动画根本不推进，
只能像这里一样按固定间隔截图采样，且每次采样前把鼠标移开复位。
"""

from __future__ import annotations

import argparse
import json
import os
import sys

try:
    from PIL import Image, ImageOps
except ImportError:
    sys.exit("需要 Pillow：python3 -m pip install pillow")

TOL = {"box": 1.1, "white": 0.06, "sharp": 0.35}   # 外框 pt、白度、锐度相对差


# ---------- 图像与坐标 ----------

def window_origin(im):
    """截图可能含窗口阴影留白。阴影是半透明的，只有窗口本体 alpha 为 255。"""
    if im.mode != "RGBA":
        return 0, 0, im.width, im.height
    opaque = im.getchannel("A").point(lambda v: 255 if v == 255 else 0)
    box = opaque.getbbox()
    if not box:
        return 0, 0, im.width, im.height
    return box[0], box[1], box[2] - box[0], box[3] - box[1]


def load_image(path, scale_hint=None):
    im = Image.open(path)
    ox, oy, w, h = window_origin(im)
    scale = scale_hint or 2
    return {"gray": im.convert("L"), "ox": ox, "oy": oy, "w": w, "h": h, "scale": scale,
            "path": path}


def patch(img, x, y, w, h):
    s = img["scale"]
    left = img["ox"] + int(round(x * s))
    top = img["oy"] + int(round(y * s))
    right = img["ox"] + int(round((x + w) * s))
    bottom = img["oy"] + int(round((y + h) * s))
    if left < 0 or top < 0 or right > img["gray"].width or bottom > img["gray"].height:
        return None
    return img["gray"].crop((left, top, right, bottom))


# ---------- 三项指标 ----------

def measure(img, x, y, w, h, inset=2.0):
    """inset 收边，避开相邻控件与容器描边落进取样框。"""
    sub = patch(img, x + inset, y + inset, w - inset * 2, h - inset * 2)
    if sub is None or sub.width < 4 or sub.height < 4:
        return None
    px = list(sub.tobytes())          # 灰度图一像素一字节，比 getdata 快且不吃弃用告警
    ordered = sorted(px)
    bg = ordered[len(ordered) // 4]
    peak = ordered[-1]
    white = (peak - bg) / (255 - bg) if bg < 255 else 0.0

    norm = ImageOps.autocontrast(sub)          # 先抹平亮度差，再比形状与锐度
    npx = list(norm.tobytes())
    width = norm.width
    pts = [(i % width, i // width) for i, v in enumerate(npx) if v > 128]
    if pts:
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        s = img["scale"]
        box = ((max(xs) - min(xs) + 1) / s, (max(ys) - min(ys) + 1) / s)
    else:
        box = (0.0, 0.0)
    grad = sum(abs(npx[i] - npx[i + 1]) for i in range(len(npx) - 1) if (i + 1) % width)
    return {"box": box, "white": white, "sharp": grad / (norm.width * norm.height),
            "bg": bg, "peak": peak}


# ---------- 区域来源 ----------

def regions_from_cli(specs):
    out = []
    for spec in specs:
        name, _, nums = spec.partition(":")
        parts = [float(v) for v in nums.split(",")]
        if len(parts) != 4:
            sys.exit(f"区域格式应为 名字:x,y,w,h —— 收到 {spec!r}")
        out.append({"name": name or "?", "frame": parts})
    return out


def ax_nodes(doc):
    """ui-spec.swift 的 JSON：单次采集取 runtime.windows[0]，扫描取第一份样本。"""
    runtime = doc.get("runtime", doc)
    sweep = runtime.get("sweep")
    if sweep:
        samples = [s for s in sweep.get("samples", []) if "window" in s]
        if not samples:
            sys.exit("sweep 里没有可用样本")
        root, shot = samples[0]["window"], (samples[0].get("screenshot") or {}).get("path")
        size = samples[0].get("windowSize", {})
    else:
        windows = runtime.get("windows") or []
        if not windows:
            sys.exit("JSON 里没有 runtime.windows")
        root = windows[0]
        shot = (runtime.get("screenshot") or {}).get("path")
        size = root.get("frame", {})
    flat = []

    def walk(node):
        flat.append(node)
        for child in node.get("children") or []:
            walk(child)

    walk(root)
    return flat, shot, size.get("width")


def label_of(node):
    for key in ("identifier", "description", "title"):
        value = node.get(key)
        if isinstance(value, str) and value:
            return value
    value = node.get("value")
    return value if isinstance(value, str) else ""


def find_node(flat, needle):
    hits = [n for n in flat if needle in label_of(n) and n.get("frameInWindow")]
    if not hits:
        return None
    # 多个命中时取面积最小的那个：外层容器往往同名且更大
    return min(hits, key=lambda n: n["frameInWindow"]["width"] * n["frameInWindow"]["height"])


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser(description="逐区域比对两张窗口截图的外观")
    ap.add_argument("reference", help="参考侧 PNG，或 ui-spec.swift 的 JSON")
    ap.add_argument("candidate", help="候选侧 PNG，或 ui-spec.swift 的 JSON")
    ap.add_argument("-r", "--region", action="append", default=[],
                    help="名字:x,y,w,h（窗口坐标 point），可重复")
    ap.add_argument("--regions", help="区域表 JSON：[{\"name\":…,\"frame\":[x,y,w,h]}]")
    ap.add_argument("--pairs", action="append", default=[],
                    help="从 AX 取框：参考标识=候选标识，同名时可只写一个")
    ap.add_argument("--inset", type=float, default=2.0, help="取样框收边 point，默认 2")
    ap.add_argument("--scale", type=float, default=None, help="像素/point，默认按窗口宽推算")
    ap.add_argument("--crops", help="把每个区域的放大对照图写进该目录")
    ap.add_argument("--report", help="写入 Markdown")
    args = ap.parse_args()

    def side(path):
        if path.lower().endswith(".json"):
            with open(path, encoding="utf-8") as handle:
                doc = json.load(handle)
            flat, shot, width = ax_nodes(doc)
            if not shot or not os.path.exists(shot):
                sys.exit(f"{path} 里没有可用的截图路径；采集时请加 --screenshot/--screenshot-dir")
            return flat, shot, width
        return None, path, None

    ref_flat, ref_png, ref_w = side(args.reference)
    cand_flat, cand_png, cand_w = side(args.candidate)

    regions = []
    if args.regions:
        with open(args.regions, encoding="utf-8") as handle:
            regions = json.load(handle)
    regions += regions_from_cli(args.region)
    for pair in args.pairs:
        left, _, right = pair.partition("=")
        right = right or left
        if ref_flat is None or cand_flat is None:
            sys.exit("--pairs 需要两侧都传 ui-spec 的 JSON")
        a, b = find_node(ref_flat, left), find_node(cand_flat, right)
        if not a or not b:
            print(f"跳过 {pair}：{'参考' if not a else '候选'}侧找不到", file=sys.stderr)
            continue
        fa, fb = a["frameInWindow"], b["frameInWindow"]
        regions.append({"name": left, "frame": [fa["x"], fa["y"], fa["width"], fa["height"]],
                        "candidateFrame": [fb["x"], fb["y"], fb["width"], fb["height"]]})
    if not regions:
        sys.exit("没有任何区域。用 -r / --regions / --pairs 指定。")

    def scale_for(png, width_pt):
        if args.scale:
            return args.scale
        _, _, w, _ = window_origin(Image.open(png))
        return round(w / width_pt, 3) if width_pt else 2

    ref = load_image(ref_png, scale_for(ref_png, ref_w))
    cand = load_image(cand_png, scale_for(cand_png, cand_w))

    rows = []
    for region in regions:
        x, y, w, h = region["frame"]
        cx, cy, cw, ch = region.get("candidateFrame", region["frame"])
        m = measure(ref, x, y, w, h, args.inset)
        a = measure(cand, cx, cy, cw, ch, args.inset)
        if not m or not a:
            rows.append((region["name"], m, a, ["取样框越界"]))
            continue
        bad = []
        if abs(a["box"][0] - m["box"][0]) > TOL["box"] or abs(a["box"][1] - m["box"][1]) > TOL["box"]:
            bad.append("外框")
        if abs(a["white"] - m["white"]) > TOL["white"]:
            bad.append("白度")
        if m["sharp"] > 0.5 and abs(a["sharp"] - m["sharp"]) / m["sharp"] > TOL["sharp"]:
            bad.append("锐度")
        rows.append((region["name"], m, a, bad))
        if args.crops:
            os.makedirs(args.crops, exist_ok=True)
            zoom = 6
            pm = patch(ref, x, y, w, h).resize((int(w * zoom), int(h * zoom)), Image.LANCZOS)
            pa = patch(cand, cx, cy, cw, ch).resize((int(cw * zoom), int(ch * zoom)), Image.LANCZOS)
            out = Image.new("L", (max(pm.width, pa.width), pm.height + pa.height + 6), 0)
            out.paste(pm, (0, 0))
            out.paste(pa, (0, pm.height + 6))
            out.save(os.path.join(args.crops, f"{region['name']}.png"))

    header = f"{'区域':16}{'参考 外框/白度/锐度':>30}{'候选 外框/白度/锐度':>30}  判定"
    lines = [header]
    for name, m, a, bad in rows:
        fmt = lambda t: "—" if not t else f"{t['box'][0]:.1f}×{t['box'][1]:.1f} {t['white']:.2f} {t['sharp']:.1f}"
        lines.append(f"{name:16}{fmt(m):>30}{fmt(a):>30}  {'✓' if not bad else '✗ ' + '/'.join(bad)}")
    failed = sum(1 for _, _, _, bad in rows if bad)
    lines.append(f"\n{len(rows) - failed}/{len(rows)} 一致"
                 f"（容差：外框 {TOL['box']}pt、白度 {TOL['white']}、锐度 {TOL['sharp']*100:.0f}%）")
    print("\n".join(lines))

    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write("# 外观比对\n\n```\n" + "\n".join(lines) + "\n```\n")
        print(f"已写入 {args.report}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

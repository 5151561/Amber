#!/usr/bin/env python3
"""把多宽度 AX 扫描拟合成布局规则。

输入是 `ui-spec.swift --widths` 产出的 sweep JSON（可给多个，例如不同侧栏状态）。
输出把每个节点的几何量表达成关于窗口宽度 W 的函数：常量、线性、分段（断点），
并统计高频常量作为设计 token 候选、列出只在部分宽度出现的节点（响应式显隐）。

用法：
  python3 Tools/fit-layout.py sweep.json --report out.md --json out.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict

TOL = 0.5  # point；AX 会给出 .5 的半像素值，容差小于它才有意义


# ---------- 载入与展平 ----------

def load_samples(paths):
    samples = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
        sweep = doc.get("runtime", {}).get("sweep") or doc.get("sweep")
        if not sweep:
            sys.exit(f"{path} 里没有 sweep 段；用 --widths 重新采集")
        if "error" in sweep:
            sys.exit(f"{path} 采集失败：{sweep['error']}")
        state = sweep.get("state", "default")
        for sample in sweep.get("samples", []):
            if "window" not in sample:
                continue
            samples.append({
                "state": state,
                "width": sample["windowSize"]["width"],
                "height": sample["windowSize"]["height"],
                "tree": sample["window"],
                "source": path,
            })
    samples.sort(key=lambda s: (s["state"], s["width"]))
    return samples


STATE_SUFFIX = re.compile(r"\[[^\]]*\]")


def label_of(node):
    """identifier 里常挂着 [viewState=mini]、[hovered] 这类瞬时状态，必须剥掉再当 key。"""
    for key in ("identifier", "title", "description"):
        value = node.get(key)
        if isinstance(value, str) and value.strip():
            return STATE_SUFFIX.sub("", value).strip()[:60]
    value = node.get("value")
    if isinstance(value, str) and value.strip():
        return STATE_SUFFIX.sub("", value).strip()[:60]
    return ""


def sig_of(node):
    """与层级无关的身份签名。AX 树的中间层会随重排出现/消失，路径不可全信。"""
    orientation = node.get("orientation", "")
    if orientation == "AXUnknownOrientation":
        orientation = ""
    return (node.get("role", "?"), node.get("subrole", ""), orientation, label_of(node))


def flatten(tree):
    """键要跨宽度稳定：同类兄弟里标签唯一就用标签，否则退回序号。"""
    flat = {}

    def walk(node, key, parent_key):
        flat[key] = {"node": node, "parent": parent_key}
        children = node.get("children") or []
        groups = defaultdict(list)
        for child in children:
            groups[sig_of(child)[:3]].append(child)
        for (role, subrole, orientation), group in sorted(groups.items()):
            tag = role + (f"[{subrole}]" if subrole else "") + (f"<{orientation}>" if orientation else "")
            labels = [label_of(child) for child in group]
            unique = len(set(labels)) == len(labels) and all(labels)
            for index, child in enumerate(group):
                part = f"{tag}:{labels[index]}" if unique else f"{tag}#{index}"
                walk(child, f"{key}/{part}", key)

    walk(tree, "window", None)
    return flat


def metrics_of(entry, flat):
    """几何量一律取窗口相对坐标；父子相对量（inset）才是可以直接抄的东西。"""
    frame = entry["node"].get("frameInWindow")
    if not frame:
        return {}
    out = {"x": frame["x"], "y": frame["y"], "w": frame["width"], "h": frame["height"]}
    parent = flat.get(entry["parent"]) if entry["parent"] else None
    pframe = parent["node"].get("frameInWindow") if parent else None
    if pframe:
        out["leading"] = frame["x"] - pframe["x"]
        out["trailing"] = (pframe["x"] + pframe["width"]) - (frame["x"] + frame["width"])
        out["top"] = frame["y"] - pframe["y"]
        out["bottom"] = (pframe["y"] + pframe["height"]) - (frame["y"] + frame["height"])
    return out


# ---------- 拟合 ----------

def linear_fit(xs, ys):
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    denom = sum((x - mx) ** 2 for x in xs)
    if denom == 0:
        return 0.0, my
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / denom
    return slope, my - slope * mx


def describe_slope(slope):
    for value, name in ((1.0, "跟随窗口右边缘/整体拉伸"), (0.5, "水平居中"), (0.25, "四分之一"),
                        (0.75, "四分之三"), (1 / 3, "三分之一"), (2 / 3, "三分之二")):
        if abs(slope - value) < 0.02:
            return name
    return f"按比例 {slope:.3f}·W"


def segment(xs, ys, tol):
    """求「能覆盖全部点的最少直线段」，段数相同时取残差最小的切法。

    贪心切段会把边界系统性地推后一个采样点（一条线还能勉强吃下断点后的第一个点），
    实测里滚动条明明在 1215→1220 消失，贪心却报 1220→1225。用 DP 才能落在真边界上。
    """
    n = len(xs)
    fits = {}
    for i in range(n):
        for j in range(i, n):
            sx, sy = xs[i:j + 1], ys[i:j + 1]
            if len(sx) == 1:
                fits[(i, j)] = (0.0, 0.0, sy[0])
                continue
            slope, intercept = linear_fit(sx, sy)
            residual = max(abs(y - (slope * x + intercept)) for x, y in zip(sx, sy))
            if residual <= tol:
                fits[(i, j)] = (residual, slope, intercept)

    best = [None] * (n + 1)          # best[j] = (段数, 总残差, 切点列表) 覆盖前 j 个点
    best[0] = (0, 0.0, [])
    for j in range(1, n + 1):
        for i in range(j):
            if best[i] is None or (i, j - 1) not in fits:
                continue
            residual = fits[(i, j - 1)][0]
            candidate = (best[i][0] + 1, best[i][1] + residual, best[i][2] + [(i, j - 1)])
            if best[j] is None or candidate[:2] < best[j][:2]:
                best[j] = candidate
    if best[n] is None:              # 单点段总是可行，理论上到不了这里
        return [{"from": xs[0], "to": xs[-1], "slope": 0.0, "intercept": ys[0], "values": ys}]

    segments = []
    for i, j in best[n][2]:
        residual, slope, intercept = fits[(i, j)]
        segments.append({"from": xs[i], "to": xs[j], "slope": round(slope, 4),
                         "intercept": round(intercept, 3), "values": ys[i:j + 1]})
    return segments


def fit(xs, ys, tol):
    if max(ys) - min(ys) <= tol:
        return {"kind": "constant", "value": round(sum(ys) / len(ys), 3)}
    if len(xs) >= 2:
        slope, intercept = linear_fit(xs, ys)
        residual = max(abs(y - (slope * x + intercept)) for x, y in zip(xs, ys))
        if residual <= tol and abs(slope) > 1e-6:
            return {"kind": "linear", "slope": round(slope, 4),
                    "intercept": round(intercept, 3), "maxResidual": round(residual, 3),
                    "meaning": describe_slope(slope)}
    segments = segment(xs, ys, tol)
    if len(segments) > 1:
        breaks = []
        for prev, nxt in zip(segments, segments[1:]):
            breaks.append({"between": [prev["to"], nxt["from"]],
                           "before": round(prev["values"][-1], 3),
                           "after": round(nxt["values"][0], 3)})
        return {"kind": "piecewise", "segments": len(segments), "breakpoints": breaks,
                "samples": [round(v, 3) for v in ys]}
    return {"kind": "unresolved", "samples": [round(v, 3) for v in ys]}


# ---------- 主流程 ----------

def analyze(samples, tol, metrics_wanted):
    by_state = defaultdict(list)
    for sample in samples:
        by_state[sample["state"]].append(sample)

    states = {}
    for state, group in by_state.items():
        flats = [flatten(sample["tree"]) for sample in group]
        widths = [sample["width"] for sample in group]
        if len(set(widths)) < 2:
            sys.exit(f"状态 {state} 只有 {len(set(widths))} 个不同宽度；至少要 2 个才能拟合")

        resolved, conditional, stats = match_nodes(flats, widths)

        rules = {}
        for node_id, pairs in resolved.items():
            series = defaultdict(list)
            ok = True
            for flat, key in pairs:
                values = metrics_of(flat[key], flat)
                if not values:
                    ok = False
                    break
                for name, value in values.items():
                    series[name].append(value)
            if not ok:
                continue
            entry = {}
            for name in metrics_wanted:
                if name in series and len(series[name]) == len(widths):
                    entry[name] = fit(widths, series[name], tol)
            if entry:
                rules[node_id] = entry

        states[state] = {"widths": widths, "nodeCounts": [len(f) for f in flats],
                         "matched": len(resolved), "matching": stats, "rules": rules,
                         "conditional": sorted(conditional, key=lambda c: c["key"])}
    return states


def render_sig(sig):
    role, subrole, orientation, label = sig
    tag = role + (f"[{subrole}]" if subrole else "") + (f"<{orientation}>" if orientation else "")
    return f"{tag}:{label}" if label else tag


def match_nodes(flats, widths):
    """两级匹配：先按路径，路径对不上的再按全局唯一签名接回来。

    AX 树在重排时会临时多一层或少一层容器（同一次扫描里 AXOutline 就时有时无），
    纯路径匹配会把几百个节点判成「只在部分宽度出现」，拟合样本因此塌掉。
    """
    common = set(flats[0])
    for flat in flats:
        common &= set(flat)

    resolved = {key: [(flat, key) for flat in flats] for key in common}
    path_matched = len(resolved)

    indexes = []
    for flat in flats:
        by_sig = defaultdict(list)
        for key, entry in flat.items():
            by_sig[sig_of(entry["node"])].append(key)
        indexes.append(by_sig)

    shared = set(indexes[0])
    for by_sig in indexes:
        shared &= set(by_sig)

    for sig in shared:
        if any(len(by_sig[sig]) != 1 for by_sig in indexes):
            continue  # 签名不唯一就不能凭它认人
        keys = [by_sig[sig][0] for by_sig in indexes]
        display = keys[-1]
        if display in resolved:
            continue
        resolved[display] = list(zip(flats, keys))

    presence = Counter()
    for by_sig in indexes:
        presence.update(by_sig.keys())
    conditional = []
    for sig, count in presence.items():
        if count < len(flats):
            present = [widths[i] for i, by_sig in enumerate(indexes) if sig in by_sig]
            conditional.append({"key": render_sig(sig), "presentAt": present, "sampleCount": count})

    stats = {"byPath": path_matched, "bySignature": len(resolved) - path_matched,
             "ambiguousSignatures": sum(1 for sig in shared
                                        if any(len(by[sig]) != 1 for by in indexes))}
    return resolved, conditional, stats


INDEX_PART = re.compile(r"#\d+")


def structural_class(key):
    """把 `AXRow#0..#30` 归一成 `AXRow#*`：31 个克隆行是一类结构，不是 31 个证据。"""
    return INDEX_PART.sub("#*", key)


def token_histogram(rules):
    """一个常量被多少种不同结构复用，才是它是不是 token 的判据。"""
    seen = defaultdict(lambda: defaultdict(set))
    for key, entry in rules.items():
        cls = structural_class(key)
        for name, rule in entry.items():
            if rule["kind"] != "constant" or name not in ("leading", "trailing", "top", "bottom", "h", "w"):
                continue
            value = round(rule["value"], 2)
            if name in ("leading", "trailing", "top", "bottom") and value <= 0:
                continue  # 0 是「贴边」，负数是溢出，都不是间距 token
            seen[name][value].add(cls)
    return {name: Counter({value: len(classes) for value, classes in values.items()})
            for name, values in seen.items()}


def markdown(states, tol):
    lines = ["# 布局规则拟合", "", f"容差 {tol} pt。自变量为窗口实际宽度 W（point）。", ""]
    for state, data in states.items():
        widths = ", ".join(f"{w:g}" for w in data["widths"])
        lines += [f"## 状态：{state}", "",
                  f"- 采样宽度：{widths}",
                  f"- 各样本节点数：{data['nodeCounts']}",
                  f"- 跨全部宽度稳定匹配：{data['matched']}"
                  f"（路径 {data['matching']['byPath']} + 签名 {data['matching']['bySignature']}）",
                  ""]

        kinds = Counter()
        for entry in data["rules"].values():
            for rule in entry.values():
                kinds[rule["kind"]] += 1
        lines += ["- 规则分布：" + "、".join(f"{k} {v}" for k, v in kinds.most_common()), ""]

        jumps = Counter()
        classes_at = defaultdict(set)
        for key, entry in data["rules"].items():
            for rule in entry.values():
                if rule["kind"] != "piecewise":
                    continue
                for point in rule["breakpoints"]:
                    span = (point["between"][0], point["between"][1])
                    jumps[span] += 1
                    classes_at[span].add(structural_class(key))
        lines += ["### 断点位置", ""]
        if jumps:
            for (low, high), count in sorted(jumps.items()):
                lines.append(f"- **{low:g} → {high:g} 之间**：{count} 个几何量跳变，"
                             f"涉及 {len(classes_at[(low, high)])} 类结构")
            lines.append("")
            lines.append("> 缩小这两个宽度之间的采样间隔可以把断点逼到 1pt。")
        else:
            lines.append("- 无。这一状态下没有宽度断点。")
        lines.append("")

        piecewise = [(k, n, r) for k, e in data["rules"].items() for n, r in e.items()
                     if r["kind"] == "piecewise" and n in ("w", "h", "x", "y")]
        lines += ["### 断点细节（尺寸与位置）", ""]
        if piecewise:
            for key, name, rule in sorted(piecewise)[:60]:
                points = "；".join(
                    f"{b['between'][0]:g}→{b['between'][1]:g} 之间 {b['before']:g}→{b['after']:g}"
                    for b in rule["breakpoints"])
                lines.append(f"- `{key}` **{name}**：{points}")
            if len(piecewise) > 60:
                lines.append(f"- …另有 {len(piecewise) - 60} 条，见 JSON")
        else:
            lines.append("- 无尺寸/位置跳变；断点只影响父子间距。")
        lines.append("")

        linear = [(k, n, r) for k, e in data["rules"].items() for n, r in e.items()
                  if r["kind"] == "linear" and n in ("w", "x", "trailing")]
        lines += ["### 随宽度变化", ""]
        for key, name, rule in sorted(linear)[:80]:
            sign = "+" if rule["intercept"] >= 0 else "−"
            lines.append(f"- `{key}` {name} = {rule['slope']:g}·W {sign} {abs(rule['intercept']):g}"
                         f"（{rule['meaning']}）")
        if len(linear) > 80:
            lines.append(f"- …另有 {len(linear) - 80} 条，见 JSON")
        lines.append("")

        lines += ["### 高频常量（token 候选）", "",
                  "计数是「用到该值的结构类数量」，克隆行只算一类。", ""]
        hist = token_histogram(data["rules"])
        for name in ("leading", "trailing", "top", "bottom", "h", "w"):
            entries = [(value, count) for value, count in hist.get(name, Counter()).most_common(14)
                       if count >= 2]
            if not entries:
                continue
            top = "、".join(f"{value:g}（{count} 类）" for value, count in entries)
            lines.append(f"- **{name}**：{top}")
        lines.append("")

        lines += ["### 只在部分宽度出现（响应式显隐）", ""]
        if data["conditional"]:
            for item in data["conditional"][:60]:
                present = ", ".join(f"{w:g}" for w in item["presentAt"])
                lines.append(f"- `{item['key']}` 仅出现在 {present}")
            if len(data["conditional"]) > 60:
                lines.append(f"- …另有 {len(data['conditional']) - 60} 条，见 JSON")
        else:
            lines.append("- 无。节点集合在所有宽度下一致。")
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="把多宽度 AX 扫描拟合成布局规则")
    parser.add_argument("sweeps", nargs="+", help="ui-spec.swift --widths 产出的 JSON")
    parser.add_argument("--report", help="写入 Markdown 报告")
    parser.add_argument("--json", dest="json_out", help="写入完整规则 JSON")
    parser.add_argument("--tolerance", type=float, default=TOL, help=f"拟合容差 point，默认 {TOL}")
    parser.add_argument("--metrics", default="x,y,w,h,leading,trailing,top,bottom",
                        help="要拟合的量，逗号分隔")
    args = parser.parse_args()

    wanted = [m.strip() for m in args.metrics.split(",") if m.strip()]
    samples = load_samples(args.sweeps)
    if not samples:
        sys.exit("没有可用样本")
    states = analyze(samples, args.tolerance, wanted)
    report = markdown(states, args.tolerance)

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump({"tolerance": args.tolerance, "states": states}, handle,
                      ensure_ascii=False, indent=1)
        print(f"已写入规则 JSON：{args.json_out}")
    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write(report)
        print(f"已写入报告：{args.report}")
    if not args.report and not args.json_out:
        print(report)


if __name__ == "__main__":
    main()

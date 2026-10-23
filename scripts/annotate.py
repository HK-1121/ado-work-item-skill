#!/usr/bin/env python3
"""给截图圈问题、加编号批注、拼左右/上下对比图，产出能直接粘进 ADO 评论的 PNG。

为什么单独一个脚本：评论图不是「截个屏」就完事，得让报障人一眼看到你看的是哪一格。
固定四件套是「框/圈 + 编号 ① + 一句批注 + 需要时左右对比拼图」；每次手写 PIL
都要重算线宽、字号、文字底，干脆固化。依赖只有 Pillow。

用法：
    python scripts/annotate.py --spec tmp/anno-4507.json
    python scripts/annotate.py --info output/4507/raw.png
    python scripts/annotate.py --compare old.png new.png --labels "标准版" "实际版" --out out.png

spec（JSON）：
{
  "out": "output/4507/comment-02-fax.png",
  "layout": "side",                       // side 左右 | stack 上下，默认 side
  "gap": 24,
  "sources": [
    { "src": "tmp/old.png", "label": "标准版（老系统）" },
    { "src": "tmp/new.png", "label": "实际版（SIT）" }
  ],
  "marks": [
    { "side": 1, "shape": "rect", "box": [820, 640, 260, 46], "label": "①" },
    { "side": 1, "shape": "ellipse", "box": [1180, 960, 220, 90], "label": "②" },
    { "side": 1, "shape": "arrow", "from": [1500, 1120], "to": [1180, 700], "text": "应为 2463 1644" },
    { "side": 1, "shape": "text", "at": [40, 40], "text": "新系统少印 LDR No:", "size": 34 }
  ]
}

坐标一律按**原图像素**；`box` 是 [x, y, 宽, 高]。对比时左右两边坐标各自独立。
"""
import argparse
import json
import math
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

RED = (222, 20, 40)
DARK_RED = (190, 0, 20)
YELLOW = (255, 212, 0)
DARK = (24, 24, 24)
WHITE = (255, 255, 255)
HEADER_BG = (238, 238, 238)
SEPARATOR = (205, 205, 205)

FONT_CANDIDATES = (
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
    r"C:\Windows\Fonts\arial.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/System/Library/Fonts/PingFang.ttc",
)

_font_cache = {}


def load_font(size, path=None):
    """按候选列表找一款能用的 TrueType 字体，找不到就退回 PIL 默认字体。"""
    key = (path, int(size))
    if key in _font_cache:
        return _font_cache[key]
    for candidate in ([path] if path else []) + list(FONT_CANDIDATES):
        if not candidate or not os.path.exists(candidate):
            continue
        try:
            font = ImageFont.truetype(candidate, int(size))
            _font_cache[key] = font
            return font
        except OSError:
            continue
    font = ImageFont.load_default()
    _font_cache[key] = font
    return font


def text_extent(draw, text, font):
    """文字的像素宽高，Pillow 新旧版本都兼容。"""
    try:
        left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
        return right - left, bottom - top
    except AttributeError:  # Pillow < 8
        return draw.textsize(text, font=font)


def clamp(value, low, high):
    return max(low, min(high, value))


def draw_caption(draw, xy, text, font, *, fill=DARK, bg=WHITE, pad=6):
    """带白底的一行字，避免压在深色界面上看不清。"""
    x, y = xy
    width, height = text_extent(draw, text, font)
    draw.rectangle([x, y, x + width + pad * 2, y + height + pad * 2], fill=bg)
    draw.text((x + pad, y + pad), text, font=font, fill=fill)
    return x + width + pad * 2, y + height + pad * 2


def draw_badge(draw, center, label, font, radius):
    """黄底红边的编号圆点，压在框的左上角。"""
    cx, cy = center
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=YELLOW,
        outline=RED,
        width=max(2, radius // 6),
    )
    width, height = text_extent(draw, label, font)
    draw.text((cx - width / 2, cy - height / 2 - radius * 0.08), label, font=font, fill=DARK)


def draw_arrow(draw, start, end, line_width):
    """直线 + 实心箭头。"""
    x1, y1 = start
    x2, y2 = end
    draw.line([x1, y1, x2, y2], fill=RED, width=line_width)
    angle = math.atan2(y2 - y1, x2 - x1)
    head = max(10, line_width * 4)
    spread = math.radians(26)
    p1 = (x2, y2)
    p2 = (x2 - head * math.cos(angle - spread), y2 - head * math.sin(angle - spread))
    p3 = (x2 - head * math.cos(angle + spread), y2 - head * math.sin(angle + spread))
    draw.polygon([p1, p2, p3], fill=RED)


def badge_center(box, radius, width, height):
    """优先把编号放在框外侧的四个角，实在没地方再退回框内左上角。"""
    x, y, bw, bh = box
    x2, y2 = x + bw, y + bh
    margin = radius * 0.55
    for cx, cy in (
        (x - margin, y - margin),
        (x2 + margin, y - margin),
        (x - margin, y2 + margin),
        (x2 + margin, y2 + margin),
    ):
        if radius <= cx <= width - radius and radius <= cy <= height - radius:
            return cx, cy
    return clamp(x + radius, radius, width - radius), clamp(y + radius, radius, height - radius)


def apply_mark(img, mark):
    """在一张图上按 spec 画一个标记。坐标是这张图自己的像素。"""
    draw = ImageDraw.Draw(img)
    width, height = img.size
    base = max(2, int(min(width, height) / 140))
    line_width = int(mark.get("width") or max(3, base * 2))
    font_size = int(mark.get("size") or max(18, int(min(width, height) / 26)))
    font = load_font(font_size, mark.get("font"))
    shape = str(mark.get("shape") or "rect").lower()

    if shape in ("rect", "box", "ellipse", "circle"):
        box = [int(float(v)) for v in mark["box"]]
        x, y, w, h = box
        x2, y2 = x + w, y + h
        if shape in ("ellipse", "circle"):
            draw.ellipse([x, y, x2, y2], outline=RED, width=line_width)
        else:
            draw.rectangle([x, y, x2, y2], outline=RED, width=line_width)
        if mark.get("label"):
            radius = max(16, font_size // 2 + 6)
            # 编号默认放框外侧；给了 label_at 就按给的坐标放
            center = (
                tuple(mark["label_at"])
                if mark.get("label_at")
                else badge_center([x, y, w, h], radius, width, height)
            )
            draw_badge(
                draw,
                center,
                str(mark["label"]),
                load_font(max(12, int(radius * 1.1))),
                radius,
            )
    elif shape == "arrow":
        draw_arrow(draw, mark["from"], mark["to"], line_width)
        text = mark.get("text")
        if text:
            tx, ty = mark.get("text_at") or mark["from"]
            text_w, _ = text_extent(draw, text, font)
            tx = clamp(int(tx) + 12, 0, max(0, width - text_w - 24))
            ty = clamp(int(ty) - font_size - 18, 0, max(0, height - font_size - 24))
            draw_caption(draw, (tx, ty), text, font, fill=DARK_RED)
    elif shape == "text":
        x, y = [int(float(v)) for v in mark["at"]]
        text = str(mark["text"])
        text_w, _ = text_extent(draw, text, font)
        x = clamp(x, 0, max(0, width - text_w - 24))
        y = clamp(y, 0, max(0, height - font_size - 24))
        draw_caption(draw, (x, y), text, font, fill=DARK_RED)
    else:
        raise SystemExit(f"不认识的 shape：{shape}（可用 rect / ellipse / arrow / text）")


def header_height(widths):
    return max(44, min(96, int(max(widths) / 28)))


def draw_label(draw, text, x, top, height):
    """标题条上的一行标签，垂直居中；不用 anchor，兼容位图字体。"""
    if not text:
        return
    font = load_font(int(height * 0.55))
    _, text_height = text_extent(draw, text, font)
    draw.text((x, top + (height - text_height) / 2), text, font=font, fill=DARK)


def compose(images, labels, layout, gap):
    """单图 = 原图（有 label 就加标题条）；两图 = 左右或上下拼。"""
    widths = [im.width for im in images]
    has_header = any(labels)
    height = header_height(widths) if has_header else 0

    if len(images) == 1:
        image = images[0]
        if not has_header:
            return image
        canvas = Image.new("RGB", (image.width, image.height + height), WHITE)
        canvas.paste(image, (0, height))
        draw = ImageDraw.Draw(canvas)
        draw.rectangle([0, 0, image.width, height], fill=HEADER_BG)
        draw_label(draw, labels[0], 16, 0, height)
        return canvas

    if layout == "stack":
        out = Image.new(
            "RGB",
            (max(widths), sum(im.height for im in images) + height * 2 + gap),
            WHITE,
        )
        draw = ImageDraw.Draw(out)
        y = 0
        for index, (image, label) in enumerate(zip(images, labels)):
            if has_header:
                draw.rectangle([0, y, out.width, y + height], fill=HEADER_BG)
                draw_label(draw, label, 16, y, height)
                y += height
            out.paste(image, ((out.width - image.width) // 2, y))
            y += image.height + (gap if index == 0 else 0)
        return out

    out = Image.new("RGB", (sum(widths) + gap, max(im.height for im in images) + height), WHITE)
    draw = ImageDraw.Draw(out)
    if has_header:
        draw.rectangle([0, 0, out.width, height], fill=HEADER_BG)
    x = 0
    for index, (image, label) in enumerate(zip(images, labels)):
        out.paste(image, (x, height))
        if has_header:
            draw_label(draw, label, x + 16, 0, height)
        x += image.width
        if index == 0:
            draw.rectangle([x + gap // 2 - 1, height, x + gap // 2 + 1, out.height], fill=SEPARATOR)
            x += gap
    return out


def append_note(image, note):
    font = load_font(max(16, int(min(image.width, image.height) / 40)))
    draw = ImageDraw.Draw(image)
    _, text_height = text_extent(draw, note, font)
    strip_height = text_height + 20
    canvas = Image.new("RGB", (image.width, image.height + strip_height), WHITE)
    canvas.paste(image, (0, 0))
    ImageDraw.Draw(canvas).text((10, image.height + 8), note, font=font, fill=DARK)
    return canvas


def load_image(path):
    if not path or not os.path.exists(path):
        raise SystemExit(f"找不到图：{path}")
    with Image.open(path) as image:
        return image.convert("RGB")


def build(spec):
    out_path = spec.get("out")
    if not out_path:
        raise SystemExit("spec 里要有 out（输出 PNG 路径）")

    sources = spec.get("sources")
    if not sources and spec.get("src"):
        sources = [{"src": spec["src"]}]
    if not sources:
        raise SystemExit("spec 里要有 sources：1 张标注，或 2 张对比")
    if len(sources) > 2:
        raise SystemExit(f"sources 最多 2 张（现在 {len(sources)} 张）：对比只拼两张，多的拆成几张图")

    images = [load_image(item.get("src")) for item in sources]
    labels = [str(item.get("label") or "") for item in sources]

    for mark in spec.get("marks") or []:
        side = int(mark.get("side", 0))
        if side < 0 or side >= len(images):
            raise SystemExit(f"mark 的 side={side} 超范围（sources 只有 {len(images)} 张）")
        apply_mark(images[side], mark)

    layout = str(spec.get("layout") or "side")
    if layout not in ("side", "stack"):
        raise SystemExit(f"layout 只能是 side 或 stack（现在 {layout}）")
    result = compose(images, labels, layout, int(spec.get("gap", 24)))
    if spec.get("note"):
        result = append_note(result, str(spec["note"]))

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    result.save(out_path)
    return out_path, result.size


def parse_box(text):
    parts = [p.strip() for p in str(text).split(",")]
    if len(parts) != 4:
        raise SystemExit("--box 要 4 个数：x,y,宽,高")
    return [float(p) for p in parts]


def main(argv=None):
    # Windows 控制台默认 GBK，中文提示会变乱码；统一按 UTF-8 输出
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except AttributeError:
            pass

    parser = argparse.ArgumentParser(description="截图标注 / 对比拼图（ADO 评论配图）")
    parser.add_argument("--spec", help="JSON 任务文件")
    parser.add_argument("--info", nargs="+", metavar="PNG", help="只打印图片尺寸，方便定坐标")
    parser.add_argument("--src", help="单图标注的源图")
    parser.add_argument("--out", help="输出 PNG")
    parser.add_argument("--box", help="要框的区域 x,y,宽,高")
    parser.add_argument("--label", help="框上的编号，如 ①")
    parser.add_argument("--text", help="批注文字")
    parser.add_argument("--compare", nargs=2, metavar=("LEFT", "RIGHT"), help="两张对比图")
    parser.add_argument("--labels", nargs="*", help="对比图两边的标签")
    parser.add_argument("--layout", choices=("side", "stack"), default="side")
    args = parser.parse_args(argv)

    if args.info:
        for path in args.info:
            with Image.open(path) as image:
                print(f"{path}  {image.width}x{image.height}  {image.mode}")
        return 0

    if args.spec:
        spec = json.loads(Path(args.spec).read_text(encoding="utf-8-sig"))
    elif args.compare:
        if not args.out:
            raise SystemExit("--compare 要配 --out")
        sources = [{"src": args.compare[0]}, {"src": args.compare[1]}]
        if args.labels:
            for item, label in zip(sources, args.labels):
                item["label"] = label
        spec = {"out": args.out, "layout": args.layout, "sources": sources, "marks": []}
    elif args.src:
        if not args.out:
            raise SystemExit("--src 要配 --out")
        marks = []
        if args.box:
            marks.append({"shape": "rect", "box": parse_box(args.box), "label": args.label or "", "text": args.text})
        elif args.text:
            marks.append({"shape": "text", "at": [24, 24], "text": args.text})
        spec = {"out": args.out, "sources": [{"src": args.src}], "marks": marks}
    else:
        parser.print_help()
        return 2

    out, size = build(spec)
    print(f"已写入: {out}  ({size[0]}x{size[1]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/bin/bash
# generate-manifest.sh — 从 buy-something 报告提取所有 Markdown 超链接，生成 links_manifest.json
# 用法: bash generate-manifest.sh <报告路径>
# 输出: 同目录下 links_manifest.json + 统计信息打印到 stdout
# 对应 HARD RULE [M11] 链接清单生成的机械自动化
#
# v1.0 — 2026-05-28
#
# 核心逻辑:
#   - 图片链接排除 (![alt](url) 不提取)
#   - Top 1-5 vs Top 10/20 正确区分 (用 \d+ 避免误匹配)
#   - Section 定位基于 heading + Top 编号
#   - 分类统计: total / top5 / appendix / other
#   - 支持 Quick / Standard / Deep 三种模式报告
#
# Section 标位逻辑:
#   1. 按 heading 层级追踪 current_section
#   2. "二、搜索参考" heading → 进入附录区 (current_top=None)
#   3. Top 10/20 heading → 清除 Top 编号 (current_top=None)
#   4. Top 1-5 heading → 设置 current_top (用 \d+ 匹配完整数字)
#   5. 非 heading 行内的链接沿用最近的 section/current_top
#   6. heading 行内可能包含链接 (如 #### Top 1：...→ [查看](url))，不跳过提取
#
# 统计分类逻辑:
#   - top5_links: section 以 "Top5-" 开头的链接数
#   - appendix_links: section 不以 "Top5-" 开头且不为 "未知" 的链接数
#   - other_links: section 为 "未知" 的链接数

set -euo pipefail

REPORT_PATH="${1:?用法: bash generate-manifest.sh <报告路径>}"
REPORT_DIR="$(dirname "$REPORT_PATH")"
REPORT_BASE="$(basename "$REPORT_PATH")"
MANIFEST_PATH="$REPORT_DIR/links_manifest.json"

if [ ! -f "$REPORT_PATH" ]; then
  echo "❌ 文件不存在: $REPORT_PATH"
  exit 1
fi

python3 - "$REPORT_PATH" "$MANIFEST_PATH" "$REPORT_BASE" << 'PYEOF'
import json, re, sys, os
from datetime import datetime, timezone

def extract_links(report_path):
    """从 Markdown 报告提取所有 [text](url) 链接，排除图片链接"""
    with open(report_path, "r", encoding="utf-8") as f:
        content = f.read()
    lines = content.split("\n")

    img_pattern = re.compile(r'\!\[[^\]]*\]\([^)]+\)')
    link_pattern = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')

    links = []
    current_section = "未知"
    current_top = None

    for i, line in enumerate(lines):
        # 先记录图片 span 位置（用于排除图片链接）
        img_spans = [(m.start(), m.end()) for m in img_pattern.finditer(line)]

        # heading 检测 — 更新 section/top 但不跳过该行（heading 行可能包含链接）
        heading_match = re.match(r'^#{1,4}\s+(.+)', line)
        if heading_match:
            heading = heading_match.group(1).strip()
            current_section = heading

            # "二、搜索参考" → 进入附录区
            if re.search(r'二、|搜索参考', heading):
                current_top = None
            # Top 10/20 → 清除编号（必须在 Top 1-5 之前检测）
            elif re.search(r'Top\s+(10|20)', heading):
                current_top = None
            # Top 1-5 → 设置编号（\d+ 避免误匹配 "Top 20" 中的 "2"）
            else:
                m = re.search(r'Top\s+(\d+)', heading)
                if m and 1 <= int(m.group(1)) <= 5:
                    current_top = int(m.group(1))

        # 提取该行所有 [text](url) 链接（heading 行也提取）
        for m in link_pattern.finditer(line):
            # 跳过在图片 span 内的链接（即图片链接）
            if any(m.start() >= s and m.end() <= e for s, e in img_spans):
                continue

            anchor = m.group(1).strip()
            url = m.group(2).strip()

            # 跳过页内锚点链接和空链接
            if url.startswith("#") or not url:
                continue

            # 嵌套 anchor 提取最内层文本
            inner = re.search(r'\[([^\]]+)\]', anchor)
            if inner:
                anchor = inner.group(1)

            section = f"Top5-{current_top}" if current_top else current_section
            links.append({"anchor": anchor, "url": url, "section": section, "line": i + 1})

    return links

def classify(links):
    """分类统计链接: top5 / appendix / other"""
    top5 = sum(1 for l in links if l["section"].startswith("Top5-"))
    appendix = sum(1 for l in links if not l["section"].startswith("Top5-") and l["section"] != "未知")
    other = len(links) - top5 - appendix
    return top5, appendix, other

# === 主逻辑 ===
report_path = sys.argv[1]
manifest_path = sys.argv[2]
report_base = sys.argv[3]

links = extract_links(report_path)
top5_count, appendix_count, other_count = classify(links)
total_count = len(links)

manifest = {
    "source_file": report_base,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "statistics": {
        "total_links": total_count,
        "top5_links": top5_count,
        "appendix_links": appendix_count,
        "other_links": other_count
    },
    "links": links
}

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)

print(f"✅ links_manifest.json 已生成: {manifest_path}")
print(f"   总链接数: {total_count}")
print(f"   Top 5 链接数: {top5_count}")
print(f"   附录链接数: {appendix_count}")
print(f"   其他链接数: {other_count}")
PYEOF
#!/bin/bash
# buy-something skill validator v1.0
# 对 SKILL.md 做内部一致性机械校验
# 在修改 SKILL.md 后执行，检测版本号/changelog/规则计数/路径引用的一致性
#
# ⚠️ 所有检查均为 WARN-only —— 内部不一致不一定导致功能异常，
#    但应在宣布修改完成前发出提醒
#
# 用法: bash validate-skill.sh

SKILL_MD="$HOME/.qoder/skills/buy-something/SKILL.md"
WARNINGS=0
PASSES=0

echo "════════════════════════════════════════════════════════"
echo "  SKILL.md 内部一致性校验 (v1.0)"
echo "════════════════════════════════════════════════════════"
echo ""

if [ ! -f "$SKILL_MD" ]; then
  echo "❌ SKILL.md 未找到: $SKILL_MD"
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# 1. Version vs Changelog 一致性
# ──────────────────────────────────────────────────────────────
echo "── 1. Version vs Changelog 一致性 ──"

# 提取 YAML front matter version（匹配 version: "X.Y.Z"）
META_VERSION=$(grep -m1 'version:' "$SKILL_MD" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$META_VERSION" ]; then
  echo "   ⚠️  无法提取 metadata version 字段"
  WARNINGS=$((WARNINGS + 1))
else
  echo "   metadata version: $META_VERSION"
fi

# 提取最新 changelog 条目版本号（第一个 ### vX.Y.Z）
CHANGELOG_LINE=$(grep -m1 '^### v[0-9]' "$SKILL_MD")
CHANGELOG_VERSION=$(echo "$CHANGELOG_LINE" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$CHANGELOG_VERSION" ]; then
  echo "   ⚠️  无法提取 changelog 最新版本号"
  WARNINGS=$((WARNINGS + 1))
else
  echo "   changelog 最新版本: $CHANGELOG_VERSION"

  CHANGELOG_VER_NUM="${CHANGELOG_VERSION#v}"
  if [ -n "$META_VERSION" ] && [ "$META_VERSION" != "$CHANGELOG_VER_NUM" ]; then
    echo "   ⚠️  版本不一致: metadata=\"$META_VERSION\" vs changelog=\"$CHANGELOG_VERSION\""
    echo "       请确保 YAML version 字段与最新 changelog 条目版本号一致"
    WARNINGS=$((WARNINGS + 1))
  else
    echo "   ✅ metadata version 与 changelog 一致"
    PASSES=$((PASSES + 1))
  fi
fi
echo ""

# ──────────────────────────────────────────────────────────────
# 2. HARD RULES 数量一致性
# ──────────────────────────────────────────────────────────────
echo "── 2. HARD RULES 数量校验 ──"

# 统计规则总数（匹配 - ⛔ [XX] 格式，XX 是大写字母+数字结尾）
TOTAL_RULES=$(grep -Ec '^[[:space:]]*-[[:space:]]*⛔[[:space:]]*\[' "$SKILL_MD" 2>/dev/null || echo 0)
if [ "$TOTAL_RULES" -gt 0 ] 2>/dev/null; then
  echo "   规则总数: $TOTAL_RULES"
  PASSES=$((PASSES + 1))

  # 按编号前缀分组统计
  for prefix in L X B R S A M G; do
    COUNT=$(grep -c "^- ⛔ \\[$prefix" "$SKILL_MD" 2>/dev/null || echo 0)
    if [ "$COUNT" -gt 0 ] 2>/dev/null; then
      printf "     [%s]: %2d 条\n" "$prefix" "$COUNT"
    fi
  done
else
  echo "   ⚠️  未检测到 HARD RULES（格式: - ⛔ [XX]）"
  WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ──────────────────────────────────────────────────────────────
# 3. COMPLETION GATE 检查项计数
# ──────────────────────────────────────────────────────────────
echo "── 3. COMPLETION GATE 检查项计数 ──"

# 提取 COMPLETION GATE 区域
GATE_START=$(grep -n '^## 🔒 COMPLETION GATE' "$SKILL_MD" | cut -d: -f1)
if [ -z "$GATE_START" ]; then
  echo "   ⚠️  未找到 COMPLETION GATE 章节"
  WARNINGS=$((WARNINGS + 1))
else
  # 提取 GATE 区域到下一个 --- 分隔符
  GATE_END=$(tail -n +"$GATE_START" "$SKILL_MD" | grep -n '^---$' | head -1 | cut -d: -f1)
  if [ -z "$GATE_END" ]; then
    GATE_BLOCK=$(tail -n +"$GATE_START" "$SKILL_MD")
  else
    GATE_END_LINE=$((GATE_START + GATE_END - 1))
    GATE_BLOCK=$(sed -n "${GATE_START},${GATE_END_LINE}p" "$SKILL_MD")
  fi

  # 统计所有 checkbox
  ALL_ITEMS=$(echo "$GATE_BLOCK" | grep -c '^[[:space:]]*-[[:space:]]*\[[ x]\]' 2>/dev/null || echo 0)
  echo "   COMPLETION GATE 检查项总数: $ALL_ITEMS"

  # 按子章节分组统计
  for section in "搜索执行" "链接合规" "小红书合规" "预算合规" "综合推荐合规" "报告产出" "归档与记忆" "对话输出" "执行授权" "机械校验"; do
    SEC_HEADING=$(echo "$GATE_BLOCK" | grep -n "### $section" | cut -d: -f1)
    if [ -n "$SEC_HEADING" ]; then
      SEC_CONTENT=$(echo "$GATE_BLOCK" | tail -n +"$SEC_HEADING" | awk '/^### /{if(NR>1)exit} {print}')
      SEC_COUNT=$(echo "$SEC_CONTENT" | grep -c '^[[:space:]]*-[[:space:]]*\[[ x]\]' 2>/dev/null || echo 0)
      printf "     %s: %2d 项\n" "$section" "$SEC_COUNT"
    fi
  done
  PASSES=$((PASSES + 1))
fi
echo ""

# ──────────────────────────────────────────────────────────────
# 4. 引用文件路径存在性
# ──────────────────────────────────────────────────────────────
echo "── 4. 引用文件路径存在性 ──"

SKILL_DIR="$HOME/.qoder/skills/buy-something"
REFERENCE_FILES=(
  "$SKILL_DIR/validate-report.sh"
  "$SKILL_DIR/test-validate.sh"
  "$SKILL_DIR/validate-skill.sh"
  "$SKILL_DIR/generate-manifest.sh"
  "$SKILL_DIR/mode-policy.md"
  "$SKILL_DIR/platform-policy.md"
  "$SKILL_DIR/category-guide.md"
  "$SKILL_DIR/buy_something_skill_optimization.md"
  "$SKILL_DIR/shopping-preferences.md"
)

for file in "${REFERENCE_FILES[@]}"; do
  if [ -f "$file" ]; then
    echo "   ✅ $(basename "$file")"
    PASSES=$((PASSES + 1))
  else
    echo "   ⚠️  $(basename "$file") — 文件不存在: $file"
    WARNINGS=$((WARNINGS + 1))
  fi
done
echo ""

# ──────────────────────────────────────────────────────────────
# 汇总
# ──────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  校验结果: ${PASSES} 通过, ${WARNINGS} 警告"
if [ "$WARNINGS" -eq 0 ]; then
  echo "  ✅ SKILL.md 内部一致性全部通过"
else
  echo "  ⚠️  存在 ${WARNINGS} 条警告，请检查上述项目"
fi
echo "════════════════════════════════════════════════════════"

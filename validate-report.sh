#!/bin/bash
# buy-something report validator v3.2
# 在 COMPLETION GATE 最后一步执行，机械校验报告基础结构
#
# ═══════════════════════════════════════════════════════════════
# [V0] 机械校验边界声明
# 本脚本仅执行结构性、格式性、存在性验证（能用正则/grep判断的）。
# 以下内容超出本脚本能力，由 Agent 在 COMPLETION GATE 中语义判断：
#   - 推荐理由的质量与逻辑自洽性
#   - 商品是否真正满足用户需求
#   - 风险评估是否充分
#   - 经验引用是否有依据
#   - 表达是否含"绝对化无条件断言"（[S4]）
#   - 执行模式选择是否合理（[G0] 选择本身）
# 本脚本仅验证"执行模式是否已声明"，不判断"选择是否正确"。
# ═══════════════════════════════════════════════════════════════
#
# 用法: bash validate-report.sh [报告文件路径] [执行模式]
#   执行模式可选: quick / standard / deep (默认 deep)

set -e

# 参数处理
# $1 = 报告文件路径（可选，默认自动查找今日报告）
# $2 = 执行模式（可选，默认 deep）
if [ -n "$1" ]; then
  REPORT="$1"
else
  REPORT=$(ls -t 购买决策_*_"$(date +%Y%m%d)".md 2>/dev/null | head -1)
fi

# 执行模式：quick / standard / deep
MODE="${2:-deep}"
MODE=$(echo "$MODE" | tr '[:upper:]' '[:lower:]')
if [[ "$MODE" != "quick" && "$MODE" != "standard" && "$MODE" != "deep" ]]; then
  echo "⚠️  未识别的执行模式 '$MODE'，回退为 deep"
  MODE="deep"
fi

if [ -z "$REPORT" ] || [ ! -f "$REPORT" ]; then
  echo "❌ FAIL: 未找到报告文件"
  echo "   期望: 购买决策_*_$(date +%Y%m%d).md"
  exit 1
fi

echo "📄 校验: $REPORT"
echo "📋 执行模式: $MODE"
PASS=true
WARNINGS=0

# ──────────────────────────────────────────────
# 1. 检查文件命名格式
# ──────────────────────────────────────────────
BASENAME=$(basename "$REPORT")
if echo "$BASENAME" | grep -qE '^购买决策_.+_[0-9]{8}\.md$'; then
  echo "   ✅ 文件命名: $BASENAME"
else
  echo "   ❌ 文件命名格式不合规，期望: 购买决策_{品类}_{YYYYMMDD}.md"
  PASS=false
fi

# ──────────────────────────────────────────────
# 2. 检查必需章节（按模式分层）
# ──────────────────────────────────────────────
# 基础章节 — 所有模式必须
BASE_SECTIONS=(
  "需求与推荐"
  "购买需求"
  "筛选思路与核心关注点"
  "综合 Top 5 推荐"
  "核心排除 Top 10"
)

# 按模式确定要检查的章节
REQUIRED_SECTIONS=("${BASE_SECTIONS[@]}")

for section in "${REQUIRED_SECTIONS[@]}"; do
  if grep -q "$section" "$REPORT"; then
    echo "   ✅ 章节: $section"
  else
    echo "   ❌ 缺少章节: $section"
    PASS=false
  fi
done

# ──────────────────────────────────────────────
# 3. 检查综合推荐是否包含链接
# ──────────────────────────────────────────────
if grep -A 200 "综合 Top 5 推荐" "$REPORT" | grep -q "https://"; then
  echo "   ✅ 综合推荐包含商品链接"
else
  echo "   ❌ 综合推荐缺少商品详情链接"
  PASS=false
fi

# ──────────────────────────────────────────────
# 3.5 [L1] 强制检查：Top 5 每项必须有链接
# 检查方式：在"各推荐详情"或 Top 5 表格中，Top 1-5 每项至少有一个 https:// 链接
# 如果 Top 5 表格本身有链接列，直接通过；否则逐一检查详情段
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  TOP5_LINK_MISSING=""
  for i in 1 2 3 4 5; do
    # 策略1：检查 Top 5 表格中该行是否有链接
    ROW_HAS_LINK=false
    if [ -n "$TOP5_BLOCK" ]; then
      # 提取 Top 5 表格中排名为 i 的行，检查是否含 https://
      if echo "$TOP5_BLOCK" | grep -E "^\| *$i *\|" | grep -q "https://"; then
        ROW_HAS_LINK=true
      fi
    fi

    # 策略2：检查详情段中是否有链接（"Top N:" 或 "Top N：" 后面跟的区域内）
    DETAIL_HAS_LINK=false
    # 查找 "Top N:" 标记行号
    DETAIL_LINE=$(grep -n -E "####.*Top *$i[:：]|###.*Top *$i[:：]" "$REPORT" | head -1 | cut -d: -f1)
    if [ -n "$DETAIL_LINE" ]; then
      # 从该行向下取30行（足够覆盖一个推荐详情块），检查是否含 https://
      DETAIL_BLOCK=$(tail -n +"$DETAIL_LINE" "$REPORT" | head -30)
      if echo "$DETAIL_BLOCK" | grep -q "https://"; then
        DETAIL_HAS_LINK=true
      fi
    fi

    if ! $ROW_HAS_LINK && ! $DETAIL_HAS_LINK; then
      TOP5_LINK_MISSING="$TOP5_LINK_MISSING Top$i"
    fi
  done

  if [ -z "$TOP5_LINK_MISSING" ]; then
    echo "   ✅ [L1] Top 5 每项均有商品链接"
  else
    echo "   ❌ [L1] Top 5 以下项缺少商品链接:$TOP5_LINK_MISSING（⛔ 每项推荐必须有可点击的商品详情链接）"
    PASS=false
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过 Top 5 每项链接检查"
fi

# ──────────────────────────────────────────────
# 4. 警告：检查是否只有占位符链接
# ──────────────────────────────────────────────
if grep -q "\[查看\](https://\.\.\.)" "$REPORT"; then
  echo "   ⚠️  发现占位符链接 (https://...)，部分链接未填充真实 URL"
  WARNINGS=$((WARNINGS + 1))
fi

# ──────────────────────────────────────────────
# 5. 警告：检查小红书是否被误用作商品来源
# ──────────────────────────────────────────────
if grep -A 200 "综合 Top 5 推荐" "$REPORT" | grep -qi "小红书.*→\|xhs.*→"; then
  echo "   ❌ 综合 Top 5 中包含小红书来源商品（⛔ [X1][X5] 小红书不作为商品来源）"
  PASS=false
else
  echo "   ✅ 综合 Top 5 无小红书来源商品"
fi

# ──────────────────────────────────────────────
# 5.5 [R1] 检查：综合 Top 5 中京东/拼多多直链是否有平台选择理由
# v3.7.0+ 跨平台性价比优先：京东/拼多多可直接进 Top 5，但须附平台选择理由
# 只检查"综合 Top 5 推荐"到下一个 ## 标题之间的区域
# ──────────────────────────────────────────────
TOP5_START=$(grep -n "### 综合 Top 5 推荐" "$REPORT" | head -1 | cut -d: -f1)
if [ -n "$TOP5_START" ]; then
  # 找到"综合 Top 5 推荐"之后的下一个 ## 标题行
  NEXT_H2=$(tail -n +"$((TOP5_START + 1))" "$REPORT" | grep -n "^## " | head -1 | cut -d: -f1)
  if [ -n "$NEXT_H2" ]; then
    TOP5_END=$((TOP5_START + NEXT_H2 - 1))
    TOP5_BLOCK=$(sed -n "${TOP5_START},${TOP5_END}p" "$REPORT")
  else
    # 没有后续 H2，取到文件末尾
    TOP5_BLOCK=$(tail -n +"$TOP5_START" "$REPORT")
  fi
  if echo "$TOP5_BLOCK" | grep -qi "jd\.com\|pinduoduo\.com"; then
    # 存在京东/拼多多链接，检查是否有平台选择理由或跨平台对比说明
    if echo "$TOP5_BLOCK" | grep -qi "平台选择理由\|跨平台性价比\|例外原因\|例外条件\|保留原因"; then
      echo "   ✅ 综合 Top 5 含京东/拼多多链接，已附平台选择理由 [R1]"
    else
      echo "   ❌ 综合 Top 5 含京东/拼多多链接但未附平台选择理由（⛔ [R1] 违规：跨平台推荐须说明选择理由）"
      PASS=false
    fi
  else
    echo "   ✅ 综合 Top 5 无京东/拼多多直链"
  fi
else
  echo "   ⚠️  未找到综合 Top 5 章节，跳过京东/拼多多直链检查"
  WARNINGS=$((WARNINGS + 1))
fi

# ──────────────────────────────────────────────
# 5.6 强制检查：综合 Top 5 链接格式 — 商品详情页 vs 搜索页/店铺首页
# 对应 HARD RULES [L2] — 链接必须是商品详情页 URL
# Quick Mode 跳过此检查
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  if [ -n "$TOP5_BLOCK" ]; then
    if echo "$TOP5_BLOCK" | grep -qiE 's\.taobao\.com/search|list\.taobao\.com'; then
      echo "   ❌ 综合 Top 5 包含搜索页/列表页链接（⛔ [L2] 违规：必须是商品详情页 detail.tmall.com 或 item.taobao.com 或 goofish.com）"
      PASS=false
    else
      echo "   ✅ 综合 Top 5 链接格式合规（商品详情页）"
    fi
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过链接格式检查"
fi

# ──────────────────────────────────────────────
# 5.7 弱校验：商品详情页链接 ID 是否为数字格式
# 检查 tmall item.htm?id= 和 jd.com/XXX.html 的 ID 部分
# 非数字 ID（如 "cory-m9s"、"半弦月-贴贴枕"）说明占位符未替换
# 仅 WARN 不 FAIL — 文本 ID 链接可能因特殊原因存在，不直接判不合格
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  if [ -n "$TOP5_BLOCK" ]; then
    # 提取 tmall/id= 参数值
    TMALL_IDS=$(echo "$TOP5_BLOCK" | grep -oP 'detail\.tmall\.com/item\.htm\?id=\K[^&)\s"]+' 2>/dev/null || true)
    NON_NUMERIC=()
    if [ -n "$TMALL_IDS" ]; then
      while IFS= read -r pid; do
        pid=$(echo "$pid" | sed 's/[^a-zA-Z0-9_-]//g')
        if [ -n "$pid" ] && ! [[ "$pid" =~ ^[0-9]+$ ]]; then
          NON_NUMERIC+=("$pid")
        fi
      done <<< "$TMALL_IDS"
    fi
    # 提取 jd.com/ 商品ID
    JD_IDS=$(echo "$TOP5_BLOCK" | grep -oP 'item\.jd\.com/\K[0-9]+(?=\.html)' 2>/dev/null || true)
    JD_NON_NUMERIC=()
    if [ -n "$JD_IDS" ]; then
      while IFS= read -r jid; do
        if [ -n "$jid" ] && ! [[ "$jid" =~ ^[0-9]+$ ]]; then
          JD_NON_NUMERIC+=("$jid")
        fi
      done <<< "$JD_IDS"
    fi

    if [ ${#NON_NUMERIC[@]} -gt 0 ]; then
      echo "   ⚠️  [L2] 综合 Top 5 中天猫链接含非数字 ID: ${NON_NUMERIC[*]}（可能为占位符未替换，请人工确认）"
      WARNINGS=$((WARNINGS + 1))
    elif [ ${#JD_NON_NUMERIC[@]} -gt 0 ]; then
      echo "   ⚠️  [L2] 综合 Top 5 中京东链接含非数字 SKU: ${JD_NON_NUMERIC[*]}（可能为占位符未替换，请人工确认）"
      WARNINGS=$((WARNINGS + 1))
    else
      echo "   ✅ 综合 Top 5 链接 ID 格式有效（均为数字 ID）"
    fi
  fi
fi

# ──────────────────────────────────────────────
# 6. 检查 Top1 推荐理由是否覆盖三维度 bullet 格式
# Quick Mode 跳过此检查
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  TOP1_FIELDS=(
    "小红书避坑经验"
    "突出优势"
    "需求匹配"
  )

  # 提取综合推荐区域
  DECISION_START=$(grep -n "综合 Top 5 推荐" "$REPORT" | head -1 | cut -d: -f1)
  if [ -n "$DECISION_START" ]; then
    # 取 Top 5 区域前 100 行（Top1 应在前 100 行内）
    DECISION_BLOCK=$(tail -n +"$DECISION_START" "$REPORT" | head -100)

    MISSING_FIELDS=""
    for field in "${TOP1_FIELDS[@]}"; do
      if ! echo "$DECISION_BLOCK" | grep -q "$field"; then
        MISSING_FIELDS="$MISSING_FIELDS $field"
      fi
    done

    if [ -z "$MISSING_FIELDS" ]; then
      echo "   ✅ Top1 推荐理由三维度 bullet 齐全"
    else
      echo "   ❌ Top1 推荐理由缺少维度:$MISSING_FIELDS"
      PASS=false
    fi
  else
    echo "   ⚠️  未找到综合决策章节，跳过 Top1 字段检查"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过 Top1 三维度检查"
fi

# ──────────────────────────────────────────────
# 7. 检查超预算标注（Quick Mode 跳过）
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  if grep -q "超出预算" "$REPORT" || grep -q "⚠️" "$REPORT"; then
    echo "   ✅ 超预算标注存在（如有超预算商品）"
  else
    echo "   ⚠️  未发现超预算标注（可能预算内全部满足，或遗漏标注）"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过超预算标注检查"
fi

# ──────────────────────────────────────────────
# 8. 检查推荐强度字段（Quick Mode 跳过）
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  if grep -q "推荐强度" "$REPORT"; then
    echo "   ✅ 推荐强度字段存在"
  else
    echo "   ❌ 缺少推荐强度字段"
    PASS=false
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过推荐强度检查"
fi

# ──────────────────────────────────────────────
# 9. 检查链接验证声明（Quick Mode 跳过）
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  if grep -q "链接验证声明" "$REPORT" || grep -q "链接已在.*搜索阶段.*验证\|有效性验证" "$REPORT"; then
    echo "   ✅ 链接验证声明存在"
  else
    echo "   ⚠️  未找到链接验证声明段落"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过链接验证声明检查"
fi

# ──────────────────────────────────────────────
# 10. 检查是否残留未填充的 {{REQUIRED}} 占位符
# ──────────────────────────────────────────────
# grep -c always outputs count to stdout (including "0") but exits 1 for zero matches.
# Don't use || fallback as it appends a second "0" — just capture the output directly.
REQUIRED_COUNT=$(grep -c "{{REQUIRED}}" "$REPORT" 2>/dev/null) || true
if [ "$REQUIRED_COUNT" -eq 0 ]; then
  echo "   ✅ 无残留 {{REQUIRED}} 占位符"
else
  echo "   ❌ 发现 $REQUIRED_COUNT 处未填充的 {{REQUIRED}} 占位符"
  PASS=false
fi

# ──────────────────────────────────────────────
# 11. [G0] 执行模式声明检查
# 报告中必须包含执行模式标注
# ──────────────────────────────────────────────
if grep -qi "执行模式\|Quick Mode\|Standard Mode\|Deep Mode" "$REPORT"; then
  echo "   ✅ [G0] 执行模式声明存在"
else
  echo "   ❌ [G0] 报告中未声明执行模式（必须在需求摘要中标注 Quick/Standard/Deep）"
  PASS=false
fi

# ──────────────────────────────────────────────
# 14. [R6] 闲鱼/拼多多风险独立评估检查（Standard/Deep）
# 如果报告同时包含闲鱼和拼多多内容，检查是否有独立风险评估
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  HAS_XIANYU=$(grep -c "闲鱼" "$REPORT" 2>/dev/null) || true
  HAS_PDD=$(grep -c "拼多多" "$REPORT" 2>/dev/null) || true
  if [ "$HAS_XIANYU" -gt 0 ] && [ "$HAS_PDD" -gt 0 ]; then
    # 检查是否有分别评估的痕迹（存在各自的风险/评估/成色/品控关键词）
    if grep -q "闲鱼.*成色\|闲鱼.*信用\|闲鱼.*二手" "$REPORT" && grep -q "拼多多.*品控\|拼多多.*白牌\|拼多多.*百亿补贴" "$REPORT"; then
      echo "   ✅ [R6] 闲鱼/拼多多风险独立评估"
    else
      echo "   ⚠️  [R6] 闲鱼和拼多多可能未独立评估风险，请确认"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过 R6 风险独立评估检查"
fi

# ──────────────────────────────────────────────
# 15. [R2a] Top 5 三价格层次标签完整性检查（Standard/Deep）
# 综合 Top 5 必须覆盖三个价格层次：💰 性价比之选 / ✅ 稳妥之选 / ⭐ 品质之选
# 检查方式：在 Top 5 区域内搜索三个 emoji 标签，缺失任一则 FAIL
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  if [ -n "$TOP5_BLOCK" ]; then
    MISSING_TIERS=""
    # 💰 性价比之选
    if ! echo "$TOP5_BLOCK" | grep -q '💰'; then
      MISSING_TIERS="$MISSING_TIERS 💰性价比之选"
    fi
    # ✅ 稳妥之选
    if ! echo "$TOP5_BLOCK" | grep -q '✅'; then
      MISSING_TIERS="$MISSING_TIERS ✅稳妥之选"
    fi
    # ⭐ 品质之选
    if ! echo "$TOP5_BLOCK" | grep -q '⭐'; then
      MISSING_TIERS="$MISSING_TIERS ⭐品质之选"
    fi

    if [ -z "$MISSING_TIERS" ]; then
      echo "   ✅ [R2a] Top 5 三价格层次标签齐全（💰✅⭐）"
    else
      echo "   ❌ [R2a] Top 5 缺少价格层次标签:$MISSING_TIERS（⛔ [B8][R2a] 强制：三个层次必须都有覆盖）"
      PASS=false
    fi
  else
    echo "   ⚠️  [R2a] 未找到 Top 5 区域，跳过价格层次标签检查"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过 R2a 价格层次标签检查"
fi

# ──────────────────────────────────────────────
# 16. [S4] 绝对化表达检出（全模式）
# 检查报告中是否出现无依据绝对化表达，命中则 WARN
# 允许出现在引用他人评价的语境中，但推荐结论区域出现需警惕
# ──────────────────────────────────────────────
ABSOLUTE_WORDS=(
  "闭眼入"
  "零差评"
  "完全无风险"
  "必买"
  "无敌"
  "绝不出错"
  "绝对值得"
  "唯一推荐"
  "唯一选择"
  "没有之一"
)
ABSOLUTE_FOUND=""
for word in "${ABSOLUTE_WORDS[@]}"; do
  if grep -q "$word" "$REPORT"; then
    ABSOLUTE_FOUND="$ABSOLUTE_FOUND \"$word\""
  fi
done

if [ -z "$ABSOLUTE_FOUND" ]; then
  echo "   ✅ [S4] 未发现绝对化表达"
else
  echo "   ⚠️  [S4] 发现可能的无依据绝对化表达:$ABSOLUTE_FOUND（⛔ [S4] 禁止无证据绝对化，请替换为有条件表述）"
  WARNINGS=$((WARNINGS + 1))
fi

# ──────────────────────────────────────────────
# 17. [B5][B6][B7] 三项必明确字段存在性检查（Standard/Deep）
# 报告"购买需求"区域必须包含：预算范围、二手接受度、白牌/平替接受度
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  # 提取购买需求区域（从"购买需求"到下一个 ### 或 ## 标题）
  DEMAND_START=$(grep -n "### 购买需求\|## 购买需求" "$REPORT" | head -1 | cut -d: -f1)
  if [ -n "$DEMAND_START" ]; then
    DEMAND_NEXT=$(tail -n +"$((DEMAND_START + 1))" "$REPORT" | grep -n "^###\|^## " | head -1 | cut -d: -f1)
    if [ -n "$DEMAND_NEXT" ]; then
      DEMAND_BLOCK=$(sed -n "${DEMAND_START},$((DEMAND_START + DEMAND_NEXT - 1))p" "$REPORT")
    else
      DEMAND_BLOCK=$(tail -n +"$DEMAND_START" "$REPORT" | head -30)
    fi

    MISSING_FIELDS=""
    # [B5] 预算范围
    if ! echo "$DEMAND_BLOCK" | grep -q "预算"; then
      MISSING_FIELDS="$MISSING_FIELDS 预算范围[B5]"
    fi
    # [B6] 二手接受度
    if ! echo "$DEMAND_BLOCK" | grep -q "二手"; then
      MISSING_FIELDS="$MISSING_FIELDS 二手接受度[B6]"
    fi
    # [B7] 白牌/平替接受度
    if ! echo "$DEMAND_BLOCK" | grep -q "白牌\|平替"; then
      MISSING_FIELDS="$MISSING_FIELDS 白牌/平替接受度[B7]"
    fi

    if [ -z "$MISSING_FIELDS" ]; then
      echo "   ✅ [B5][B6][B7] 购买需求区域三项必明确字段齐全"
    else
      echo "   ❌ [B5][B6][B7] 购买需求区域缺少必明确字段:$MISSING_FIELDS（⛔ 预算/二手接受度/白牌接受度必须明确）"
      PASS=false
    fi
  else
    echo "   ⚠️  [B5][B6][B7] 未找到购买需求章节，跳过三项必明确检查"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过 B5/B6/B7 三项必明确检查"
fi

# ──────────────────────────────────────────────
# 18. [R7] 筛选思路与核心关注点章节检查（Standard/Deep）
# 必须包含核心关注维度（≥3个）、避坑要点（≥2条）、筛选逻辑
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  FILTER_SECTION=$(grep -n "筛选思路与核心关注点" "$REPORT" | head -1 | cut -d: -f1)
  if [ -n "$FILTER_SECTION" ]; then
    echo "   ✅ [R7] 筛选思路与核心关注点章节存在"
    # 检查核心关注维度
    FILTER_BLOCK=$(tail -n +"$FILTER_SECTION" "$REPORT" | head -60)
    if echo "$FILTER_BLOCK" | grep -q "核心关注维度"; then
      # 统计维度数量（编号列表项 1. 2. 3. 等）
      DIM_COUNT=$(echo "$FILTER_BLOCK" | grep -cE '^[0-9]+\.' 2>/dev/null) || true
      if [ "$DIM_COUNT" -ge 3 ]; then
        echo "   ✅ [R7] 核心关注维度 ≥3 个（实际: $DIM_COUNT）"
      else
        echo "   ❌ [R7] 核心关注维度不足 3 个（实际: $DIM_COUNT，⛔ 要求 ≥3）"
        PASS=false
      fi
    else
      echo "   ❌ [R7] 缺少「核心关注维度」子章节"
      PASS=false
    fi
    # 检查避坑要点
    if echo "$FILTER_BLOCK" | grep -q "避坑要点"; then
      PITFALL_ROWS=$(echo "$FILTER_BLOCK" | grep -A 20 "避坑要点" | grep -cE '^\| [0-9]' 2>/dev/null) || true
      if [ "$PITFALL_ROWS" -ge 2 ]; then
        echo "   ✅ [R7] 避坑要点 ≥2 条（实际: $PITFALL_ROWS）"
      else
        echo "   ❌ [R7] 避坑要点不足 2 条（实际: ${PITFALL_ROWS:-0}，⛔ 要求 ≥2）"
        PASS=false
      fi
    else
      echo "   ❌ [R7] 缺少「避坑要点」子章节"
      PASS=false
    fi
    # 检查筛选逻辑
    if echo "$FILTER_BLOCK" | grep -q "筛选逻辑"; then
      echo "   ✅ [R7] 筛选逻辑说明存在"
    else
      echo "   ❌ [R7] 缺少「筛选逻辑」子章节"
      PASS=false
    fi
  else
    echo "   ❌ [R7] 缺少「筛选思路与核心关注点」章节（⛔ [R7] 强制要求）"
    PASS=false
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过 R7 筛选思路检查"
fi

# ──────────────────────────────────────────────
# 19. [R8] 核心排除 Top 10 章节检查（Standard/Deep）
# 必须有 10 件排除商品，每件必须有核心排除理由
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  EXCLUDE_SECTION=$(grep -n "核心排除 Top 10" "$REPORT" | head -1 | cut -d: -f1)
  if [ -n "$EXCLUDE_SECTION" ]; then
    echo "   ✅ [R8] 核心排除 Top 10 章节存在"
    EXCLUDE_BLOCK=$(tail -n +"$EXCLUDE_SECTION" "$REPORT" | head -30)
    # 统计表格数据行数
    EXCLUDE_ROWS=$(echo "$EXCLUDE_BLOCK" | grep -cE '^\| [0-9]' 2>/dev/null) || true
    if [ "$EXCLUDE_ROWS" -ge 8 ]; then
      echo "   ✅ [R8] 核心排除商品 ≥8 件（实际: $EXCLUDE_ROWS）"
    elif [ "$EXCLUDE_ROWS" -ge 5 ]; then
      echo "   ⚠️  [R8] 核心排除商品仅 $EXCLUDE_ROWS 件（⛔ 要求 10 件）"
      WARNINGS=$((WARNINGS + 1))
    else
      echo "   ❌ [R8] 核心排除商品仅 ${EXCLUDE_ROWS:-0} 件（⛔ 要求 10 件）"
      PASS=false
    fi
    # 检查排除理由是否关联筛选思路（排除理由中应包含筛选维度或避坑相关关键词）
    EXCLUDE_REASONS=$(echo "$EXCLUDE_BLOCK" | grep -E '^\| [0-9]' | grep -cE '维度|避坑|关注|不符合|不满足|触发|违反|未通过|不达标' 2>/dev/null) || true
    if [ "$EXCLUDE_REASONS" -ge 5 ]; then
      echo "   ✅ [R8] 排除理由与筛选思路关联良好（$EXCLUDE_REASONS/$EXCLUDE_ROWS 条含关联关键词）"
    elif [ "$EXCLUDE_ROWS" -ge 5 ]; then
      echo "   ⚠️  [R8] 仅 $EXCLUDE_REASONS/$EXCLUDE_ROWS 条排除理由含筛选思路关联关键词，请确认排除理由是否具体"
      WARNINGS=$((WARNINGS + 1))
    fi
  else
    echo "   ❌ [R8] 缺少「核心排除 Top 10」章节（⛔ [R8] 强制要求）"
    PASS=false
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过 R8 核心排除检查"
fi

# ──────────────────────────────────────────────
# 20. [R9] 核心关注点字段检查（Standard/Deep）
# 购买需求区域必须包含「🎯 核心关注点」字段
# ──────────────────────────────────────────────
if [[ "$MODE" != "quick" ]]; then
  if [ -n "$DEMAND_BLOCK" ]; then
    if echo "$DEMAND_BLOCK" | grep -q "核心关注点"; then
      echo "   ✅ [R9] 购买需求包含「核心关注点」字段"
    else
      echo "   ❌ [R9] 购买需求缺少「🎯 核心关注点」字段（⛔ [R9] 强制要求）"
      PASS=false
    fi
  else
    echo "   ⚠️  [R9] 未找到购买需求章节，跳过核心关注点检查"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  echo "   ⏭️  [Quick Mode] 跳过 R9 核心关注点检查"
fi

# ──────────────────────────────────────────────
# 结果汇总
# ──────────────────────────────────────────────
echo ""
if $PASS; then
  echo "✅ 报告基础结构验证通过 [$MODE mode]"
  if [ $WARNINGS -gt 0 ]; then
    echo "   ($WARNINGS 条警告，请人工确认)"
  fi
  exit 0
else
  echo "❌ 报告验证失败 [$MODE mode]，请回到 COMPLETION GATE 补齐缺失项"
  exit 1
fi

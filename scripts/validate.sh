#!/usr/bin/env bash
# 知识库机械校验 —— .agents/rules/013-机械校验.md 的执行器
# 用法: bash scripts/validate.sh
# 退出码: 0=全部通过, 1=存在 FAIL（此时禁止提交，修复后重跑）
set -u
cd "$(dirname "$0")/.." || exit 1
FAIL=0
ok()  { echo "  [PASS] $1"; }
bad() { echo "  [FAIL] $1"; FAIL=1; }
note(){ echo "  [warn] $1"; }

echo "== 1/5 md 链接解析 =="
BROKEN=0
while IFS=$'\t' read -r f p; do
  [ -n "$f" ] || continue
  d=$(dirname "$f")
  if [ ! -f "$d/$p" ]; then echo "         BROKEN: $f -> $p"; BROKEN=1; fi
done < <(grep -rEo ']\([^)#]+\.md\)' --include='*.md' 体系文档 README.md AGENTS.md 2>/dev/null \
  | sed -E 's/^([^:]+):.*\]\(([^)]+)\)$/\1\t\2/' | tr -d '\r' | sed 's|\\|/|g')
# 注：不扫 .agents/rules——规则里的 ](README.md) 等是体例格式示例（同 SVG 约定示例行的处理）
if [ "$BROKEN" -eq 0 ]; then ok "md 链接全部解析"; else bad "存在损坏的 md 链接"; fi

echo "== 2/5 SVG 引用与文件对账 =="
REFTMP=$(mktemp); FILETMP=$(mktemp); RESOLVED=$(mktemp)
grep -rEo '!\[[^]]*\]\([^)]*\.svg\)' --include='*.md' 体系文档 README.md 2>/dev/null \
  | sed -E 's/^([^:]+):.*\]\(([^)]+)\)$/\1\t\2/' | tr -d '\r' | sed 's|\\|/|g' \
  | grep -v '相对路径' | grep -v 'NN-MM' > "$REFTMP"
REFN=$(wc -l < "$REFTMP" | tr -d ' ')
( cd 体系文档 && find . -name '*.svg' -not -path '*_render*' ) | sed 's|^\./||; s|^|体系文档/|' | sort > "$FILETMP"
FILEN=$(wc -l < "$FILETMP" | tr -d ' ')
B2=0
while IFS=$'\t' read -r f p; do
  [ -n "$f" ] || continue
  d=$(dirname "$f")
  if [ ! -f "$d/$p" ]; then echo "         BROKEN: $f -> $p"; B2=1; fi
  echo "$d/$p" | sed 's|^\./||' | sed 's|\\|/|g'
done < "$REFTMP" | sort > "$RESOLVED"
UNIQ=$(wc -l < "$RESOLVED" | tr -d ' ')
ORPH=$(comm -13 "$RESOLVED" "$FILETMP" | head -3)
[ -z "$ORPH" ] || { echo "         孤儿图: $ORPH"; B2=1; }
if [ "$B2" -eq 0 ] && [ "$REFN" -eq "$FILEN" ] && [ "$UNIQ" -eq "$FILEN" ]; then
  ok "SVG 引用 $REFN = 文件 $FILEN，零孤儿零重复"
else
  bad "SVG 对账不符: 引用=$REFN 去重=$UNIQ 文件=$FILEN"
fi
rm -f "$REFTMP" "$FILETMP" "$RESOLVED"

echo "== 3/5 README 状态表数字对账 =="
board_n=$(ls -d 体系文档/0[0-9][0-9]-*/ 2>/dev/null | wc -l | tr -d ' ')
gloss_n=$(find 体系文档 -name '00-术语表.md' | wc -l | tr -d ' ')
book_n=$(find 体系文档 -name '*.md' | grep -cE '/([0-9]{3}|[AB])-[^/]*\.md$')
svg_f=$(find 体系文档 -name '*.svg' -not -path '*_render*' | wc -l | tr -d ' ')
claim(){ grep -E "^\| $1 " README.md | head -1 | grep -oE '[0-9]+' | head -1; }
for pair in "板块:$board_n" "正文册:$book_n" "术语表:$gloss_n"; do
  label=${pair%%:*}; actual=${pair##*:}; claimed=$(claim "$label")
  if [ "$claimed" = "$actual" ]; then ok "$label: 声称 $claimed = 实数 $actual"; else bad "$label: 声称 $claimed != 实数 $actual"; fi
done
claimed_svg=$(claim '手写 SVG 配图'); claimed_ref=$(claim '图片引用')
if [ "$claimed_svg" = "$svg_f" ]; then ok "手写 SVG 配图: 声称 $claimed_svg = 实数 $svg_f"; else bad "手写 SVG 配图: 声称 $claimed_svg != 实数 $svg_f"; fi
if [ "$claimed_ref" = "$REFN" ]; then ok "图片引用: 声称 $claimed_ref = 实数 $REFN"; else bad "图片引用: 声称 $claimed_ref != 实数 $REFN"; fi

echo "== 4/5 CRLF 统一 =="
CRLFBAD=0
while IFS= read -r f; do
  line=""
  IFS= read -r line < "$f" || true
  [[ "$line" == *$'\r'* ]] || { echo "         非 CRLF: $f"; CRLFBAD=1; }
done < <(find 体系文档 .agents/rules .agents/memorys _issues -name '*.md' 2>/dev/null; printf 'README.md\nAGENTS.md\n')
if [ "$CRLFBAD" -eq 0 ]; then ok "全部 md 为 CRLF"; else bad "存在非 CRLF 的 md 文件"; fi

echo "== 5/5 未完成标记扫描（仅提醒，不计失败）=="
todo=$(grep -rn 'TODO\|FIXME\|待补\|待填\|占位' --include='*.md' 体系文档 2>/dev/null | tr -d '\r' | wc -l | tr -d ' ')
if [ "$todo" -eq 0 ]; then ok "无 TODO/待补 标记"; else note "发现 $todo 处标记，人工确认是否该保留"; fi

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ 机械校验全部通过"; else echo "❌ 机械校验存在 FAIL，禁止提交"; fi
exit "$FAIL"

#!/usr/bin/env bash
# gen-train-one.sh <doc_id> [outdir] — 从你的文档库读一篇文档,调 LLM 生成 1 条训练样本(JSONL 行)
# 输出格式: {"query":"...","positive":"...","negative":"...","source_id":"<doc_id>"}
# 依赖两个你自己实现的钩子(见下),管线本身与任何具体文档库/LLM 服务解耦。
set -uo pipefail
DOC_ID="$1"
OUTDIR="${2:-./train-batch}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/$(echo "$DOC_ID" | tr '/ ' '__').jsonl"

# ── 钩子 1:读取文档内容(替换为你的文档库命令:cat 文件/数据库查询/API) ──
CONTENT=$(read_doc "$DOC_ID" 2>/dev/null)   # 自行实现 read_doc

if [ -z "$CONTENT" ]; then
  echo "{\"_error\":\"empty_content\",\"source_id\":\"$DOC_ID\"}" > "$OUT"; exit 0
fi
if [ "${#CONTENT}" -lt 200 ]; then
  echo "{\"_error\":\"too_short\",\"source_id\":\"$DOC_ID\",\"clen\":${#CONTENT}}" > "$OUT"; exit 0
fi

# ── 生成 prompt(要点:自然问句+同主题迷惑负段落+拒绝标准) ──
PROMPT="你是 embedding 训练集生成器。给定下面的文档段落:
1) 生成一个用户会自然提出、且这个段落是最佳答案的中文问句(query);
2) 从段落中摘出最能回答该问句的连续片段(positive,100-300字);
3) 写一个同主题但不能回答该问句的迷惑性段落(negative,与 positive 长度相当);
拒绝标准:若文档是纯目录/代码清单/无实义内容,输出 {\"_skip\": true}。
只输出一行 JSON:{\"query\":...,\"positive\":...,\"negative\":...}
--- 文档 ---
$CONTENT"

# ── 钩子 2:调 LLM(任意 OpenAI 兼容端点;示例用 curl,替换 \$LLM_BASE/\$LLM_KEY/\$LLM_MODEL) ──
RESP=$(curl -s -m 120 "$LLM_BASE/chat/completions" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $LLM_KEY" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'model':'$LLM_MODEL','max_tokens':1000,'temperature':0.7,'messages':[{'role':'user','content':sys.stdin.read()}]}))" <<< "$PROMPT")" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])")

# ── 解析校验后落盘(坏样本带 _error 落盘,不静默丢) ──
python3 - "$DOC_ID" "$OUT" <<'PY' <<< "$RESP"
import json, sys
doc_id, out = sys.argv[1], sys.argv[2]
raw = sys.stdin.read().strip()
try:
    # 容忍 LLM 包 markdown 代码块
    if raw.startswith("```"):
        raw = raw.strip("`").lstrip("json").strip()
    d = json.loads(raw)
    if d.get("_skip"):
        row = {"_error": "skipped_by_llm", "source_id": doc_id}
    elif all(k in d and isinstance(d[k], str) and d[k].strip() for k in ("query", "positive", "negative")):
        row = {"query": d["query"], "positive": d["positive"], "negative": d["negative"], "source_id": doc_id}
    else:
        row = {"_error": "missing_fields", "source_id": doc_id, "raw": raw[:200]}
except Exception as e:
    row = {"_error": f"parse_fail:{e}", "source_id": doc_id, "raw": raw[:200]}
open(out, "w").write(json.dumps(row, ensure_ascii=False) + "\n")
PY

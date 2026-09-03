#!/usr/bin/env bash
# gen-train-one.sh <doc_id> [outdir] — read one document from your document store, call an LLM to generate 1 training sample (one JSONL line)
# Output format: {"query":"...","positive":"...","negative":"...","source_id":"<doc_id>"}
# Depends on two hooks you implement yourself (see below); the pipeline itself is decoupled from any specific document store / LLM service.
set -uo pipefail
DOC_ID="$1"
OUTDIR="${2:-./train-batch}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/$(echo "$DOC_ID" | tr '/ ' '__').jsonl"

# ── Hook 1: read the document content (replace with your document-store command: cat a file / DB query / API) ──
CONTENT=$(read_doc "$DOC_ID" 2>/dev/null)   # implement read_doc yourself

if [ -z "$CONTENT" ]; then
  echo "{\"_error\":\"empty_content\",\"source_id\":\"$DOC_ID\"}" > "$OUT"; exit 0
fi
if [ "${#CONTENT}" -lt 200 ]; then
  echo "{\"_error\":\"too_short\",\"source_id\":\"$DOC_ID\",\"clen\":${#CONTENT}}" > "$OUT"; exit 0
fi

# ── Generation prompt (core: natural question + confusable same-topic negative passage + rejection criteria) ──
PROMPT="You are an embedding training-set generator. Given the document passage below:
1) Generate a question (query), in the document's language, that a user would naturally ask and for which this passage is the best answer;
2) Extract from the passage the contiguous fragment that best answers the question (positive, 100-300 characters);
3) Write a confusable passage on the same topic that cannot answer the question (negative, similar length to positive);
Rejection criteria: if the document is a bare table of contents / code listing / has no substantive content, output {\"_skip\": true}.
Output exactly one line of JSON: {\"query\":...,\"positive\":...,\"negative\":...}
--- document ---
$CONTENT"

# ── Hook 2: call the LLM (any OpenAI-compatible endpoint; example uses curl — replace \$LLM_BASE/\$LLM_KEY/\$LLM_MODEL) ──
RESP=$(curl -s -m 120 "$LLM_BASE/chat/completions" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $LLM_KEY" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'model':'$LLM_MODEL','max_tokens':1000,'temperature':0.7,'messages':[{'role':'user','content':sys.stdin.read()}]}))" <<< "$PROMPT")" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])")

# ── Parse, validate, write to disk (bad samples are written with _error, never silently dropped) ──
python3 - "$DOC_ID" "$OUT" <<'PY' <<< "$RESP"
import json, sys
doc_id, out = sys.argv[1], sys.argv[2]
raw = sys.stdin.read().strip()
try:
    # tolerate the LLM wrapping output in a markdown code fence
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

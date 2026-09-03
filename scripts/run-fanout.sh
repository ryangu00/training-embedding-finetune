#!/usr/bin/env bash
# run-fanout.sh <doc_id_list.txt> [outdir] [parallel] — 批量并行生成训练样本
# doc_id_list.txt: 每行一个文档 id(你的文档库枚举命令产出)
set -uo pipefail
LIST="$1"; OUTDIR="${2:-./train-batch}"; PAR="${3:-8}"
mkdir -p "$OUTDIR"
# 断点续跑:已有输出的 id 跳过
todo=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  f="$OUTDIR/$(echo "$id" | tr '/ ' '__').jsonl"
  [ -s "$f" ] && continue
  echo "$id"; todo=$((todo+1))
done < "$LIST" | xargs -P "$PAR" -I{} "$(dirname "$0")/gen-train-one.sh" {} "$OUTDIR"
echo "fanout done (new: $todo)" >&2

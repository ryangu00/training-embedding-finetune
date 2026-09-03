#!/usr/bin/env bash
# run-fanout.sh <doc_id_list.txt> [outdir] [parallel] — batch parallel training-sample generation
# doc_id_list.txt: one document id per line (produced by your document store's enumeration command)
set -uo pipefail
LIST="$1"; OUTDIR="${2:-./train-batch}"; PAR="${3:-8}"
mkdir -p "$OUTDIR"
# resumable: ids that already have output are skipped
todo=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  f="$OUTDIR/$(echo "$id" | tr '/ ' '__').jsonl"
  [ -s "$f" ] && continue
  echo "$id"; todo=$((todo+1))
done < "$LIST" | xargs -P "$PAR" -I{} "$(dirname "$0")/gen-train-one.sh" {} "$OUTDIR"
echo "fanout done (new: $todo)" >&2

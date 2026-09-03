# Fine-Tuning Your Own Embedding Model: From Training-Set Generation to Ollama Production Deployment

> Fine-tune an embedding model on your own knowledge base's style and deploy it as a resident Ollama service — the training pipeline, the deployment method,
> and three production incidents that hurt us badly (one of them silently degraded retrieval for a long time before anyone noticed).
> The training-set generation scripts ship with this repo; our training data itself is not published (it contains private corpora), but the schema and method are fully reproducible.

## Training pipeline (scripts included in this repo)

```
scripts/
  gen-train-one.sh      # Generate one training sample (LLM-assisted: the prompt's core = given a passage, generate a natural question that this passage would answer + one confusable negative passage on the same topic; includes rejection criteria to block low-quality samples)
  run-fanout.sh         # Batch parallel fan-out generation
  merge-and-verify.py   # Merge + dedupe + schema validation (failed samples are written to disk, never silently dropped)
```

Training-set schema (JSONL, one per line):
```json
{"query": "<retrieval-intent question>", "positive": "<the passage that should be hit>", "negative": "<a nearby passage that should NOT be hit>"}
```
Key points:
- **Use "close but wrong" passages as negatives** (same topic, different entity / same entity, different time period) — this trains a far more discriminative model than random negatives.
- Failed generations go into errors.jsonl for the record; never silently drop them — the failure-rate statistics are the first signal of training-set quality.
- Scale reference: across two iterations our training set grew from ~200KB to ~560KB (JSONL); our judgment from experience (not a controlled experiment): the second round's gains came mainly from negative-sample quality, not quantity.

## Deployment (Ollama + Modelfile)

**One-command deploy**: `scripts/deploy-ollama.sh <your.gguf> <name-ft>` — enforces a distinct `-ft` name (defense against incident #2) → explicit num_batch 16384 → long-input assertion → vector fingerprint written to disk (the foundation of the canary guard). Manual path:

Convert the fine-tuned weights to GGUF, then build an Ollama model service with a Modelfile. **Critical parameter**:

```
PARAMETER num_batch 16384
```

## Three production incidents (the core value of this book)

1. **The num_batch default crashes on long inputs**: the Ollama embedding runner defaults to `num_batch 2048` — any input over 2048 tokens **crashes with EOF**, and upstream only sees "all embeddings failing". Our batch-write job went down entirely, with the root cause hiding in this default. **Set `num_batch 16384` explicitly in the Modelfile, and carry it along every time you rebuild the model** (after fixing it once we missed it again on a rebuild, leaving a NULL hole).
2. **`ollama pull` silently overwrites a same-named fine-tuned model**: if your fine-tuned model uses the same model tag as one in the official library, any person or any automation running a single pull on that tag replaces your fine-tuned weights with the stock version — **retrieval quality silently degrades, with no error whatsoever**. Defense: (1) give fine-tuned models a **distinct name** (a `-ft` suffix or similar) that can never collide with an official name; (2) deploy a canary guard script: periodically embed a known query, compare the vector fingerprint, alert on drift.
3. **Verify content, not just bytes**: post-deploy verification that "the model is the right one" cannot rely on `ls -l` file sizes — the stock and fine-tuned versions are nearly identical in size. Assert on a fingerprint of the first N dimensions of the embedding vector for a fixed input.

## Measurement methodology

The fine-tuning gains show up in **retrieval hit rate on your own corpus** (in-domain terminology, naming conventions, document structure); scores on general benchmarks may well not look good — that is the whole point of specialization. Evaluation method: recall@k on a held-out set (k = the actual retrieval count of your production pipeline, commonly 5/10) versus the stock model, with real query logs as the query source and a 10-20% held-out ratio.

---
*RyanAI Lab · All numbers measured on our resident environment. Updated 2026-09. Issues welcome.*

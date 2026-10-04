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

**One-command deploy**: `scripts/deploy-ollama.sh <your.gguf> <name-ft>` — enforces a distinct `-ft` name (defense against incident #2) — explicit num_batch 16384 — long-input assertion — vector fingerprint written to disk (the foundation of the canary guard). In our own production we could not follow this advice: the application that consumes the embeddings enforced the configured embedding model name and reverted any attempt to change it, so the fine-tuned weights have lived under the stock model name since 2026-07-02 (created with `ollama cp <name>-ft <stock-name>`). That is exactly why we run a canary (see the 2026-10 update below). Manual path:

Convert the fine-tuned weights to GGUF, then build an Ollama model service with a Modelfile. **Critical parameter**:

```
PARAMETER num_batch 16384
```

## Three production incidents (the core value of this book)

1. **The num_batch default crashes on long inputs**: the Ollama embedding runner defaults to `num_batch 2048` — any input over 2048 tokens **crashes with EOF**, and upstream only sees "all embeddings failing". Our batch-write job went down entirely, with the root cause hiding in this default. **Set `num_batch 16384` explicitly in the Modelfile, and carry it along every time you rebuild the model** (after fixing it once we missed it again on a rebuild, leaving a NULL hole).
2. **`ollama pull` silently overwrites a same-named fine-tuned model**: if your fine-tuned model uses the same model tag as one in the official library, any person or any automation running a single pull on that tag replaces your fine-tuned weights with the stock version — **retrieval quality silently degrades, with no error whatsoever**. Defense: (1) give fine-tuned models a **distinct name** (a `-ft` suffix or similar) that can never collide with an official name (if your application lets you change the configured model name; ours did not, see below); (2) deploy a canary guard script: periodically embed a known query, compare the vector fingerprint, alert on drift.
3. **Verify content, not just bytes**: post-deploy verification that "the model is the right one" cannot rely on `ls -l` file sizes — the stock and fine-tuned versions can be nearly identical in size, and a copy of a model can differ in size and digest from its source without any difference in weights. In our own listing the fine-tuned F16 model is about 1.20 GB while the stock Q8_0 library model is about 0.64 GB, so a size check would happen to catch an overwrite in our case, but only because the quantizations differ. A same-quantization overwrite would not change the size. File size and digest are not identity; the embedded vector is (see the update below).

## Measurement methodology

The fine-tuning gains show up in **retrieval hit rate on your own corpus** (in-domain terminology, naming conventions, document structure); scores on general benchmarks may well not look good — that is the whole point of specialization. Evaluation method: recall@k on a held-out set (k = the actual retrieval count of your production pipeline, commonly 5/10) versus the stock model, with real query logs as the query source and a 10-20% held-out ratio. Our own numbers for this method are in the 2026-10 update below.

## Update (2026-10): scores, a numeric identity check, and lessons from running on a second host

### A. Score table (measured once each, 2026-07-02)

Setup: end-to-end hybrid retrieval (vector plus keyword search fused by reciprocal-rank fusion, with query expansion), no reranker, 30 candidates fetched and the top 10 kept, recency and salience boosts off. Evaluation set: 120 synthetic queries (generated by a language model from the content of one knowledge-base page each; the gold answer is that page). The queries and pages are private. Training pages and gold pages were checked to have zero overlap (the training set of that iteration had 301 examples; no claim is made here about which training iteration produced the scored weights).

| System | recall@1 | recall@5 | recall@10 | hits at 1 / 5 / 10 (of 120) |
|---|---|---|---|---|
| Stock embedding model | 0.35 | 0.6833 | 0.70 | 42 / 82 / 84 |
| Fine-tuned embedding model (served under the stock name) | 0.5667 | 0.825 | 0.8417 | 68 / 99 / 101 |
| Difference (points) | +21.7 | +14.2 | +14.2 | |

Conditions and caveats:
- Reported only: single run per system, no repeats, no confidence interval. One query is 0.83 points; the binomial standard error of a single recall@1 estimate near 0.57 at n=120 is about 4.5 points (computed), so the recall@1 gain is large relative to noise, while the smaller differences should be read with care.
- Stock baseline and fine-tuned runs were taken at different times on the same day against a corpus that was being modified; the corpus snapshots are not guaranteed identical. Embedding coverage during the fine-tuned run was 97.73 percent (33,959 of 34,747 chunks). Before gaps were filled, the fine-tuned recall@1 was 0.492, which shows how much missing vectors suppress results.
- The queries are synthetic, not real query logs.
- Corpus is about 34.7 thousand chunks of a private personal and engineering knowledge base. Embedding dimension 1024.

### B. Three-way cosine check (measured 2026-10-03)

Procedure (read-only; any Ollama install can repeat it): embed the same fixed input with three model names through `POST /api/embed` and compute the cosine of the returned 1024-dimensional vectors.
- Name A: the model served under the stock name in production (fine-tuned weights).
- Name B: the fine-tuned model under its own `-ft` name (the source of the copy).
- Name C: a backup copy of the original stock model (Q8_0).

Result on eight inputs (short English sentences, a code snippet, a short Chinese phrase, and one fixed canary sentence), local Ollama on an Apple M4 Max Mac with 64 GB:

| Comparison | Result |
|---|---|
| cosine(A, B) | 1.000000 on all eight inputs |
| cosine(A, C), stock | 0.741, 0.778, 0.821, 0.826, 0.906, 0.926, 0.947, 0.958 (one value per input) |

Findings:
- A and B return identical vectors. Their model-layer blob is the same file (identical blob digest in both manifests); only the manifest differs, so the two names have different digests and sizes (1,197,629,982 versus 1,197,629,801 bytes, a difference of 181 bytes) while the weights are the same.
- The stock-versus-fine-tuned cosine depends strongly on the input (0.74 to 0.96 here). Do not set an alert threshold on the stock side. The canary should assert that the name served in production matches the fine-tuned reference at cosine above 0.9999; an overwrite by the stock model shows up as a value well below 1.
- Canary rule used in production: embed one fixed sentence under both names, alert if cosine is 0.9999 or lower.

### C. Canary re-check after a bulk re-embedding (2026-09-27, plus today)

On 2026-09-27 a backlog of 43,822 chunks across 5,134 pages was re-embedded with the local Ollama, after which the remaining count of chunks without a vector was reported as 0 and the canary was recorded as "still the fine-tuned model". The cosine value for that check was not recorded (recorded as a pass). The 2026-10-03 re-check in section B gives 1.000000 on all eight inputs. Observed once on each date.

### D. Four pitfalls from running the same embedding service on a second host

All observed in 2026-09 while moving the service to a second host (details of that host are not needed for the lessons).

1. Fake high availability (observed 2026-09-24, fixed the same day). The failover proxy in front of the embedding endpoint had its primary and standby upstream set to the same address, so it protected against nothing. Fix: the standby now points, through an SSH tunnel, at an Ollama instance on another machine that holds the same fine-tuned weights (same digest). Rule recorded: the standby must serve the same fine-tuned model; a same-named stock model on another node would silently degrade the whole index. A drill with the primary pointed at a dead port confirmed the proxy falls over to the standby (tested once).
2. An image digest is not an identity. Copying a model under a new name produces a new digest while sharing the same weights blob (section B), so a differing digest does not prove different weights. Compare vectors with a cosine on a fixed input, not digests or sizes.
3. An endpoint that silently degrades. After a client configuration was copied to the second host, its embedding base URL pointed at a local port that was a load balancer whose upstream was an Ollama instance with no models loaded. Query-time embedding requests failed fast with HTTP 502 for roughly one day (2026-09-23 to 2026-09-24) while hybrid retrieval kept returning scored results from the keyword side, so nothing looked broken. The write path used a different, healthy route and was unaffected. Detection was by reading the configuration and comparing the top hits of one query before and after the fix (an old, loosely related document ranked first before the fix; relevant documents ranked first after). Keyword-only search scores are constant zero and cannot reveal this. Lesson: a health check must perform a real embedding, check the vector dimension and compare it with a fixed reference vector.
4. A fake alias. Model aliases named like hosted-API embedding models (implying 3072 and 1536 dimensions) had been created by copying the production model name; they had the same digest as the production model and actually returned 1024 dimensions. They had no active references and were removed from both hosts on 2026-09-23. Lesson: aliases created for compatibility must not advertise dimensions the weights do not produce.

### What is still unresolved

- Scores are one run each on a private synthetic set; no confidence interval; the baseline and the fine-tuned run did not use a guaranteed-identical corpus snapshot.
- Which training iteration produced the scored weights is not recorded in the evaluation record.
- Embedding coverage was measured as 97.73 percent on 2026-07-02. After the 2026-09-27 re-embedding the count of chunks without a vector was reported as 0; the coverage percentage was not recomputed and recall was not re-measured after that change.
- The cosine value of the 2026-09-27 canary check was not recorded.
- The stock-versus-fine-tuned cosine was measured on one machine only (eight inputs); whether it differs across chips was not measured.
- The effect of the roughly one-day silent degradation on retrieval quality was observed on one query only.

---
*RyanAI Lab · Numbers are measured on our resident environment unless marked as computed. Updated 2026-10. Issues welcome.*

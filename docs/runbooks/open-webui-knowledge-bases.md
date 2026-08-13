# Runbook: subject knowledge bases in Open WebUI (RAG)

How to give Open WebUI a body of reference material — a standards corpus, a
product manual, a rules system, internal documentation — and get answers grounded
in it with citations back to the source.

## How it works, in one pass

```
INGEST (once per document)
  file ──► extract text ──► split into chunks ──► embed each chunk ──► vector store

QUERY (every question)
  question ──┬─► embedded, compared against chunk vectors  ─┐
             └─► BM25 keyword search over the chunks       ─┴─► merged, top 5
                                                                     │
                                     system prompt + those 5 chunks + question
                                                                     │
                                                          answering model
                                                                     ▼
                                                   answer + source citations
```

An **embedding** turns text into a vector whose direction encodes meaning, so a
question retrieves passages that mean the same thing in different words. **BM25**
is plain keyword matching, which is what actually finds rare exact terms — domain
jargon, identifiers, defined terms. Running both and merging (**hybrid search**)
is why a technical corpus works at all; embeddings alone are weak precisely where
a subject corpus is most specific.

## Platform configuration (already in place)

| Setting                        | Value              | Why                                                                                                                                  |
| ------------------------------ | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `RAG_EMBEDDING_ENGINE`         | `openai`           | Embeddings run outside the pod, via LiteLLM                                                                                          |
| `RAG_EMBEDDING_MODEL`          | `b580:nomic-embed-text` | Served by Ollama on the GPU node                                                                                                     |
| `ENABLE_RAG_HYBRID_SEARCH`     | `true`             | BM25 + vector, merged                                                                                                                |
| `RAG_HYBRID_BM25_WEIGHT`       | `0.6`              | Tilted toward exact-term matching                                                                                                    |
| `RAG_TOP_K`                    | `5`                | Chunks injected into the prompt                                                                                                      |
| `CHUNK_SIZE` / `CHUNK_OVERLAP` | `1500` / `200`     | Keeps a table with the heading that gives it meaning                                                                                 |
| extraction engine              | unset (built-in)   | No sidecar; see [Preparing a corpus](#1-prepare-the-corpus)                                                                          |
| reranker                       | none               | Without one, chunks are ordered by cosine similarity against the same embeddings — no local model needed, which suits the slim image |

These are **global**, not per-collection. Changing them affects every knowledge
base on the instance, and changing chunking or the embedding model invalidates
everything already ingested (see [Re-ingest triggers](#re-ingest-triggers)).

## 1. Prepare the corpus

This step determines whether the whole thing works. The retrieval and model
layers cannot recover information that extraction destroyed.

**Prefer Markdown or plain text.** The built-in loader reads it directly, and
headings become natural chunk boundaries, so each chunk carries the context of
which section it came from.

**For PDFs:**

1. Confirm there is a text layer (`pdftotext file.pdf - | head`). If it comes out
   empty, the document is a scan — OCR it first with `ocrmypdf in.pdf out.pdf`,
   which adds a text layer without touching the page images.
2. Convert to Markdown **offline**, on a workstation. See the converters below.
3. **Read the output before uploading.** Two things break, and both are silent:
   multi-column pages interleaving into spliced sentences, and tables collapsing
   into unreadable runs of numbers. Re-run with a different tool on whatever came
   out mangled.

Converting outside the cluster is deliberate: it is a one-time job per document,
it keeps zero long-lived extraction pods on the node, and — most importantly — it
lets you inspect and iterate on the output, which is impossible once extraction is
buried inside an ingest pipeline.

### Converters

Ordered cheapest-first. Escalate only when the previous tier's output fails the
inspection in step 3 — the light tools are instant and often sufficient.

Only tools that are open source **without usage-gated tiers** are listed. Several
popular converters are free only below a revenue, page or seat threshold, or ship
non-commercial model weights; they are omitted deliberately, so check the licence
before adding a row here.

| Tool | Licence | Approach | Best at | Weight | Watch out for |
|---|---|---|---|---|---|
| `pdftotext -layout` (poppler) | GPL-2.0 | pure text extraction | checking whether a text layer exists; simple single-column documents | instant | no Markdown structure; tables become whitespace art |
| `pymupdf4llm` | AGPL-3.0 | PyMuPDF, heuristic | clean single-column PDFs, fast bulk conversion | instant, no models | weak on complex tables and multi-column |
| **`docling`** (IBM) | MIT | ML layout + TableFormer | the workhorse: multi-column text, tables, also DOCX/PPTX/HTML | moderate, CPU-viable | slower per page than the above |
| `PP-StructureV3` (PaddleOCR) | Apache-2.0 | ML layout + table recognition + OCR | table-dense documents; scans, without a separate OCR pass | moderate–heavy | heavier dependency stack to install |
| `MinerU` | AGPL-3.0 | ML layout, formulas, tables | documents the above still mangle; dense technical layouts | heavy, GPU recommended | CLI renamed across releases (`magic-pdf` → `mineru`) |

Notes:

- `docling`, `MinerU` and PaddleOCR are also engines Open WebUI can call as
  in-cluster services. Running them as CLI tools is the same work with a feedback
  loop and no permanent pod.
- Any of these benefit from a GPU but none require one; a one-off conversion
  taking minutes on CPU is not a problem for a job you run once per document.
- Output is Markdown plus an images directory. The images are not embedded and not
  retrievable — only the text is indexed, so diagrams effectively vanish. If a
  diagram carries information you will need, transcribe or caption it in the
  Markdown by hand.

Verify the result before uploading, not after:

```sh
grep -c '^#' out.md                 # headings survived → chunk boundaries exist
grep -n '^|' out.md | head          # tables are real Markdown tables
sed -n '400,420p' out.md            # spot-check a page you know
```

**Naming is citation.** The filename is what appears beside an answer, so encode
title and edition: `ISO-27001-2022.md`, not `standard.md`.

**Editions and addenda.** Index the current corrected edition. Do not expect the
model to reconcile an addendum or errata sheet against an original — retrieval has
no notion of precedence and will happily return a superseded passage with full
confidence. Where corrections matter, apply them to the text before ingesting.

## 2. Create the knowledge base

In the UI: **Workspace → Knowledge → Create**, then upload the prepared files.
(Menu labels drift between Open WebUI releases.)

Scope one collection per subject. Do not accumulate unrelated material in a single
collection — hybrid retrieval builds its BM25 index from the _whole_ collection on
every query, so both memory use and irrelevant matches grow with collection size.

Open the document view after upload and confirm the stored text is what you
expected. This is the last point at which a bad conversion is cheap to fix.

## 3. Sanity-check retrieval before trusting it

Reference the collection in a normal chat with `#` and ask questions **whose
answers you already know** — ten is enough to see the failure modes. You are
testing retrieval, not the model: if the right passage never appears in the
citations, no amount of prompt work will fix it.

If answers land on nearly-right passages:

| Symptom                                       | Knob                                              |
| --------------------------------------------- | ------------------------------------------------- |
| Right topic, wrong section                    | Raise `RAG_TOP_K`; consider a reranker            |
| Exact term ignored in favour of vague matches | Raise `RAG_HYBRID_BM25_WEIGHT` toward `0.7`–`0.8` |
| Tables or definitions arrive truncated        | Raise `CHUNK_SIZE`; re-ingest                     |
| Irrelevant collections bleeding in            | Split into narrower collections                   |

## 4. Create a Model for the subject

Rather than attaching knowledge ad hoc each time, define a Model
(**Workspace → Models**): pick a base model, attach the collection, and give it a
system prompt. That produces a single entry in the model picker, SSO-fronted and
usable from a phone.

A system prompt that works for reference corpora:

```
You answer questions about <subject> using only the provided context.

- Cite the source document and page or section for every claim.
- Quote the decisive sentence when the wording matters.
- If the context does not contain the answer, say so. Do not infer from
  general knowledge and do not fill gaps.
- If the context is ambiguous or two passages conflict, say that explicitly
  and cite both.
```

The instruction to refuse rather than infer is the important one. The default
behaviour of every model is to produce a plausible answer, and a plausible wrong
answer about a reference corpus is worse than no answer.

**Choosing the answering model.** Retrieval hands over passages; reconciling them
is reasoning work, and that is where small local models blend sources
confidently. For corpora with no confidentiality constraints, prefer a cloud alias
for answering — the embedding side stays local either way. For sensitive material,
keep everything local and accept a lower reasoning ceiling.

## 5. Keep an eval set

Every knob here — `CHUNK_SIZE`, `RAG_TOP_K`, `RAG_HYBRID_BM25_WEIGHT`, the
embedding model, which converter produced the Markdown — changes retrieval quality
**invisibly**. Without a fixed test set, a tuning change can improve one class of
question, break another, and look like an improvement because the question you
happened to retry got better.

Keep ~20 questions per corpus with known answers, recording the expected source and
page. Deliberately include: an exact-term lookup, one whose answer lives in a
table, one spanning two documents, and one the corpus genuinely **does not**
answer — the last checks that the model declines instead of inventing.

Re-run after any configuration or corpus change and note the pass count. Start
manual; a checklist and a tally catches regressions perfectly well. Building a
harness first is how this step never gets done. Tracked in #918.

## Re-ingest triggers

Re-uploading is required — not just recommended — after:

- **changing `RAG_EMBEDDING_MODEL`**: vectors are only comparable within one
  model. Old and new coordinates are unrelated, and mismatched retrieval fails
  _silently_, returning unrelated passages rather than an error.
- **changing `CHUNK_SIZE` / `CHUNK_OVERLAP`**: existing chunks keep their old
  boundaries.
- replacing or correcting a source document.

## Operational notes

- **The corpus is state, not config.** Uploaded files and their vectors live in
  the Open WebUI PVC, not in this repo. Pod restarts are fine; losing the PVC
  means re-uploading and re-embedding everything. No backup is configured, on the
  same reasoning as `litellm-postgres` — recreatable, at the cost of an afternoon.
- **Vector store** is Chroma in that PVC by default. `VECTOR_DB: pgvector` against
  CNPG is possible and would fold the vectors into a backed-up database, but the
  standard CNPG image does not ship the `vector` extension and
  `PGVECTOR_CREATE_EXTENSION` defaults to true while the cluster runs
  `enableSuperuserAccess: false` — so it needs a custom image and a grant. Not
  worth it below a large corpus.
- **Embeddings must stay on an always-on backend**, and must never be given a
  LiteLLM fallback: they are on the hot path of every query, and a fallback to a
  different model returns meaningless retrieval instead of degraded retrieval. See
  the `Embeddings` row in `docs/adr/0003-opportunistic-xtx-inference-tier.md`.
- **In-cluster extraction**, if ever wanted: the self-hostable engines are `tika`,
  `docling`, `mineru` and `paddleocr_vl`. Tika reserves ~1.5Gi by default for a job
  that runs once per document, and the other three are ML pipelines that cost more
  memory, not less. The remaining engines are third-party cloud APIs, which both
  meter per page and send the documents off-site. Offline conversion avoids every
  one of these trade-offs.
- The LiteLLM virtual key used by Open WebUI must permit the embedding model. If
  it is model-scoped and the embedding model is missing, chat keeps working while
  retrieval silently returns nothing.

## What this is good for, and what it isn't

It is an excellent **finder**: it will put the relevant passage in front of you in
seconds, with a citation, which is most of the value when you are looking
something up under time pressure.

It is a poor **arbiter**. Questions that require combining several sources and
knowing which one takes precedence are exactly where it will sound most confident
and be wrong. Mandatory citations are what make this safe — they turn every answer
into something you can verify in one click.

For questions scoped to a single chapter or section, pasting that section into a
long-context model directly beats retrieval. RAG earns its keep when you do not
know where the answer lives.

## Alternatives, and when to graduate

This runbook describes the cheapest approach that works with what is already
deployed — **not** the best retrieval available. It was chosen because the *access
surface* is what determines whether a knowledge base actually gets used: one entry
in the model picker, SSO, usable from a phone, citations one click away. Every
alternative below wins on some technical axis and loses on that one.

| Approach | Wins on | Loses on | Issue |
|---|---|---|---|
| Built-in Open WebUI RAG (this doc) | zero new infra, best access surface | global-only tuning, corpus is PVC state, click-ops setup | — |
| Own ingest pipeline + vector store | per-corpus settings, metadata filters, reproducible ingest | a component to maintain, with its own auth and backups | #919 |
| Full-text search only, no embeddings | legible failures, no re-embed cycle, cheap to operate | weaker on vaguely-worded questions | #920 |
| Long context, no retrieval | cannot fail to retrieve; simplest of all | context window and per-call cost | #921 |
| Agentic search over Markdown | best precision — multi-step beats one-shot | desk-only; useless from a phone mid-session | #921 |

Two changes are worth making **regardless** of whether any of the above happens,
because they make all of them available later at no extra cost:

1. **Move the corpus into version control** (#917). Converted Markdown in a
   dedicated repo — not this one, which drives clusters — gives reviewable diffs
   when a converter version changes the output, and makes the upload a publish step
   rather than the only copy.
2. **Keep an eval set** (#918, and step 5 above). Without it there is no way to
   know whether any of these alternatives is actually better than what it replaces.

Graduation triggers, concretely:

- **A second corpus wanting different chunking** → #919. This is a hard wall, not a
  preference: `CHUNK_SIZE` and the `RAG_*` settings are per-instance.
- **Retrieval keeps missing and vector distance offers no explanation** → #920.
- **Questions are usually already scoped to a known section** → #921 path A; skip
  retrieval for those rather than tuning it.

Umbrella issue: #922.

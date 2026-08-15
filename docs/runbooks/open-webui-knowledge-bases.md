# Runbook: subject knowledge bases in Open WebUI (RAG)

Gives Open WebUI a body of reference material (standards corpus, product
manual, rules system, internal documentation) and grounds answers in it with
citations to the source.

## How it works

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

An embedding turns text into a vector whose direction encodes meaning: a
question retrieves passages that mean the same thing in different words.
BM25 is keyword matching: it finds rare exact terms such as domain jargon,
identifiers, and defined terms. Hybrid search runs both and merges the
results, which is what makes retrieval work against a technical corpus;
embeddings alone are weak precisely where a subject corpus is most specific.

## Platform configuration

| Setting                        | Value                   | Note                                                                                    |
| ------------------------------ | ------------------------ | ---------------------------------------------------------------------------------------- |
| `RAG_EMBEDDING_ENGINE`         | `openai`                | Embeddings run outside the pod, via LiteLLM                                              |
| `RAG_EMBEDDING_MODEL`          | `b580:nomic-embed-text` | Served by Ollama on the GPU node                                                          |
| `ENABLE_RAG_HYBRID_SEARCH`     | `true`                  | BM25 + vector, merged                                                                     |
| `RAG_HYBRID_BM25_WEIGHT`       | `0.6`                   | Tilted toward exact-term matching                                                         |
| `RAG_TOP_K`                    | `5`                     | Chunks injected into the prompt                                                           |
| `CHUNK_SIZE` / `CHUNK_OVERLAP` | `1500` / `200`          | Keeps a table with the heading that gives it meaning                                      |
| Extraction engine               | unset (built-in)       | No sidecar; see [Preparing a corpus](#1-prepare-the-corpus)                               |
| Reranker                        | none                    | Chunks are ordered by cosine similarity against the same embeddings. No local model needed, consistent with the slim image |
| Vector store                    | `pgvector` (CNPG `open-webui-postgres`) | See [Operational notes](#operational-notes)                          |

These settings are instance-wide, not per knowledge base. Changing chunking
or the embedding model invalidates every already-ingested vector (see
[Re-ingest triggers](#re-ingest-triggers)).

## 1. Prepare the corpus

Extraction quality bounds everything downstream. Retrieval and the answering
model cannot recover information that extraction destroyed.

Prefer Markdown or plain text: the built-in loader reads it directly, and
headings become chunk boundaries, so each chunk carries the context of the
section it came from.

**For PDFs:**

1. Confirm a text layer exists: `pdftotext file.pdf - | head`. Empty output
   means a scan; OCR it first with `ocrmypdf in.pdf out.pdf`, which adds a
   text layer without altering the page images.
2. Convert to Markdown offline, on a workstation. See the converters below.
3. Read the output before uploading. Two failure modes are silent:
   multi-column pages interleaving into spliced sentences, and tables
   collapsing into unreadable runs of numbers. Re-run with a different tool
   on whatever came out mangled.

Conversion happens outside the cluster: it is a one-time job per document,
keeps no long-lived extraction pod on the node, and keeps the output
inspectable, which extraction buried inside an ingest pipeline does not.

### Converters

Ordered cheapest first. Escalate only when the previous tier's output fails
the inspection in step 3.

Listed tools are open source without usage-gated tiers. Several popular
converters are free only below a revenue, page, or seat threshold, or ship
non-commercial model weights; check licence before adding a row here.

| Tool | Licence | Approach | Best at | Weight | Watch out for |
|---|---|---|---|---|---|
| `pdftotext -layout` (poppler) | GPL-2.0 | pure text extraction | checking whether a text layer exists; simple single-column documents | instant | no Markdown structure; tables become whitespace art |
| `pymupdf4llm` | AGPL-3.0 | PyMuPDF, heuristic | clean single-column PDFs, fast bulk conversion | instant, no models | weak on complex tables and multi-column |
| **`docling`** (IBM) | MIT | ML layout + TableFormer | the workhorse: multi-column text, tables, also DOCX/PPTX/HTML | moderate, CPU-viable | slower per page than the above |
| `PP-StructureV3` (PaddleOCR) | Apache-2.0 | ML layout + table recognition + OCR | table-dense documents; scans, without a separate OCR pass | moderate to heavy | heavier dependency stack to install |
| `MinerU` | AGPL-3.0 | ML layout, formulas, tables | documents the above still mangle; dense technical layouts | heavy, GPU recommended | CLI renamed across releases (`magic-pdf` → `mineru`) |

Notes:

- `docling`, `MinerU`, and PaddleOCR are also available as in-cluster Open
  WebUI extraction engines. Running them as CLI tools does the same work
  without a permanent pod.
- None of these require a GPU. A one-off conversion taking minutes on CPU is
  acceptable for a job run once per document.
- Output is Markdown plus an images directory. Images are not embedded or
  retrievable; only text is indexed, so diagrams are not represented.
  Transcribe or caption any diagram whose content is needed.

Verify the result before uploading:

```sh
grep -c '^#' out.md                 # headings survived → chunk boundaries exist
grep -n '^|' out.md | head          # tables are real Markdown tables
sed -n '400,420p' out.md            # spot-check a page you know
```

Filenames are citations: encode title and edition, e.g. `ISO-27001-2022.md`,
not `standard.md`.

Index the current corrected edition. Retrieval has no notion of precedence
between an original and its errata and will return a superseded passage with
full confidence. Apply corrections to the text before ingesting.

## 2. Create the knowledge base

In the UI: Workspace → Knowledge → Create, then upload the prepared files.
(Menu labels vary across Open WebUI releases.)

One collection per subject. Hybrid retrieval builds its BM25 index from the
whole collection on every query, so unrelated material in one collection
increases both memory use and irrelevant matches.

Open the document view after upload and confirm the stored text matches the
source. This is the last point at which a bad conversion is cheap to fix.

## 3. Verify retrieval before trusting it

Reference the collection in a chat with `#` and ask questions with known
answers; ten is enough to expose failure modes. This tests retrieval, not
the model: if the right passage never appears in the citations, no prompt
change fixes it.

| Symptom                                       | Knob                                              |
| --------------------------------------------- | ------------------------------------------------- |
| Right topic, wrong section                    | Raise `RAG_TOP_K`; consider a reranker            |
| Exact term ignored in favour of vague matches | Raise `RAG_HYBRID_BM25_WEIGHT` toward `0.7`–`0.8` |
| Tables or definitions arrive truncated        | Raise `CHUNK_SIZE`; re-ingest                     |
| Irrelevant collections bleeding in            | Split into narrower collections                   |

## 4. Create a Model for the subject

Workspace → Models: pick a base model, attach the collection, and give it a
system prompt. This produces one entry in the model picker, SSO-fronted and
usable from a phone.

System prompt for reference corpora:

```
You answer questions about <subject> using only the provided context.

- Cite the source document and page or section for every claim.
- Quote the decisive sentence when the wording matters.
- If the context does not contain the answer, say so. Do not infer from
  general knowledge and do not fill gaps.
- If the context is ambiguous or two passages conflict, say that explicitly
  and cite both.
```

The instruction to refuse rather than infer is the operative one. A model's
default behaviour is to produce a plausible answer, and a plausible wrong
answer about a reference corpus is worse than no answer.

**Choosing the answering model.** Retrieval hands over passages; reconciling
them is reasoning work, and small local models blend sources without
flagging conflicts. Prefer a cloud alias for answering when the corpus has
no confidentiality constraint; the embedding side stays local regardless.
Keep everything local for sensitive material and accept a lower reasoning
ceiling.

## 5. Keep an eval set

`CHUNK_SIZE`, `RAG_TOP_K`, `RAG_HYBRID_BM25_WEIGHT`, the embedding model, and
the converter used all change retrieval quality without any visible signal.
A tuning change can improve one class of question and break another while
looking like an improvement.

Keep about 20 questions per corpus with known answers, recording the
expected source and page. Include an exact-term lookup, one whose answer
lives in a table, one spanning two documents, and one the corpus genuinely
does not answer, the last checks that the model declines instead of
inventing.

Re-run after any configuration or corpus change and record the pass count.
Tracked in #918.

## Re-ingest triggers

Re-uploading is required after:

- **changing `RAG_EMBEDDING_MODEL`**: vectors are only comparable within one
  model. Mismatched retrieval fails silently, returning unrelated passages
  rather than an error.
- **changing `CHUNK_SIZE` / `CHUNK_OVERLAP`**: existing chunks keep their old
  boundaries.
- replacing or correcting a source document.

## Operational notes

- Uploaded files and their chunk metadata live in the Open WebUI PVC
  (sqlite), not in this repo.
- A pod restart while a file is mid-processing leaves it stuck in `pending`
  or `processing`, with no automatic retry. The knowledge-base UI blocks
  deleting a file in that state. `DELETE /api/v1/knowledge/{id}/delete`
  removes the entire collection via the API regardless of individual file
  status.
- Vector store is `pgvector` against the CNPG cluster `open-webui-postgres`.
  The `vector` extension is installed via `postInitApplicationSQL` at
  cluster bootstrap, since `enableSuperuserAccess: false` blocks
  `CREATE EXTENSION` at runtime. No backup is configured for
  `open-webui-postgres`; state is recreated by re-ingesting.
- Embeddings run on the always-on tier-1 backend (the B580) and carry no
  LiteLLM fallback. They sit on the hot path of every query; a fallback to a
  different model would return meaningless retrieval rather than degraded
  retrieval. See the Embeddings row in
  `docs/adr/0003-opportunistic-xtx-inference-tier.md`.
- In-cluster extraction engines available if needed: `tika`, `docling`,
  `mineru`, `paddleocr_vl`. `tika` reserves about 1.5Gi by default for a job
  that runs once per document; the other three are ML pipelines that cost
  more memory, not less. Remaining engines are third-party cloud APIs,
  metered per page and off-site.
- The LiteLLM virtual key used by Open WebUI must permit the embedding
  model. If the key is model-scoped and the embedding model is missing,
  chat keeps working while retrieval silently returns nothing.

## What this is good for, and what it isn't

Good as a **finder**: surfaces the relevant passage with a citation in
seconds.

Poor as an **arbiter**: questions that require combining several sources and
a precedence judgement between them are exactly where it answers most
confidently and incorrectly. Mandatory citations make every answer
verifiable in one click.

For a question scoped to a single chapter or section, pasting that section
into a long-context model directly outperforms retrieval. Retrieval earns
its keep when the location of the answer is unknown.

## Alternatives

Current approach: built-in Open WebUI RAG, chosen for access surface (one
entry in the model picker, SSO, usable from a phone, citations one click
away) over retrieval quality.

| Approach | Wins on | Loses on | Issue |
|---|---|---|---|
| Built-in Open WebUI RAG (this doc) | zero new infra, best access surface | global-only tuning, corpus is PVC state, click-ops setup | n/a |
| Own ingest pipeline + vector store | per-corpus settings, metadata filters, reproducible ingest | a component to maintain, with its own auth and backups | #919 |
| Full-text search only, no embeddings | legible failures, no re-embed cycle, cheap to operate | weaker on vaguely worded questions | #920 |
| Long context, no retrieval | cannot fail to retrieve; simplest of all | context window and per-call cost | #921 |
| Agentic search over Markdown | best precision, multi-step beats one-shot | desk-only; unusable from a phone mid-session | #921 |

Tracked regardless of which alternative is adopted:

1. **Move the corpus into version control** (#917). Converted Markdown in a
   dedicated repo, not this one, gives reviewable diffs when a converter
   version changes the output and makes the upload a publish step rather
   than the only copy.
2. **Keep an eval set** (#918, and step 5 above). The only way to know
   whether an alternative is actually better than what it replaces.

Graduation triggers:

- A second corpus wanting different chunking → #919. `CHUNK_SIZE` and the
  `RAG_*` settings are per-instance, not per-collection.
- Retrieval keeps missing and vector distance offers no explanation → #920.
- Questions are usually already scoped to a known section → #921 path A;
  skip retrieval for those rather than tuning it.

Umbrella issue: #922.

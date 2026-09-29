# Backlog

## Open
- **Access crossover: GPT-OSS 120B and Nemotron for every division, Terra also for Sales.** IT keeps all six models (already true). GPT-OSS: add Sales, Marketing. Nemotron: add Sales, Local Branches, Credit/Loans, Risk, Marketing. Terra: add Sales (IT already has it).
  Scope is the whole matrix, not just the SVG: `materials/access-matrix.svg`, `materials/architecture.svg`, README matrix table, `content/modules/ROOT/pages/corporate-scenario.adoc` (`[[the_access_matrix]]` is the source of truth per the SVG header comment), `manifests/auth-policies.yaml`, `manifests/subscriptions.yaml`, and the allow-lists/cap checks in `run-demo.sh` / `verify-fa-cap.sh`.
  New hourly caps required for every newly allowed model (standard caps today: GPT-OSS 2M/h, Nemotron 1M/h). Sales' Terra cap is an open decision — 100K/h keeps the "IT ≈ 5x standard" cloud pattern (claude 250K→1.25M, gemini 50K→250K).
  `verify-fa-cap.sh` expectations change: 42 access tests go 15 allow / 27 deny → 23 allow / 19 deny; subscription-cap checks go 15 → 23.
- **Rename "Nemotron Lightning 30B" → "Nemotron 30B", full stop.** Display-name occurrences: `maas-models.yaml` annotation, README tables, `access-matrix.svg`, `architecture.svg`, adoc page.
  Open scope call: leave the resource ID `nemotron-lightning` and served name `nemotron/3.5-lightning` as internal plumbing, or rename them too (touches `models-onprem.yaml`, URL paths, `run-demo.sh`, `verify-fa-cap.sh`, README sample output).
- **Gemini 3 Pro: drop the image characterization.** Remove "(image)" from `access-matrix.svg` and `architecture.svg`; align README role ("Image generation / multimodal"), talk track ("the image model"), `maas-models.yaml` description, and `subscriptions.yaml` marketing description.

- **Access-matrix caps never say what's capped.** 15 cells read "2M/h", "250K/h"… with no unit on screen — viewer can't tell tokens from money. Add one word to the subtitle (`materials/access-matrix.svg` :23): "Per-model hourly **token** caps by division — everything else is hidden from the catalog." Cells stay as-is.
  Same sweep, same file: legend "IT ≈ 5× standard caps" (:150) — "standard" baseline is undefined on screen and "≈" is a slow read → "IT — about 5× the other caps" (fits the ~360px legend slot at 19px font; the "runs the platform" why stays in the talk track).
- **Rename "MODEL ESTATES" → "WHERE MODELS RUN"** (`materials/architecture.svg` :101). "Estate" is insider IT phrasing labeling half the frame; nothing on screen decodes it. The talk track's spoken "two estates" (adoc :115) self-explains right after, so no talk-track change required.
  Same sweep: card title "Cloud / SaaS" (:118) → "Cloud" — "/ SaaS" adds nothing over the "external SaaS · pay-per-use" sub-line directly below (:119) and breaks the one-word "On-prem" parallelism.
- **Round org-chart decimal percentages.** `materials/org-chart.svg`: 37.5/12.5/6.25/3.75% on cards (:52, :72, :82, :102) + legend tspans (:131, :135, :139, :143) → 38/25/13/6/5/4/10 (legend then sums 101%, normal for rounded legends). Round only the displayed `.pct` text and legend tspans — leave the pie arc path coordinates at exact proportions so slices still match the numbers. Alternative: drop pcts entirely (pie + headcounts carry the share).
- **cio-email: "an API" dangles at line end.** `materials/cio-email.svg` :55-56 ("…one login, an API / key that works…") — during the ~3s B-roll flash the line ends on a bare acronym. Rewrap only, end :55 at "one login,"; render-check width since :56 grows ~5 chars. Wording itself is the approved phrasing — keep verbatim.
- **Audited clean / leave alone (2026-09-29 five-SVG sweep):** `cut-card.svg` has a single string ("55 minutes later..."), plain English. "Mail — Inbox" em-dash (`cio-email.svg` :32) is a typographic nit, zero WTH risk — leave. No HTTP codes, OIDC/JWT/k8s jargon, repo paths, or namespace names in any of the five SVGs; model names are display names only.

## Done

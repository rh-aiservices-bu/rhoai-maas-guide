# AGENTS.md

Instructions for AI agents (Claude Code, Codex, Cursor, OpenCode, Roo Code) working in this repo. Read this before you write or change a guide page, a manifest or a script, so your work looks like the rest of the guide.

## What this repo is

A companion guide to deploy RHOAI Models-as-a-Service (MaaS) on OpenShift, with opinionated Kustomize manifests and automation scripts. It is *not* the official documentation, and pages say so.

The guide is an Antora site. `.github/workflows/gh-pages.yml` publishes it from `main` to GitHub Pages. Anything merged to `main` is visible to customers.

## Layout

| Path | What lives there |
|------|------------------|
| `content/antora.yml` | Component config and AsciiDoc attributes (`{rhoai}`, `{maas}`, `{repo-url}`, ...) |
| `content/modules/ROOT/nav.adoc` | Left navigation, grouped by `.Section` titles |
| `content/modules/ROOT/pages/` | One `.adoc` per page. Phase pages are numbered (`03-maas-platform.adoc`) |
| `content/modules/ROOT/assets/images/`, `images/` | SVG diagrams and screenshots |
| `manifests/NN-name/` | Manifests per phase, numbered like the page. Extras use `99-*` (`99-cors`, `99-model-swap`) |
| `scripts/` | `setup-maas.sh` (orchestrator), `deploy-model.sh`, `verify-maas.sh` (wrapper for `manifests/06-verification/verify.sh`), `test-inference.sh`, `cleanup-maas.sh` |
| `demo/` | Self-contained demo scenarios with their own READMEs |
| `supplemental-ui/` | Theme overrides (header, footer, favicon) |
| `.claude/skills/` | `/install-maas` and `/verify-guide` skills |

## Build locally

Same commands as CI:

```bash
npm install --global @antora/cli@3.1 @antora/site-generator@3.1 @andrew-jones/antora-tabs-extension @antora/lunr-extension
antora generate site.yml --stacktrace
```

Output goes to `www/` (gitignored). Build after every page change and fix broken xrefs before you open a PR.

## Voice

Write like an engineer who tested it on a real cluster.

- Plain, direct English. Short sentences. Talk to the reader as "you", in present tense.
- Be exact. Name the version, CSV, channel, namespace and resource: `rhcl-operator.v1.5.0` from `stable-1.5`, not "the latest RHCL".
- Give numbers, not adjectives: "*15 of 15* checks passed", "idles at 145-271m", "brought it back to `minReplicas: 2` in ten seconds".
- Explain the why in one or two sentences, then show the command.
- Say what was *not* tested.
- No marketing words, no filler ("simply", "seamlessly", "powerful", "robust", "leverage"), no emojis.
- No em-dashes. Use a spaced hyphen ` - ` or split the sentence.
- Bold with `*word*` only for the one word that matters in a sentence: "there is *one* CSV".

## AsciiDoc conventions

Product names come from attributes in `content/antora.yml`. Use them instead of typing the full name:

```asciidoc
{rhoai} / {rhoai-short}   -> Red Hat OpenShift AI / RHOAI
{ocp} / {ocp-short}       -> OpenShift Container Platform / OpenShift
{maas}                    -> Models as a Service
{repo-url}                -> https://github.com/rh-aiservices-bu/rhoai-maas-guide
```

Links:

```asciidoc
xref:03-maas-platform.adoc[Phase 3]
link:https://access.redhat.com/articles/7092611[RHCL supported configurations article^]
link:https://redhat.atlassian.net/browse/RHOAIENG-103136[RHOAIENG-103136^]
link:{repo-url}/pull/205[#205]
```

For new content, end external links with `^` so they open in a new tab (older pages are not consistent). PR links do not use it.

Commands go in `[source,bash]`. Put the expected output in a separate bare `[source]` block right after it:

```asciidoc
[source,bash]
----
oc get csv -n openshift-operators -l '!olm.copiedFrom'
----

[source]
----
NAME                   PHASE
rhcl-operator.v1.5.0   Succeeded
----
```

- All paths and `oc apply` commands are relative to the repo root. Prefer `oc apply -k manifests/<dir>/`.
- Use `oc wait --for=condition=... --timeout=...` as the status gate after each step.
- Use `oc apply -f - <<'EOF'` heredocs for one-off YAML that is not in `manifests/`.

Admonitions: use the one-line form (`NOTE:`, `TIP:`, `IMPORTANT:`, `WARNING:`) for text. Use the block form when the note contains code:

```asciidoc
[NOTE]
====
Text first.

[source,bash]
----
oc ...
----
====
```

Version differences go in tabs, newest first:

```asciidoc
[tabs]
====
RHOAI 3.5+::
+
--
...
--
RHOAI 3.4::
+
--
...
--
====
```

Tables:

```asciidoc
[cols="1,2", options="header"]
|===
| Property | Value

| {ocp-short}
| 4.21.36, single node
|===
```

Headings are mixed today (`== Manual setup` in phase pages, `== Why This Page Exists` in field notes pages). Match the heading case of the page you are editing.

## Page patterns

**Phase page** (see `03-maas-platform.adoc`):

```asciidoc
= Phase N: Title

One sentence on what this phase deploys.

TIP: All file paths and `oc apply` commands in this guide are relative to ...
IMPORTANT: This guide is not a replacement for the official ...

== Prerequisites
== Overview
TIP: ... To run only this phase automatically: `./scripts/setup-maas.sh --from-phase N`
== Manual setup
=== Step 1: ...
== Verify
== What this creates      (table: Resource | Namespace | Purpose)
== Troubleshooting
== References
== Next step
```

**Field notes / validation page** (see `13-openshift5.adoc`, `14-rhcl-15.adoc`):

```asciidoc
= Running MaaS with X

One paragraph: what was installed, on what, and how it differs from the rest of the guide.

IMPORTANT: support statement caveat, with links to the supported configurations articles.

== Why This Page Exists  (optional)
== Test Cluster          (table: Property | Value)
== Outcome               (bullets with hard numbers, plus what was not exercised)
== Issue N: <the symptom, in words>
Tracked as link:...[RHOAIENG-NNNNN^].   (when there is a Jira)
=== Symptoms
=== Diagnosis
=== Workaround
```

**Troubleshooting entries** anywhere in the guide use the same `Symptoms` / `Diagnosis` / `Workaround` structure. Show the exact error string the reader will see, so they can search for it.

## When you add or change a page

- Add new pages to `nav.adoc` under the right `.Section`.
- Add an entry to `changelog.adoc` under the current month, in `=== New Pages`, `=== Features` or `=== Fixes`:

  ```asciidoc
  * *Short Title* - What changed and why it matters, in a few sentences. (link:{repo-url}/pull/NNN[#NNN])
  ```

- Update the tables in `README.md` if you add a phase, a reference page, a script or a model.
- If you change what a script or manifest does, update the page that documents it in the same PR, and the other way around.
- Pre-GA content (Early Access builds, unreleased RHOAI or RHCL versions) never goes to `main`. Keep the page, its nav entry and its changelog entry on a side branch until GA. A warning admonition is not enough.

## Manifests and scripts

- One directory per phase under `manifests/`. The `kustomization.yaml` is in the directory or in its subdirectories (`01-prerequisites/operators/`). If you add a `README.md`, keep it short and link to the published page.
- Version-specific variants get a suffix next to the default file: `datasciencecluster.yaml` (3.5) and `datasciencecluster-34.yaml` (3.4).
- Cluster-specific values (hostname, cert name) go in a `*.yaml.tmpl` file rendered with `envsubst`, for example `envsubst '${MAAS_HOSTNAME} ${CERT_NAME}' < manifests/02-platform-config/gateway.yaml.tmpl | oc apply -f -`.
- Never commit secrets, API keys or tokens. Pages create secrets with `oc create secret ...`. If a YAML file needs a credential, use a `REPLACE_ME` placeholder. Grep for secrets before staging.
- Scripts start with `#!/usr/bin/env bash` and a header comment that says what the script does.
- Phases must be idempotent: re-running skips what is already done. Scripts that change the cluster support `--dry-run`.
- A new flag goes into the `usage()` block of the script, `quick-start.adoc` and `README.md`.
- To validate on a live cluster, run `scripts/verify-maas.sh` (15 checks) or the `/install-maas` and `/verify-guide` skills.

## Git and pull requests

- Never commit or push unless the user asks. No AI attribution anywhere: no `Co-Authored-By`, no "Generated with" footer.
- Branch names: `docs/<topic>`, `fix/<topic>`, `feat/<topic>`.
- Commit messages: one line, 5 words max, lowercase, casual. No `feat:` / `fix:` / `docs:` prefixes. Example: `fix gateway readme and troubleshooting`.
- PR description: a few plain sentences on what and why, then a short test plan. No long templated sections.
- PRs are squash merged, so the title becomes the commit on `main`. Keep it in the same short style.

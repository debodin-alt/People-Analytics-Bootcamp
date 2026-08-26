# The Wizard function

The conversational analyst behind `/wizard`. Runs as a Supabase Edge
Function because the LLM key must not be in the browser bundle, and
because this is where the caller's JWT can be used to reach the measures.

## Setup

Set one API key and deploy. The provider is chosen from whichever key is
present, so there is nothing else to configure.

```sh
REF=<project-ref>

# Gemini — key from aistudio.google.com. Has a free tier.
supabase secrets set GEMINI_API_KEY=... --project-ref $REF

# …or Claude — key from console.anthropic.com. Note that a Claude
# Max/Pro subscription does NOT include API access; it is billed
# separately.
supabase secrets set ANTHROPIC_API_KEY=sk-ant-... --project-ref $REF

supabase functions deploy wizard --project-ref $REF
```

`SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected by the edge runtime;
they do not need to be set.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | — | Required for the Gemini provider. |
| `ANTHROPIC_API_KEY` | — | Required for the Claude provider. |
| `WIZARD_PROVIDER` | whichever key is set, else `claude` | `gemini`, `claude`, or `azure-openai`. Set it explicitly only if both keys are present. |
| `WIZARD_MODEL` | `gemini-3.7-flash` / `claude-opus-5` | Model id. Provider-specific — clear it when switching providers. Currently set to `gemini-3.6-flash`: as of 2026-08-25 `gemini-3.7-flash` returns 503 "high demand" after ~100s. Worth retrying periodically. |
| `WIZARD_EFFORT` | `medium` | Claude only. `low`…`max`. The first knob to reach for if answers look shallow, ahead of any prompt change. |

Both providers run **stateless**: history is passed explicitly on every
request and neither vendor is asked to retain the transcript (Gemini gets
`store: false`; the Claude provider never chains conversation ids). For a
tool that will eventually see real HR questions, not leaving a transcript
of them on a third party's servers is worth the extra tokens.

## Why it is safe to point at real data

The function holds **no privileged credential**. It reads no service-role
key, and its Supabase client is built from the caller's own
`Authorization` header. Every measure call therefore runs as the signed-in
user, which means:

- capability gates apply (a viewer asking about pay gets `unavailable`,
  not a number),
- row scope applies (a manager sees their own tree),
- minimum cell size applies (cuts under five people come back
  `suppressed`).

None of this is re-implemented here. There is no second permission model
to keep in sync, because there is no second path to the data — the Wizard
can only ask the same questions the dashboard asks, as the same person.

Citations shown in the UI are rebuilt server-side from the measures that
actually ran, not from the model's own account of what it used. A model
that fabricated a number would fabricate a citation for it just as
readily; the point of a citation is that it is checkable.

## Verified behaviour

Exercised end-to-end against the live project under real signed-in sessions:

- **admin** — "active headcount" → 820 as of 2026-04-22, matching the PRD
  reference value the suite asserts. "Highest voluntary attrition by
  function" → Design 23.3% (5 exits over 21.5 average headcount),
  Engineering highest by volume at 20. Every figure exact against the
  measures; no fabrication.
- **viewer** — compensation questions refused as an access matter; company
  aggregates still answered; dimensional breakdowns refused.
- **unauthenticated** — 401 at the gateway, and 401 from the function for
  the anon key (which is itself a valid JWT and so passes the gateway).

Citations are filtered to measures that actually returned data: a run where
five measures were called and four were refused cites only the one that
answered.

## What this does not defend against

**Differencing attacks.** Suppression hides a cell; it does not stop
someone narrowing successive queries until only one person remains in the
difference between two allowed results. The Wizard makes this easier than
the dashboard does, because asking is cheaper than clicking. The system
prompt tells the model not to assist with it, which is a deterrent and not
a control. A real control is query-log auditing plus a per-session budget
on how finely one user may cut the same population — neither is built.
This is noted on the Methodology page as a known limitation.

**Prompt injection via data.** Measure results are aggregates and band
labels, so there is currently no free text from the database reaching the
model. That changes the day engagement verbatims become queryable
(`engagement_open_ended` holds employee-written text). If a measure ever
returns free text, it must be fenced and marked untrusted before it goes
into a tool result.

## The tool schema dialect

`ToolSpec.inputSchema` is plain JSON Schema restricted to the intersection
the providers all accept: `type`, `properties`, `items`, `enum`,
`description`, `required`. `additionalProperties` is deliberately absent —
Gemini validates function parameters against a subset of OpenAPI that does
not reliably support it, and rejects free-form objects outright.

The `options` properties are **derived from the catalog signatures at
request time**, not hand-listed: `metric_catalog()` reports each measure's
Postgres argument list, which is parsed for name and type. Today that
yields `p_dimension` (as an enum of the eight conformed dimensions),
`p_months`, `p_status` and `p_competency_type`. A measure that gains a
parameter gains it in the tool schema with no edit here.

## Moving to Microsoft Copilot / Azure OpenAI

`providers.ts` is the seam. `AzureOpenAiProvider` is a documented stub —
it throws rather than silently falling back, so nobody points this at a
company's HR data believing it is running on the sanctioned stack.

What a swap touches: authentication, the tool-schema translation, and the
tool-loop shape. What it does not touch: the tool layer, the generated
system prompt, the capability gates, the suppression rules, and the entire
UI. That asymmetry is the reason the provider is behind an interface.

Worth weighing before writing that provider: the alternative integration
is to expose this same tool layer as an OpenAPI-described API plugin and
let M365 Copilot call *in*. Users then ask in Teams rather than learning a
second chat box, and the governed semantic layer stays exactly where it
is. The tool layer is the asset either way; the chat UI is not.

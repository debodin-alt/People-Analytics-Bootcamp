/**
 * The LLM provider seam.
 *
 * The Wizard's valuable asset is not the model — it is the governed tool
 * layer underneath (metrics.* measures that already enforce capability
 * gates, row scope and cell-size suppression). The model is the
 * replaceable part, so it sits behind an interface narrow enough that
 * swapping it touches nothing else.
 *
 * Gemini and Claude are both implemented and interchangeable. Production
 * is expected to be Microsoft Copilot / Azure OpenAI, because that is the
 * stack the business already governs; `AzureOpenAiProvider` below is a
 * deliberate stub rather than a guess, documenting the shape of the work
 * without pretending to be tested code.
 *
 * The interface takes the whole tool loop, not a single completion. The
 * three providers disagree on nearly everything about tool use — Claude
 * returns `tool_use` content blocks and takes results back as a user
 * message, Gemini returns `function_call` steps and takes
 * `function_result` items, Azure OpenAI returns `tool_calls` with
 * stringified arguments and wants one `role: "tool"` message per result.
 * Every one of those disagreements stays inside its own provider rather
 * than leaking into a shared loop full of branches.
 *
 * What all three *do* share is the tool schema, which is why ToolSpec
 * holds plain JSON Schema restricted to the dialect they all accept (see
 * semanticModel.ts) rather than anything vendor-shaped.
 */

import Anthropic from 'npm:@anthropic-ai/sdk@0.120.0';

/** Ceiling on a single model round trip. */
const REQUEST_TIMEOUT_MS = 60_000;

/** Ceiling on the whole tool loop, across every round trip. */
const DEFAULT_DEADLINE_MS = 150_000;

/**
 * The answer given when the loop runs out of wall clock.
 *
 * Deliberately shaped like a refusal rather than an error: the user asked
 * something reasonable and the system could not finish in time, which is a
 * fact about the system, not a fault in the question. Naming the measures
 * that did complete gives them something to narrow towards.
 */
function outOfTime(
  toolCalls: ToolCallRecord[],
  inputTokens: number,
  outputTokens: number,
  servedBy: string,
  iterationMs?: number[],
): LlmRunResult {
  const ran = [...new Set(toolCalls.filter((c) => c.ok).map((c) => c.name))];
  return {
    text: JSON.stringify({
      answer: '',
      citedMeasures: [],
      citedTables: [],
      refused: {
        reason:
          'That took longer than I can wait for. Try asking about one thing at a time — ' +
          'a narrower question usually needs a single measure and returns quickly.' +
          (ran.length ? ` I did get as far as running: ${ran.join(', ')}.` : ''),
      },
    }),
    toolCalls,
    stopReason: 'deadline_exceeded',
    usage: { inputTokens, outputTokens },
    servedBy,
    iterations: iterationMs?.length,
    iterationMs,
  };
}

/** A provider-neutral tool: JSON Schema in, JSON out. */
export interface ToolSpec {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export type ToolExecutor = (name: string, input: Record<string, unknown>) => Promise<unknown>;

/**
 * Conversation history is plain text on both sides — deliberately.
 *
 * Tool calls and their results live inside a single `run()` and are not
 * carried into the next turn. The model therefore sees its own prior
 * answers but not the raw rows behind them, and re-queries when a
 * follow-up needs the numbers again. That costs a round trip on some
 * follow-ups and buys a history format with nothing provider-specific in
 * it, which is the whole point of this file.
 */
export interface ChatTurn {
  role: 'user' | 'assistant';
  content: string;
}

export interface ToolCallRecord {
  name: string;
  input: Record<string, unknown>;
  ok: boolean;
}

export interface LlmRunResult {
  /** Round trips to the model. The dominant latency term: each one resends
   *  the whole prompt, so 7 tool calls spread over 7 iterations costs
   *  roughly 7x what the same 7 calls batched into 2 iterations costs. */
  iterations?: number;
  /** Milliseconds per model round trip, for diagnosing where time went. */
  iterationMs?: number[];
  /** The model's final text. Expected to be JSON matching WizardResponse. */
  text: string;
  /** What the model actually called — the basis for citations, not the model's claims. */
  toolCalls: ToolCallRecord[];
  stopReason: string | null;
  usage: { inputTokens: number; outputTokens: number } | null;
  /** Which model served the response, after any server-side fallback. */
  servedBy: string;
}

export interface LlmRunRequest {
  /** Wall-clock ceiling for the whole tool loop. Without it, maxIterations
   *  slow-but-not-timing-out round trips stack: six iterations at the 60s
   *  per-request ceiling is a six-minute request. Reaching this returns a
   *  partial, honest answer rather than continuing to spend the user's wait. */
  deadlineMs?: number;
  system: string;
  messages: ChatTurn[];
  tools: ToolSpec[];
  execute: ToolExecutor;
  /** Hard ceiling on tool round trips. A wizard that cannot answer in this
   *  many steps should say so rather than loop on the caller's budget. */
  maxIterations: number;
}

export interface LlmProvider {
  readonly id: string;
  run(req: LlmRunRequest): Promise<LlmRunResult>;
}

// ---------------------------------------------------------------------------
// Claude — the demo provider
// ---------------------------------------------------------------------------

/**
 * The parts of a Claude response this code reads. Declared locally rather
 * than imported so that an SDK version bump cannot break the build over
 * types nothing here depends on. Anything absent is treated as absent.
 */
interface ClaudeContentBlock {
  type: string;
  text?: string;
  id?: string;
  name?: string;
  input?: unknown;
}

interface ClaudeResponse {
  content: ClaudeContentBlock[];
  stop_reason?: string | null;
  model?: string;
  usage?: { input_tokens?: number; output_tokens?: number };
}

export class ClaudeProvider implements LlmProvider {
  readonly id = 'claude';

  #client: Anthropic;
  #model: string;
  #effort: string;

  constructor(opts: { apiKey: string; model?: string; effort?: string }) {
    this.#client = new Anthropic({
      apiKey: opts.apiKey,
      // The SDK's default timeout is ten minutes, which in an interactive
      // chat is indistinguishable from a hang. Match the Gemini provider's
      // ceiling. maxRetries is the SDK's own backoff over 408/409/429/5xx
      // and connection errors — the same protection hand-rolled around
      // fetch() on the Gemini side, already built here.
      timeout: REQUEST_TIMEOUT_MS,
      maxRetries: 2,
    });
    this.#model = opts.model ?? 'claude-opus-5';
    // `high` is the API default. `medium` is set here because this is an
    // interactive chat where a several-second wait is felt, and on Opus 5
    // the lower effort levels hold up unusually well. Raise it via
    // WIZARD_EFFORT if answers start looking shallow — that is the knob to
    // reach for first, ahead of any prompt change.
    this.#effort = opts.effort ?? 'medium';
  }

  /**
   * The request body is assembled untyped and passed straight through.
   *
   * `fallbacks` and `output_config.effort` are newer than most published
   * SDK typings, and pinning this file to a particular version's parameter
   * type would make an SDK bump a compile error in a file that has no
   * reason to care. The SDK forwards unrecognised keys unchanged, so the
   * wire request is correct either way; what is lost is compile-time
   * checking of the body, which the local ClaudeResponse shape below
   * restores on the half that this code actually reads.
   */
  #send(body: Record<string, unknown>): Promise<ClaudeResponse> {
    const create = this.#client.beta.messages.create as unknown as (
      b: Record<string, unknown>,
    ) => Promise<ClaudeResponse>;
    return create.call(this.#client.beta.messages, body);
  }

  async run(req: LlmRunRequest): Promise<LlmRunResult> {
    const tools = req.tools.map((t) => ({
      name: t.name,
      description: t.description,
      input_schema: t.inputSchema,
    }));

    const messages: unknown[] = req.messages.map((m) => ({
      role: m.role,
      content: m.content,
    }));

    const toolCalls: ToolCallRecord[] = [];
    let stopReason: string | null = null;
    let servedBy = this.#model;
    let inputTokens = 0;
    let outputTokens = 0;

    const deadline = Date.now() + (req.deadlineMs ?? DEFAULT_DEADLINE_MS);

    for (let i = 0; i < req.maxIterations; i++) {
      if (Date.now() > deadline) {
        return outOfTime(toolCalls, inputTokens, outputTokens, servedBy);
      }
      const response = await this.#send({
        model: this.#model,
        max_tokens: 8000,
        system: req.system,
        messages,
        tools,
        output_config: { effort: this.#effort },
        // Safety classifiers can decline a request outright. Without a
        // fallback the turn simply stops; with one the API re-runs it on
        // another model inside the same call. HR analytics is unlikely to
        // trip them, but a demo failing in front of an audience for a
        // reason nobody can explain is worth a cheap insurance policy.
        betas: ['server-side-fallback-2026-07-01'],
        fallbacks: 'default',
      });

      inputTokens += response.usage?.input_tokens ?? 0;
      outputTokens += response.usage?.output_tokens ?? 0;
      stopReason = response.stop_reason ?? null;
      servedBy = response.model ?? servedBy;

      if (response.stop_reason === 'refusal') {
        return {
          text: JSON.stringify({
            answer: '',
            citedMeasures: [],
            citedTables: [],
            refused: { reason: 'The model declined to answer this question.' },
          }),
          toolCalls,
          stopReason,
          usage: { inputTokens, outputTokens },
          servedBy,
        };
      }

      const toolUses = response.content.filter((b) => b.type === 'tool_use');

      if (toolUses.length === 0) {
        const text = response.content
          .filter((b) => b.type === 'text')
          .map((b) => b.text ?? '')
          .join('');
        return { text, toolCalls, stopReason, usage: { inputTokens, outputTokens }, servedBy };
      }

      messages.push({ role: 'assistant', content: response.content });

      // Parallel calls are executed together and their results returned in
      // one user message. Splitting them across messages trains the model
      // out of calling tools in parallel at all.
      const results = await Promise.all(
        toolUses.map(async (use) => {
          const input = (use.input ?? {}) as Record<string, unknown>;
          const name = use.name ?? '';
          const id = use.id ?? '';
          try {
            const out = await req.execute(name, input);
            toolCalls.push({ name, input, ok: true });
            return {
              type: 'tool_result' as const,
              tool_use_id: id,
              content: JSON.stringify(out),
            };
          } catch (err) {
            toolCalls.push({ name, input, ok: false });
            return {
              type: 'tool_result' as const,
              tool_use_id: id,
              // The message goes back to the model, not the user. A bad
              // measure name or a missing argument is recoverable — the
              // model reads the error and retries with a valid call.
              content: err instanceof Error ? err.message : String(err),
              is_error: true,
            };
          }
        }),
      );

      messages.push({ role: 'user', content: results });
    }

    // Out of iterations. Say so rather than returning whatever half-formed
    // state the loop happened to end in.
    return {
      text: JSON.stringify({
        answer: '',
        citedMeasures: [],
        citedTables: [],
        refused: {
          reason:
            `I could not answer that within ${req.maxIterations} steps. Try asking about one measure at a time.`,
        },
      }),
      toolCalls,
      stopReason: 'max_iterations',
      usage: { inputTokens, outputTokens },
      servedBy,
    };
  }
}

// ---------------------------------------------------------------------------
// Gemini
// ---------------------------------------------------------------------------

/**
 * Gemini, over `generateContent`.
 *
 * Auth is the standard `x-goog-api-key` header. `AQ.…` keys — the format
 * AI Studio now issues, replacing legacy `AIza…` keys, which stop working
 * in September 2026 — work with it normally.
 *
 * A correction worth leaving in place, because the wrong version of this
 * comment cost an hour: an earlier revision sent the key as
 * `Authorization: Bearer`, on the theory that the SDK's `x-goog-api-key`
 * could not carry the newer key type. That was wrong. It was diagnosed
 * against a malformed key, where `x-goog-api-key` returned
 * ACCESS_TOKEN_TYPE_UNSUPPORTED and Bearer returned
 * API_KEY_SERVICE_BLOCKED; the differing error codes looked like evidence
 * that Bearer got further, when in fact both were failing and Bearer is
 * simply the wrong scheme for an API key (it is for OAuth tokens, and
 * Google's message on that path is misleading). Against a valid key,
 * `x-goog-api-key` and `?key=` both succeed and Bearer still 401s.
 *
 * Using fetch rather than @google/genai is now a preference, not a
 * necessity: the SDK targets the newer Interactions API, while
 * `generateContent` is the older, stable, thoroughly documented surface,
 * and one endpoint plus one header is a small thing to own. The SDK is a
 * perfectly good alternative — switching means replacing this class, not
 * touching anything else.
 */
interface GeminiPart {
  text?: string;
  functionCall?: { name?: string; args?: Record<string, unknown> };
}

interface GeminiResponse {
  candidates?: { content?: { parts?: GeminiPart[] }; finishReason?: string }[];
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number };
  error?: { message?: string; status?: string; details?: unknown };
}

export class GeminiProvider implements LlmProvider {
  readonly id = 'gemini';

  #apiKey: string;
  #model: string;

  constructor(opts: { apiKey: string; model?: string }) {
    this.#apiKey = opts.apiKey;
    this.#model = opts.model ?? 'gemini-3.7-flash';
  }

  async #generate(body: Record<string, unknown>): Promise<GeminiResponse> {
    const url =
      `https://generativelanguage.googleapis.com/v1beta/models/${this.#model}:generateContent`;

    // Retry transient capacity errors, and cap every attempt. Without the
    // cap a Google-side stall hangs the whole request: gemini-3.7-flash was
    // observed sitting for ~100s before returning 503, which presents to
    // the user as a frozen page rather than a failure.
    let res: Response | null = null;
    let text = '';
    for (let attempt = 0; attempt < 3; attempt++) {
      const abort = new AbortController();
      const timer = setTimeout(() => abort.abort(), REQUEST_TIMEOUT_MS);
      try {
        res = await fetch(url, {
          method: 'POST',
          headers: {
            'x-goog-api-key': this.#apiKey,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(body),
          signal: abort.signal,
        });
        text = await res.text();
      } catch (err) {
        if (abort.signal.aborted) {
          throw new Error(
            `Gemini did not respond within ${REQUEST_TIMEOUT_MS / 1000}s. ` +
              'The model may be under load — try again, or set WIZARD_MODEL to another model.',
          );
        }
        throw err;
      } finally {
        clearTimeout(timer);
      }

      // 429 rate limit, 503 capacity, 500 transient. Anything else is ours.
      if (res.status !== 429 && res.status !== 503 && res.status !== 500) break;
      if (attempt === 2) break;
      await new Promise((r) => setTimeout(r, 800 * Math.pow(3, attempt)));
    }
    if (!res) throw new Error('Gemini request failed with no response.');

    let parsed: GeminiResponse;
    try {
      parsed = JSON.parse(text) as GeminiResponse;
    } catch {
      throw new Error(`Gemini returned non-JSON (HTTP ${res.status}): ${text.slice(0, 300)}`);
    }

    if (!res.ok || parsed.error) {
      const reason =
        (parsed.error?.details as { reason?: string }[] | undefined)?.[0]?.reason ?? '';
      const hint =
        reason === 'API_KEY_SERVICE_BLOCKED'
          ? ' — the Generative Language API is blocked for this key. Enable it on the ' +
            "key's Google Cloud project, or clear the key's API restrictions."
          : reason === 'ACCESS_TOKEN_TYPE_UNSUPPORTED'
            ? ' — Google did not recognise the credential. Usually a malformed or ' +
              'truncated key rather than a wrong transmission method; check its length ' +
              'against what AI Studio shows.'
            : '';
      throw new Error(
        `Gemini ${res.status} ${reason}: ${parsed.error?.message ?? text.slice(0, 300)}${hint}`,
      );
    }

    return parsed;
  }

  async run(req: LlmRunRequest): Promise<LlmRunResult> {
    const tools = [
      {
        functionDeclarations: req.tools.map((t) => ({
          name: t.name,
          description: t.description,
          parameters: t.inputSchema,
        })),
      },
    ];

    const contents: Record<string, unknown>[] = req.messages.map((m) => ({
      role: m.role === 'user' ? 'user' : 'model',
      parts: [{ text: m.content }],
    }));

    const toolCalls: ToolCallRecord[] = [];
    const iterationMs: number[] = [];
    let inputTokens = 0;
    let outputTokens = 0;

    const deadline = Date.now() + (req.deadlineMs ?? DEFAULT_DEADLINE_MS);

    for (let i = 0; i < req.maxIterations; i++) {
      if (Date.now() > deadline) {
        return outOfTime(toolCalls, inputTokens, outputTokens, this.#model, iterationMs);
      }
      const started = Date.now();
      const response = await this.#generate({
        contents,
        tools,
        systemInstruction: { parts: [{ text: req.system }] },
      });

      iterationMs.push(Date.now() - started);
      inputTokens += response.usageMetadata?.promptTokenCount ?? 0;
      outputTokens += response.usageMetadata?.candidatesTokenCount ?? 0;

      const parts = response.candidates?.[0]?.content?.parts ?? [];
      const calls = parts.filter((p) => p.functionCall);

      if (calls.length === 0) {
        const text = parts.map((p) => p.text ?? '').join('');
        return {
          text,
          toolCalls,
          stopReason: response.candidates?.[0]?.finishReason ?? 'end_turn',
          usage: { inputTokens, outputTokens },
          servedBy: this.#model,
          iterations: iterationMs.length,
          iterationMs,
        };
      }

      // Echo the model's own turn back before the results, so the next
      // request sees the calls its answers belong to.
      contents.push({ role: 'model', parts: calls });

      const responses = await Promise.all(
        calls.map(async (p) => {
          const name = p.functionCall?.name ?? '';
          const args = p.functionCall?.args ?? {};
          try {
            const out = await req.execute(name, args);
            toolCalls.push({ name, input: args, ok: true });
            // functionResponse.response must be an object, not a scalar.
            return { functionResponse: { name, response: { result: out } } };
          } catch (err) {
            toolCalls.push({ name, input: args, ok: false });
            return {
              functionResponse: {
                name,
                response: { error: err instanceof Error ? err.message : String(err) },
              },
            };
          }
        }),
      );

      contents.push({ role: 'user', parts: responses });
    }

    return {
      text: JSON.stringify({
        answer: '',
        citedMeasures: [],
        citedTables: [],
        refused: {
          reason:
            `I could not answer that within ${req.maxIterations} steps. Try asking about one measure at a time.`,
        },
      }),
      toolCalls,
      stopReason: 'max_iterations',
      usage: { inputTokens, outputTokens },
      servedBy: this.#model,
      iterations: iterationMs.length,
      iterationMs,
    };
  }
}

// ---------------------------------------------------------------------------
// Azure OpenAI / Microsoft Copilot — the production target
// ---------------------------------------------------------------------------

/**
 * Not implemented. Present so the shape of the production swap is written
 * down while it is still cheap to change, and so that selecting it fails
 * loudly rather than silently falling back to Claude with a company's real
 * HR data.
 *
 * What implementing it involves, in rough order of effort:
 *
 *  1. Auth. Azure OpenAI takes an Entra ID token or an endpoint key, not
 *     an Anthropic key. In a company tenant this is managed identity, not
 *     a secret in an environment variable.
 *  2. Tool translation. `ToolSpec` maps onto OpenAI's
 *     `{type: 'function', function: {name, description, parameters}}` —
 *     the JSON Schema itself carries across unchanged, which is the reason
 *     ToolSpec holds raw JSON Schema instead of anything Anthropic-shaped.
 *  3. Loop translation. Tool calls arrive on `message.tool_calls` with
 *     stringified `arguments`, and results go back as `role: 'tool'`
 *     messages keyed by `tool_call_id` — one message per result, not one
 *     message carrying all of them.
 *  4. Structured output. `response_format: {type: 'json_schema'}` can
 *     enforce the WizardResponse shape directly, which is stricter than
 *     the prompt-level instruction Claude gets here.
 *
 * Note what is *not* on that list: the tool layer, the system prompt, the
 * capability gates, the suppression rules, and the UI. Those are the parts
 * that took the work, and none of them are provider-specific.
 *
 * A second integration path is worth weighing before writing any of this:
 * rather than this dashboard calling Copilot, expose the same tool layer
 * as an OpenAPI-described API plugin and let M365 Copilot call *in*. Users
 * then ask in Teams instead of learning a new chat box, and the governed
 * semantic layer stays exactly where it is.
 */
export class AzureOpenAiProvider implements LlmProvider {
  readonly id = 'azure-openai';

  // deno-lint-ignore require-await
  async run(_req: LlmRunRequest): Promise<LlmRunResult> {
    throw new Error(
      'The Azure OpenAI provider is not implemented. Set WIZARD_PROVIDER=claude, ' +
        'or implement AzureOpenAiProvider before pointing the Wizard at production data.',
    );
  }
}

// Providers that call out to a public third-party API rather than a
// company-governed endpoint. Real HR data must not reach these unless
// someone has deliberately accepted that — see WIZARD_DATA_MODE below.
const PUBLIC_API_PROVIDERS = new Set(['claude', 'gemini']);

export function selectProvider(env: {
  provider?: string;
  anthropicApiKey?: string;
  geminiApiKey?: string;
  model?: string;
  effort?: string;
  dataMode?: string;
}): LlmProvider {
  // Default to whichever key is actually present, so the deployment is
  // configured by setting one secret rather than two. An explicit
  // WIZARD_PROVIDER always wins.
  const id = env.provider ?? (env.geminiApiKey ? 'gemini' : 'claude');

  // Claude and Gemini are "the demo provider" (see AzureOpenAiProvider's
  // docstring) — real HR data flowing through them means it leaves the
  // region to a public API with no reviewed data-processing agreement for
  // this use. WIZARD_DATA_MODE defaults to 'demo' precisely so that
  // running against real data is a decision someone makes on purpose, not
  // a config default nobody looked at. Set WIZARD_DATA_MODE=production
  // only once that's actually been reviewed (or once azure-openai is
  // implemented and selected instead).
  const dataMode = env.dataMode ?? 'demo';
  if (dataMode === 'production' && PUBLIC_API_PROVIDERS.has(id)) {
    throw new Error(
      `WIZARD_DATA_MODE=production but WIZARD_PROVIDER resolves to '${id}', a public ` +
        "third-party API. Real HR data must not be queried through it without a reviewed " +
        "data-processing agreement. Either set WIZARD_PROVIDER=azure-openai (once " +
        "implemented), or leave WIZARD_DATA_MODE unset/'demo' if this is still synthetic data.",
    );
  }

  switch (id) {
    case 'claude':
      if (!env.anthropicApiKey) {
        throw new Error(
          'ANTHROPIC_API_KEY is not set. Add it with: ' +
            'supabase secrets set ANTHROPIC_API_KEY=sk-ant-...',
        );
      }
      return new ClaudeProvider({
        apiKey: env.anthropicApiKey,
        model: env.model,
        effort: env.effort,
      });

    case 'gemini': {
      if (!env.geminiApiKey) {
        throw new Error(
          'GEMINI_API_KEY is not set. Add it with: ' +
            'supabase secrets set GEMINI_API_KEY=...',
        );
      }
      // Two key formats are in circulation, and both are valid:
      //
      //   AIza…  legacy "standard" key. Being retired — the Gemini API
      //          started rejecting unrestricted ones in June 2026 and
      //          rejects them outright from September 2026.
      //   AQ.…   current "auth" key, bound to a Google Cloud service
      //          account. This is the only kind AI Studio now issues.
      //
      // The check is only for a whitespace-mangled or obviously wrong
      // paste. It deliberately does NOT enforce a prefix: an earlier
      // version of this asserted `AIza` and rejected the newer format
      // outright, which is a worse failure than the 401 it was meant to
      // explain — a validator built on a stale assumption turns a working
      // key into a confident error message.
      const key = env.geminiApiKey.trim();
      if (key.length < 20 || /\s/.test(key)) {
        throw new Error(
          `GEMINI_API_KEY does not look usable (${key.length} characters` +
            `${/\s/.test(key) ? ', contains whitespace' : ''}). Check for a truncated ` +
            `paste or surrounding quotes, then re-set it with: ` +
            `supabase secrets set GEMINI_API_KEY=...`,
        );
      }
      return new GeminiProvider({ apiKey: key, model: env.model });
    }

    case 'azure-openai':
      return new AzureOpenAiProvider();

    default:
      throw new Error(
        `Unknown WIZARD_PROVIDER: ${id}. Expected 'claude', 'gemini' or 'azure-openai'.`,
      );
  }
}

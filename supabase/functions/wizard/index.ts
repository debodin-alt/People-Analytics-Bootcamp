/**
 * The Wizard's server side.
 *
 * Two things make this an Edge Function rather than browser code:
 *
 *  1. An API key in a Vite bundle is a published API key. There is no
 *     configuration that makes it otherwise.
 *  2. It is where the caller's JWT can be used to reach the measures
 *     without ever holding a privileged credential. This function has no
 *     service-role key and no elevated path to the data. It builds a
 *     Supabase client from the *caller's* Authorization header, so every
 *     capability gate, row-scope rule and suppression threshold applies to
 *     the Wizard exactly as it applies to the dashboard pages.
 *
 * That second point is the security design. The Wizard cannot leak what a
 * user could not already read, because it holds nothing they do not.
 */

import { createClient } from 'npm:@supabase/supabase-js@2.112.3';
import { selectProvider, type ChatTurn } from './providers.ts';
import {
  buildExecutor,
  buildSystemPrompt,
  buildTools,
  loadSemanticModel,
} from './semanticModel.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const MAX_ITERATIONS = 6;
const MAX_HISTORY_TURNS = 12;

interface WizardRequestBody {
  messages: ChatTurn[];
  filters?: Record<string, string[] | undefined>;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

/**
 * The model is asked for bare JSON, and usually complies. When it does
 * not, the failure is almost always a code fence or a sentence of preamble
 * rather than malformed JSON — so recover from those two cases and treat
 * anything else as a genuine parse failure rather than guessing further.
 */
function parseWizardResponse(text: string): Record<string, unknown> {
  const trimmed = text.trim();
  const candidates = [trimmed];

  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced) candidates.push(fenced[1].trim());

  const firstBrace = trimmed.indexOf('{');
  const lastBrace = trimmed.lastIndexOf('}');
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    candidates.push(trimmed.slice(firstBrace, lastBrace + 1));
  }

  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate);
      if (parsed && typeof parsed === 'object') return parsed as Record<string, unknown>;
    } catch {
      // try the next candidate
    }
  }

  // Rather than surface a parse error, treat the model's text as the
  // answer with no citations. The user gets something readable, and the
  // missing citation block is itself the signal that something went wrong.
  return { answer: trimmed, citedMeasures: [], citedTables: [] };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Not signed in.' }, 401);

  let body: WizardRequestBody;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Malformed request body.' }, 400);
  }

  const messages = (body.messages ?? []).filter(
    (m) => (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string',
  );
  if (messages.length === 0) return json({ error: 'No message to answer.' }, 400);

  // Bounded history: a long conversation should cost a predictable amount,
  // and the Wizard re-queries measures rather than relying on old context
  // anyway (see the ChatTurn note in providers.ts).
  const history = messages.slice(-MAX_HISTORY_TURNS);

  // The caller's token, and only the caller's token. No service-role key
  // is read here, deliberately — there is nothing to accidentally use.
  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );

  try {
    // Establish who is asking before touching anything in `metrics`.
    //
    // The order matters. Loading the semantic model first meant an
    // unauthenticated caller got "permission denied for schema metrics"
    // and an HTTP 500 — technically the grants doing their job, but it
    // reads as a broken function rather than a closed door, and it puts a
    // schema name in an error message that reaches an unauthenticated
    // client. Identity first, data second.
    //
    // The anon key is itself a signed JWT, so it satisfies the gateway's
    // verify_jwt and arrives here looking authenticated. getUser() is what
    // distinguishes a real signed-in user from it.
    const { data: userData } = await db.auth.getUser();
    if (!userData?.user) {
      return json({ error: 'Not signed in.' }, 401);
    }

    const [{ measures, catalog, boundary }, sessionRes, cellSizeRes] = await Promise.all([
      loadSemanticModel(db),
      db.schema('metrics').rpc('current_session_context'),
      db.schema('metrics').rpc('minimum_cell_size'),
    ]);

    // Read the role from the database, never from the request. A client
    // that claims to be an admin is a client, not an admin.
    //
    // current_session_context() RETURNS TABLE, so PostgREST sends an array
    // of rows rather than an object, and the column is `app_role` — not
    // `role`. Reading it as an object with a `role` field yields undefined
    // and presents as "your account is not mapped", which is the same
    // shape of bug as the earlier populationCount/population_count one:
    // a silent naming mismatch that reads as a legitimate empty state.
    // SessionContext.tsx unwraps it exactly this way; this now matches.
    const sessionRow = (Array.isArray(sessionRes.data) ? sessionRes.data[0] : sessionRes.data) as
      | { app_role?: string; employee_id?: string | null; capabilities?: string[] }
      | null
      | undefined;

    // Distinguish "the lookup failed" from "the lookup succeeded and this
    // account has no role". Collapsing the two into one message is what
    // sent the last hour sideways: a broken RPC reported itself as an
    // unmapped account, which is a different problem with a different fix.
    if (sessionRes.error) {
      return json(
        { error: `Could not read your session context: ${sessionRes.error.message}` },
        500,
      );
    }

    if (!sessionRow?.app_role) {
      return json({ error: 'Your account is not mapped to a role yet.' }, 403);
    }

    // Provider selection last of the setup steps: a misconfigured or
    // missing API key is operator-facing information, and there is no
    // reason for an unauthenticated caller to be able to probe for it.
    const provider = selectProvider({
      provider: Deno.env.get('WIZARD_PROVIDER') ?? undefined,
      anthropicApiKey: Deno.env.get('ANTHROPIC_API_KEY') ?? undefined,
      geminiApiKey: Deno.env.get('GEMINI_API_KEY') ?? undefined,
      model: Deno.env.get('WIZARD_MODEL') ?? undefined,
      effort: Deno.env.get('WIZARD_EFFORT') ?? undefined,
      dataMode: Deno.env.get('WIZARD_DATA_MODE') ?? undefined,
    });

    const system = buildSystemPrompt({
      catalog,
      boundary,
      role: sessionRow.app_role,
      capabilities: sessionRow.capabilities ?? [],
      activeFilters: body.filters ?? {},
      minimumCellSize: (cellSizeRes.data as number) ?? 5,
    });

    const refusedMeasures = new Set<string>();

    const result = await provider.run({
      system,
      messages: history,
      tools: buildTools(measures),
      execute: buildExecutor(db, measures, refusedMeasures),
      maxIterations: MAX_ITERATIONS,
      // Wall-clock budget for the whole loop. Tunable so it can be lowered
      // to exercise the deadline path without waiting out the real one.
      deadlineMs: Number(Deno.env.get('WIZARD_DEADLINE_MS') ?? '') || undefined,
    });

    const parsed = parseWizardResponse(result.text);

    // Citations are rebuilt from the tool calls that actually succeeded,
    // not from the model's own list. The whole value of a citation is that
    // it is checkable, and a self-reported one is not — a model that
    // hallucinated a number would happily cite a measure for it too.
    const actuallyCalled = [
      ...new Set(
        result.toolCalls
          .filter((c) => c.ok && c.name === 'run_measure')
          .map((c) => String(c.input.measure ?? ''))
          // A measure whose capability gate refused it was called but
          // yielded nothing; citing it would overstate what the answer rests on.
          .filter((m) => m && !refusedMeasures.has(m)),
      ),
    ];

    return json({
      ...parsed,
      citedMeasures: actuallyCalled,
      diagnostics: {
        provider: provider.id,
        servedBy: result.servedBy,
        stopReason: result.stopReason,
        toolCalls: result.toolCalls.length,
        iterations: result.iterations,
        iterationMs: result.iterationMs,
        usage: result.usage,
      },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('wizard error:', message);
    return json({ error: message }, 500);
  }
});

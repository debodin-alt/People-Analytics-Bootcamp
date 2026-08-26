import { useEffect, useRef, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useFilters } from '../context/FilterContext';
import { useSession } from '../context/SessionContext';
import { ChartFrame } from '../components/charts/ChartFrame';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { TrendLine } from '../components/charts/TrendLine';
import { filterParams } from '../lib/useMetric';
import type { WizardChartSpec, WizardResponse } from '../lib/types';

/**
 * Page 12 — the Wizard (PRD_Class2 §6.1, WIZ-1..WIZ-6).
 *
 * A conversational analyst over the semantic layer. Three properties are
 * doing the work, and each is a deliberate constraint rather than a
 * feature:
 *
 *  - It cannot see more than the user can (WIZ-2). The Edge Function
 *    behind this page holds no privileged credential; it queries with the
 *    caller's own JWT, so capability gates, row scope and cell-size
 *    suppression apply unchanged. There is no separate permission model to
 *    keep in sync, because there is no second path to the data.
 *
 *  - It cannot invent a number (WIZ-1). Citations rendered below are
 *    rebuilt server-side from the measures that actually ran, not from the
 *    model's own account of what it used. An uncited answer is visible as
 *    such.
 *
 *  - It cannot invent a chart (WIZ-5). A returned chart spec names a
 *    measure and a dimension; this page runs that measure through the same
 *    RPC path every dashboard page uses and renders it with the same
 *    components. The Wizard cannot draw something the dashboard could not.
 */

interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
  response?: WizardResponse;
  diagnostics?: Record<string, unknown>;
  error?: string;
}

const SUGGESTIONS = [
  'Which function has the highest voluntary attrition?',
  'How has headcount moved over the last 12 months?',
  'What is the median compa-ratio, and where is it lowest?',
  'Where are we below 60 days to fill?',
];

export function Wizard() {
  const { filters } = useFilters();
  const { role } = useSession();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const endRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, [messages, busy]);

  async function ask(question: string) {
    const trimmed = question.trim();
    if (!trimmed || busy) return;

    const history: ChatMessage[] = [...messages, { role: 'user', content: trimmed }];
    setMessages(history);
    setInput('');
    setBusy(true);

    try {
      const { data, error } = await supabase.functions.invoke('wizard', {
        body: {
          // Only role and content cross the wire — the chart specs and
          // diagnostics attached to earlier turns are presentation state,
          // not conversation.
          messages: history.map((m) => ({ role: m.role, content: m.content })),
          filters: {
            function: filters.function,
            location: filters.location,
            levelBand: filters.levelBand,
            tenureBand: filters.tenureBand,
          },
        },
      });

      if (error) throw error;

      if (data?.error) {
        setMessages((m) => [...m, { role: 'assistant', content: '', error: data.error }]);
        return;
      }

      const response = data as WizardResponse & { diagnostics?: Record<string, unknown> };
      setMessages((m) => [
        ...m,
        {
          role: 'assistant',
          content: response.answer ?? '',
          response,
          diagnostics: response.diagnostics,
        },
      ]);
    } catch (err) {
      setMessages((m) => [
        ...m,
        {
          role: 'assistant',
          content: '',
          error: err instanceof Error ? err.message : String(err),
        },
      ]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="wizard">
      <div className="wizard-intro">
        <h2 className="wizard-title">Ask the data</h2>
        <p className="wizard-sub">
          Answers come from the same measures as every chart on this platform, run under your own
          permissions as <strong>{role}</strong>. Nothing here can show you a figure the dashboard
          would withhold — and every number carries the measure it came from.
        </p>
      </div>

      {messages.length === 0 && (
        <div className="wizard-suggestions">
          {SUGGESTIONS.map((s) => (
            <button key={s} className="wizard-suggestion" onClick={() => ask(s)}>
              {s}
            </button>
          ))}
        </div>
      )}

      <div className="wizard-thread">
        {messages.map((m, i) => (
          <Turn key={i} message={m} />
        ))}
        {busy && (
          <div className="wizard-turn assistant">
            <div className="wizard-bubble thinking">Querying the semantic layer…</div>
          </div>
        )}
        <div ref={endRef} />
      </div>

      <form
        className="wizard-composer"
        onSubmit={(e) => {
          e.preventDefault();
          ask(input);
        }}
      >
        <input
          className="wizard-input"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Ask about headcount, attrition, pay, hiring or engagement…"
          disabled={busy}
        />
        <button className="wizard-send" type="submit" disabled={busy || !input.trim()}>
          Ask
        </button>
      </form>
    </div>
  );
}

function Turn({ message }: { message: ChatMessage }) {
  if (message.role === 'user') {
    return (
      <div className="wizard-turn user">
        <div className="wizard-bubble user">{message.content}</div>
      </div>
    );
  }

  const r = message.response;

  return (
    <div className="wizard-turn assistant">
      <div className="wizard-bubble">
        {message.error && <p className="wizard-error">{message.error}</p>}

        {r?.refused && <p className="wizard-refusal">{r.refused.reason}</p>}

        {r?.clarificationNeeded && (
          <p className="wizard-clarify">{r.clarificationNeeded.question}</p>
        )}

        {message.content && <p className="wizard-answer">{message.content}</p>}

        {r?.chart && <WizardChart spec={r.chart} />}

        {r && r.citedMeasures.length > 0 && (
          <div className="wizard-citations">
            <span className="wizard-citations-label">From</span>
            {r.citedMeasures.map((m) => (
              <code key={m} className="wizard-citation">
                {m}
              </code>
            ))}
          </div>
        )}

        {/* An answer with no citation ran no measure. That is worth showing
            rather than hiding: it is exactly the case where the text should
            not be trusted as a figure. */}
        {r && !r.refused && !r.clarificationNeeded && r.citedMeasures.length === 0 &&
          message.content && (
            <p className="wizard-uncited">
              No measure was run for this answer — treat it as commentary, not as data.
            </p>
          )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Chart rendering — through the existing components, never a second system
// ---------------------------------------------------------------------------

type Row = Record<string, unknown>;

const LABEL_KEYS = ['label', 'band', 'period', 'reason', 'stage_name', 'category', 'value'];

/** Pick the category column: a known label name, else the first string column. */
function labelKey(row: Row): string | null {
  for (const k of LABEL_KEYS) if (k in row && typeof row[k] === 'string') return k;
  for (const [k, v] of Object.entries(row)) if (typeof v === 'string') return k;
  return null;
}

/** Pick the value column: the first numeric column that isn't an ordering hint. */
function valueKey(row: Row, exclude: string | null): string | null {
  for (const [k, v] of Object.entries(row)) {
    if (k === exclude || k.endsWith('_order')) continue;
    if (typeof v === 'number') return k;
  }
  return null;
}

function WizardChart({ spec }: { spec: WizardChartSpec }) {
  const [state, setState] = useState<{ loading: boolean; rows: Row[] | null; error: string | null }>(
    { loading: true, rows: null, error: null },
  );

  const key = JSON.stringify(spec);

  useEffect(() => {
    let cancelled = false;
    setState({ loading: true, rows: null, error: null });

    const args: Record<string, unknown> = {
      ...filterParams({
        function: spec.filters?.function,
        location: spec.filters?.location,
        levelBand: spec.filters?.levelBand,
        tenureBand: spec.filters?.tenureBand,
      }),
    };
    if (spec.dimension) args.p_dimension = spec.dimension;

    supabase
      .schema('metrics')
      .rpc(spec.measure, args)
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) {
          setState({ loading: false, rows: null, error: error.message });
          return;
        }
        setState({ loading: false, rows: (data ?? []) as Row[], error: null });
      });

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  const rows = state.rows ?? [];
  const status = state.loading
    ? 'loading'
    : state.error
      ? 'error'
      : rows.length === 0
        ? 'empty'
        : 'ready';

  const lk = rows.length ? labelKey(rows[0]) : null;
  const vk = rows.length ? valueKey(rows[0], lk) : null;

  // A spec that does not resolve to a label and a value is not renderable.
  // Say so rather than drawing an empty frame that reads as "no data".
  if (status === 'ready' && (!lk || !vk)) {
    return (
      <ChartFrame
        title={spec.title}
        status="error"
        errorMessage={`Could not chart ${spec.measure} — its result has no obvious category and value column.`}
      >
        <div />
      </ChartFrame>
    );
  }

  const data = rows.map((r) => ({
    label: String(r[lk!] ?? ''),
    value: Number(r[vk!] ?? 0),
  }));

  const isTrend = spec.form === 'line';

  return (
    <ChartFrame
      title={spec.title}
      status={status}
      errorMessage={state.error ?? undefined}
      emptyReason="No rows for this population."
      bodyHeight={isTrend ? undefined : Math.max(180, data.length * 22 + 40)}
      note={`${spec.measure}${spec.dimension ? ` by ${spec.dimension}` : ''}`}
    >
      {isTrend ? (
        <TrendLine
          data={data.map((d) => ({ period: d.label, value: d.value }))}
          valueLabel={vk ?? 'Value'}
        />
      ) : (
        <SortedHorizontalBar
          data={data}
          valueLabel={vk ?? 'Value'}
          // Ordinal dimensions must keep their sequence — sorting a tenure
          // profile by magnitude destroys the shape it exists to show.
          preserveOrder={
            spec.dimension === 'tenure_band' ||
            spec.dimension === 'level_band' ||
            spec.dimension === 'career_level'
          }
        />
      )}
    </ChartFrame>
  );
}

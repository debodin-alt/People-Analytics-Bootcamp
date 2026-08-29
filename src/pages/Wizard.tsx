import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { supabase } from '../lib/supabase';
import { ask, bindUser, clearThread, getSnapshot, subscribe } from '../lib/wizardStore';
import type { ChatMessage } from '../lib/wizardStore';
import { useFilters } from '../context/FilterContext';
import { useSession } from '../context/SessionContext';
import { ChartFrame } from '../components/charts/ChartFrame';
import { SortedHorizontalBar } from '../components/charts/SortedHorizontalBar';
import { TrendLine } from '../components/charts/TrendLine';
import { filterParams } from '../lib/useMetric';
import type { WizardChartSpec } from '../lib/types';

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

const SUGGESTIONS = [
  'Which function has the highest voluntary attrition?',
  'How has headcount moved over the last 12 months?',
  'What is the median compa-ratio, and where is it lowest?',
  'Where are we below 60 days to fill?',
];

export function Wizard() {
  const { filters } = useFilters();
  const { role, session } = useSession();
  const [input, setInput] = useState('');
  const endRef = useRef<HTMLDivElement>(null);

  // The thread lives in the store, not here, so navigating away mid-question
  // neither cancels it nor loses it (see lib/wizardStore.ts).
  const state = useSyncExternalStore(subscribe, getSnapshot);
  const { messages, startedAt } = state;
  const busy = startedAt !== null;

  const userId = session?.user?.id ?? null;
  useEffect(() => {
    bindUser(userId);
  }, [userId]);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
  }, [messages, busy]);

  const send = (q: string) => {
    if (busy) return;
    setInput('');
    void ask(q, filters);
  };

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
            <button key={s} className="wizard-suggestion" onClick={() => send(s)}>
              {s}
            </button>
          ))}
        </div>
      )}

      {messages.length > 0 && (
        <button className="wizard-clear" onClick={clearThread} disabled={busy}>
          Clear conversation
        </button>
      )}

      <div className="wizard-thread">
        {messages.map((m, i) => (
          <Turn key={i} message={m} />
        ))}
        {busy && <Thinking startedAt={startedAt} />}
        <div ref={endRef} />
      </div>

      <form
        className="wizard-composer"
        onSubmit={(e) => {
          e.preventDefault();
          send(input);
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

/**
 * A live wait indicator.
 *
 * A broad question ("how are we doing on hiring?") fans out to seven
 * measures across three model round trips, and upstream latency varies
 * enormously — the same question has been measured at 22s and at 95s. A
 * static "Querying…" is indistinguishable from a hung page for the whole
 * of that, and the natural response is to reload, which throws away the
 * work and starts the wait again.
 *
 * So show the clock. The number moving is what says the thing is alive,
 * and the note after fifteen seconds explains the wait rather than leaving
 * the user to invent a worse explanation for it.
 */
function Thinking({ startedAt }: { startedAt: number }) {
  const [elapsed, setElapsed] = useState(() => Math.round((Date.now() - startedAt) / 1000));

  useEffect(() => {
    // Derived from the store's start time, not from mount, so leaving the
    // page and returning shows the true elapsed time rather than resetting.
    const id = setInterval(() => setElapsed(Math.round((Date.now() - startedAt) / 1000)), 250);
    return () => clearInterval(id);
  }, [startedAt]);

  return (
    <div className="wizard-turn assistant">
      <div className="wizard-bubble thinking">
        <span className="wizard-pulse" />
        Querying the semantic layer… {elapsed}s
        {elapsed >= 15 && (
          <div className="wizard-thinking-note">
            Broad questions run several measures in sequence. This can take up to a minute.
          </div>
        )}
      </div>
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

/**
 * Does the title claim a proportion, and does the column supply one?
 *
 * The prompt tells the model to keep its title and its column in
 * agreement, but a prompt is a request, not a guarantee — and this
 * particular disagreement is the most damaging one the Wizard can
 * produce. "Voluntary Attrition Rate by Function" plotted from
 * `voluntary` puts Engineering on top at 20 while the prose above it says
 * Design at 23.3%: a chart that contradicts its own answer, and the chart
 * is what gets believed. Detect it and say so on the chart rather than
 * rendering something authoritative and wrong.
 *
 * Not auto-corrected. Swapping the column on a string match would be
 * guessing at intent, and a wrong silent correction is the same class of
 * problem as the bug. Naming the discrepancy leaves the reader able to
 * judge it.
 */
const RATE_WORDS = /\b(rate|percent|percentage|ratio|share|proportion)\b|%/i;
const RATE_COLUMN = /(rate|pct|percent|ratio|share)/i;

function titleColumnMismatch(title: string, column: string | null): string | null {
  if (!column) return null;
  const titleSaysRate = RATE_WORDS.test(title);
  const columnIsRate = RATE_COLUMN.test(column);
  if (titleSaysRate && !columnIsRate) {
    return `Title mentions a rate, but this plots ${column} — read it as counts, not percentages.`;
  }
  if (!titleSaysRate && columnIsRate) {
    return `This plots ${column}, which is a rate rather than the count the title implies.`;
  }
  return null;
}

/** Sequence columns a result may carry to declare its own order. */
function orderKey(row: Row): string | null {
  for (const k of Object.keys(row)) if (k.endsWith('_order') && typeof row[k] === 'number') return k;
  return null;
}

/** Pick the category column: the model's choice, a known label name, else
 *  the first string column. */
function labelKey(row: Row, named?: string): string | null {
  if (named && named in row) return named;
  for (const k of LABEL_KEYS) if (k in row && typeof row[k] === 'string') return k;
  for (const [k, v] of Object.entries(row)) if (typeof v === 'string') return k;
  return null;
}

/**
 * Pick the column to plot.
 *
 * The model names it, because it is the only party that knows which series
 * its title refers to. The fallback — first numeric column — is genuinely
 * unsafe and kept only so an older spec still draws something: PostgREST
 * returns keys alphabetically, so for attrition_by_dimension it picks
 * avg_headcount, and a chart titled "Voluntary Attrition Rate" then plots
 * headcounts. Hence the mismatch warning at the call site.
 */
function valueKey(row: Row, exclude: string | null, named?: string): string | null {
  if (named && named in row && typeof row[named] === 'number') return named;
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

  const lk = rows.length ? labelKey(rows[0], spec.labelColumn) : null;
  const vk = rows.length ? valueKey(rows[0], lk, spec.valueColumn) : null;
  // The model named a column that isn't in the result: say so rather than
  // silently charting a different series under its title.
  const columnMissing =
    !!spec.valueColumn && rows.length > 0 && !(spec.valueColumn in rows[0]);

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

  // A result that declares its own order keeps it. The recruiting funnel
  // is the case in point: Application -> Hire is a sequence, and sorting
  // it by magnitude only looks right because the funnel happens to shrink
  // monotonically. One stage larger than the one before would scramble it.
  const ok = rows.length ? orderKey(rows[0]) : null;
  const ordered = ok ? [...rows].sort((a, b) => Number(a[ok]) - Number(b[ok])) : rows;

  // A null value is not a zero.
  //
  // A cut with no measurable population returns null, and `Number(null)` is
  // 0 — which draws a bar of length zero saying "no attrition here" when
  // the truth is "not computable here". Attrition.tsx already drops these
  // for the same reason; the Wizard has to as well, or the same population
  // reads differently depending on which page you saw it on. Genuine zeros
  // (Executive: 1 person, 0 leavers) are kept, because those are facts.
  const usable = ordered.filter((r) => r[vk!] !== null && r[vk!] !== undefined);
  const notComputable = ordered.length - usable.length;

  const data = usable.map((r) => ({
    label: String(r[lk!] ?? ''),
    value: Number(r[vk!]),
  }));

  const mismatch = titleColumnMismatch(spec.title, vk);

  const isTrend = spec.form === 'line';

  // An explicit pixel height, not a min-height.
  //
  // ChartFrame is `display:flex` with `.chart-body { flex: 1 }`. On a
  // dashboard page the frame is a grid item, so it has a definite height
  // and flex:1 resolves to one. In a chat bubble it is a plain block sized
  // by its content, flex:1 resolves to zero, and Recharts' 100%-height
  // ResponsiveContainer draws nothing into a correctly-sized empty box.
  const chartHeight = isTrend ? 260 : Math.max(220, data.length * 26 + 56);

  return (
    <ChartFrame
      title={spec.title}
      status={status}
      errorMessage={state.error ?? undefined}
      emptyReason="No rows for this population."
      bodyHeight={chartHeight}
      note={
        columnMissing
          ? `${spec.measure} — could not find column "${spec.valueColumn}"; showing ${vk} instead`
          : mismatch
            ? `⚠ ${mismatch}`
            : `${spec.measure}${spec.dimension ? ` by ${spec.dimension}` : ''}${vk ? ` — ${vk}` : ''}` +
              (notComputable > 0
                ? ` (${notComputable} cut${notComputable > 1 ? 's' : ''} omitted — not computable)`
                : '')
      }
    >
      <div style={{ height: chartHeight }}>
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
            ok !== null ||
            spec.dimension === 'tenure_band' ||
            spec.dimension === 'level_band' ||
            spec.dimension === 'career_level'
          }
        />
      )}
      </div>
    </ChartFrame>
  );
}

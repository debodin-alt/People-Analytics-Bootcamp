import { useTableRpc } from '../lib/useMetric';

interface CatalogRow {
  measure: string;
  arguments: string;
  returns_metric_result: boolean;
  definition: string;
}

/**
 * Page 11 — Methodology (PRD_Class2 §6.1, MET-1).
 *
 * The metric catalog is read from pg_description at runtime rather than
 * restated here. Documentation that lives beside the code it documents
 * cannot silently fall behind it — and when this page was first built the
 * catalog immediately reported 26 of 47 measures undocumented, which a
 * hand-maintained list would never have surfaced.
 */
export function Methodology() {
  const catalog = useTableRpc<CatalogRow>('metric_catalog');
  const vintage = useTableRpc<{ domain: string; boundary: string; note: string }>('data_vintage');

  return (
    <div style={{ maxWidth: 940 }}>
      <Section title="Data vintage">
        <p style={pStyle}>
          The reporting boundary is derived from the loaded data, never hardcoded, so the same code works on every
          refresh. It is scoped per domain: a requisition closing late must not move the attrition window.
        </p>
        {vintage.loading && <p style={pStyle}>Loading…</p>}
        {vintage.data && (
          <table style={tableStyle}>
            <thead>
              <tr>
                <Th>Domain</Th>
                <Th>Boundary</Th>
                <Th>Scope</Th>
              </tr>
            </thead>
            <tbody>
              {vintage.data.map((v) => (
                <tr key={v.domain}>
                  <Td mono>{v.domain}</Td>
                  <Td mono>{v.boundary}</Td>
                  <Td>{v.note}</Td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Section>

      <Section title="Known variances from the source PRD">
        <p style={pStyle}>
          Where this platform disagrees with a figure printed in the bootcamp PRD, the disagreement is recorded here
          rather than resolved by fitting the code to the number.
        </p>
        <ul style={ulStyle}>
          <li>
            <strong>Voluntary attrition reads 9.0%, the PRD prints 8.9%.</strong> The PRD defines the measure as
            terminations over <em>average</em> active headcount, but its printed figure divides by <em>ending</em>{' '}
            headcount (820 rather than 807). This implementation follows the written definition. Ending headcount
            understates attrition whenever the workforce grew during the period, and Meridian grew 794 → 820. The
            termination count itself matches exactly (73).
          </li>
          <li>
            <strong>Offer acceptance is reported as two measures, not one.</strong> The PRD names the metric
            "first-offer acceptance", gives the formula <code>offers_accepted ÷ offers_made</code>, and prints 87%.
            Those describe different things: the formula yields 68.5% (overall acceptance — a requisition needing three
            offers counts three times in the denominator), while "filled on a single offer" yields 85.6%. Both are
            published under names that say what they compute. The residual 1.4pp against 87% is unexplained by any
            scoping we could identify.
          </li>
          <li>
            <strong>Median time to fill reads 62 days</strong> against a 60-day figure in the PRD, which appears to be
            the stated target rather than the observed value.
          </li>
        </ul>
      </Section>

      <Section title="The two engagement instruments">
        <p style={pStyle}>
          Meridian measures engagement two different ways, and they are <strong>never combined</strong>:
        </p>
        <ul style={ulStyle}>
          <li>
            <strong>Anonymous survey</strong> — 30 Likert items on a <strong>1–5</strong> scale, 720 responses.{' '}
            <code>engagement_responses</code> carries no employee key, so anonymity is structural rather than a setting
            that could be changed. Reported in aggregate only, suppressed below five respondents.
          </li>
          <li>
            <strong>Per-employee score</strong> — <code>latest_engagement_score</code> on the employee record, on a{' '}
            <strong>0–10</strong> scale.
          </li>
        </ul>
        <p style={pStyle}>
          They are different instruments on different scales. Averaging them, or plotting them on a shared axis, would
          produce a number that means nothing.
        </p>
      </Section>

      <Section title="Market comparison — mapping caveats">
        <p style={pStyle}>
          Every market-position figure passes through three mapping tables. Without them the comparisons are wrong in
          ways that still look plausible:
        </p>
        <ul style={ulStyle}>
          <li>
            <strong>Level mapping.</strong> Meridian uses P1–P7 / M3–M8; the benchmark uses I–VII / M, SrM, D, VP, SVP.
            No mapping, no valid benchmark join.
          </li>
          <li>
            <strong>Pay-zone tiering.</strong> Meridian's internal <code>pay_zone</code> tags Boston, Dublin and Toronto
            all as "High", while the benchmark places Boston at Tier 1 (100), Dublin at Tier 7 (80) and Toronto at Tier 6
            (76). Joining on the internal zone would overstate Dublin and Toronto underpayment by roughly 20–24%.
            Resolution is keyed on office <em>and</em> internal zone together, because Remote-US spans three tiers on its
            own.
          </li>
          <li>
            <strong>Currency.</strong> Base salary is stored in local currency. Any measure summing or averaging raw
            salary converts to USD first; compa-ratio and range penetration are already normalised and must{' '}
            <em>not</em> be converted.
          </li>
        </ul>
      </Section>

      <Section title="Privacy and suppression">
        <ul style={ulStyle}>
          <li>
            The browser holds <strong>no row-level access to any table containing people</strong>. Its entire data
            surface is the aggregate measures below.
          </li>
          <li>
            Aggregates over a personal attribute are suppressed below <strong>five</strong> people. Flight risk
            suppresses on the denominator, so "1 of 2" cannot identify anyone.
          </li>
          <li>
            Names, work email and date of birth never enter the semantic layer. Open-ended survey text is never exposed —
            free text alongside function, level, tenure and location re-identifies people.
          </li>
          <li>
            <strong>Not yet addressed:</strong> differencing. Someone patient can still narrow successive aggregate
            queries to infer an individual. Minimum cell size does not prevent this, and no query-history-aware
            suppression exists yet. The Wizard lowers the effort involved, since asking is cheaper than clicking — it
            is instructed not to assist with it, but an instruction is a deterrent, not a control. A real control is
            query-log auditing plus a per-session limit on how finely one person may re-cut the same population.
          </li>
        </ul>
      </Section>

      <Section title="Responsible use">
        <p style={{ ...pStyle, borderLeft: '3px solid var(--warning)', paddingLeft: 12 }}>
          These indicators are directional, not predictive of any individual's decision. They are derived from patterns
          in historical data and should inform conversations, never employment decisions on their own. Flight-risk
          rating is a field carried in the source data, not a score this platform computes. Unadjusted pay comparisons
          do not control for level, function, location or tenure and are not evidence of discrimination.
        </p>
      </Section>

      <Section title={`Metric catalog${catalog.data ? ` (${catalog.data.length})` : ''}`}>
        <p style={pStyle}>
          Read live from the database, so a measure cannot exist without a definition appearing here.
        </p>
        {catalog.loading && <p style={pStyle}>Loading…</p>}
        {catalog.error && <p style={{ ...pStyle, color: 'var(--critical)' }}>{catalog.error}</p>}
        {catalog.data && (
          <table style={tableStyle}>
            <thead>
              <tr>
                <Th>Measure</Th>
                <Th>Definition</Th>
              </tr>
            </thead>
            <tbody>
              {catalog.data.map((m) => (
                <tr key={m.measure}>
                  <Td mono>
                    {m.measure}
                    {m.returns_metric_result && (
                      <span style={{ display: 'block', fontSize: 10, color: 'var(--ink-faint)' }}>typed result</span>
                    )}
                  </Td>
                  <Td>{m.definition}</Td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Section>
    </div>
  );
}

const pStyle: React.CSSProperties = { margin: '0 0 10px', fontSize: 13, lineHeight: 1.6, color: 'var(--ink-muted)' };
const ulStyle: React.CSSProperties = { margin: '0 0 10px', paddingLeft: 18, fontSize: 13, lineHeight: 1.7, color: 'var(--ink-muted)' };
const tableStyle: React.CSSProperties = { width: '100%', borderCollapse: 'collapse', fontSize: 12, marginTop: 8 };

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section
      style={{
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 10,
        padding: '16px 18px',
        marginBottom: 14,
      }}
    >
      <h2 style={{ fontSize: 14, margin: '0 0 10px', color: 'var(--ink)' }}>{title}</h2>
      {children}
    </section>
  );
}

function Th({ children }: { children: React.ReactNode }) {
  return (
    <th style={{ textAlign: 'left', padding: '6px 10px 6px 0', borderBottom: '1px solid var(--border)', color: 'var(--ink)', fontWeight: 600 }}>
      {children}
    </th>
  );
}

function Td({ children, mono }: { children: React.ReactNode; mono?: boolean }) {
  return (
    <td
      style={{
        padding: '7px 10px 7px 0',
        borderBottom: '1px solid var(--border)',
        color: 'var(--ink-muted)',
        verticalAlign: 'top',
        fontFamily: mono ? 'var(--mono)' : undefined,
        whiteSpace: mono ? 'nowrap' : undefined,
      }}
    >
      {children}
    </td>
  );
}

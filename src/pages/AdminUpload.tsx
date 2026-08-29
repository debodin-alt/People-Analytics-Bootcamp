import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { FileAdapter, type ParsedTable } from '../lib/sourceAdapter';

/**
 * Page 13 — Admin: Data Upload (ING-1..ING-10).
 *
 * The four steps are deliberately separate and separately visible: read
 * the file, stage it, validate it, promote it. A single "Upload" button
 * that did all four would hide the only moment that matters — the point
 * after validation where a person can still say no.
 *
 * Nothing here decides whether the data is acceptable. The browser parses
 * and reports; the database validates against the constraints production
 * actually enforces and refuses the promote itself if anything fails. That
 * split is why this screen cannot be talked into a bad load by a
 * mis-parsed spreadsheet: the last word belongs to the constraints, not to
 * this code.
 */

interface Failure {
  table_name: string;
  source_row: number | null;
  rule: string;
  detail: string;
}

interface Blocker {
  blocker: string;
  detail: string;
}

interface Staged {
  table_name: string;
  rows_staged: number;
}

type Phase = 'idle' | 'reading' | 'staging' | 'validating' | 'ready' | 'promoting' | 'done';

const BATCH = 500;

export function AdminUpload() {
  const [schema, setSchema] = useState<{ names: string[]; cols: Record<string, string[]> } | null>(
    null,
  );
  const [phase, setPhase] = useState<Phase>('idle');
  const [note, setNote] = useState<string>('');
  const [parsed, setParsed] = useState<ParsedTable[]>([]);
  const [staged, setStaged] = useState<Staged[]>([]);
  const [failures, setFailures] = useState<Failure[]>([]);
  const [blockers, setBlockers] = useState<Blocker[]>([]);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fileNames, setFileNames] = useState<string[]>([]);

  useEffect(() => {
    supabase
      .rpc('ingest_target_schema')
      .then(({ data, error: e }) => {
        if (e) { setError(e.message); return; }
        const rows = (data ?? []) as { table_name: string; columns: string[] }[];
        setSchema({
          names: rows.map((r) => r.table_name),
          cols: Object.fromEntries(rows.map((r) => [r.table_name, r.columns])),
        });
      });
  }, []);

  async function handleFiles(files: FileList | null) {
    if (!files || files.length === 0 || !schema) return;
    setError(null);
    setResult(null);
    setFailures([]);
    setBlockers([]);
    setParsed([]);
    setStaged([]);

    try {
      setPhase('reading');
      const adapter = new FileAdapter(schema.names, schema.cols);
      const names = Array.from(files).map((f) => f.name);
      setFileNames(names);

      const tables: ParsedTable[] = [];
      for (const file of Array.from(files)) {
        setNote(`Reading ${file.name}…`);
        tables.push(...(await adapter.parseDetailed(file, file.name)));
      }
      setParsed(tables);

      // A previous half-finished attempt must not ride along with this one.
      setPhase('staging');
      setNote('Clearing previous staging…');
      const { error: resetErr } = await supabase.rpc('ingest_reset');
      if (resetErr) throw new Error(resetErr.message);

      for (const t of tables) {
        if (t.unrecognised || t.rows.length === 0) continue;
        for (let i = 0; i < t.rows.length; i += BATCH) {
          setNote(`Staging ${t.targetTable} ${i + 1}–${Math.min(i + BATCH, t.rows.length)}…`);
          const { error: e } = await supabase
            .rpc('ingest_stage_rows', { p_table: t.targetTable, p_rows: t.rows.slice(i, i + BATCH) });
          if (e) throw new Error(`${t.targetTable}: ${e.message}`);
        }
      }

      setPhase('validating');
      setNote('Validating against the production constraints…');
      const [sum, val, blk] = await Promise.all([
        supabase.rpc('ingest_staged_summary'),
        supabase.rpc('ingest_validate', { p_max_failures: 500 }),
        supabase.rpc('ingest_blockers'),
      ]);
      if (sum.error) throw new Error(sum.error.message);
      if (val.error) throw new Error(val.error.message);
      if (blk.error) throw new Error(blk.error.message);

      setStaged((sum.data ?? []) as Staged[]);
      setFailures((val.data ?? []) as Failure[]);
      setBlockers((blk.data ?? []) as Blocker[]);
      setPhase('ready');
      setNote('');
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      setPhase('idle');
      setNote('');
    }
  }

  async function promote() {
    setPhase('promoting');
    setNote('Replacing production data…');
    setError(null);
    try {
      const { data, error: e } = await supabase
        .rpc('ingest_promote', { p_file_names: fileNames, p_note: null });
      if (e) throw new Error(e.message);
      const row = (Array.isArray(data) ? data[0] : data) as
        | { data_load_id: string; tables_replaced: string[]; row_counts: Record<string, number> }
        | undefined;
      const total = Object.values(row?.row_counts ?? {}).reduce((a, b) => a + b, 0);
      setResult(
        `Loaded ${total.toLocaleString()} rows into ${row?.tables_replaced.length ?? 0} table(s). ` +
          `Reference ${row?.data_load_id}.`,
      );
      setStaged([]);
      setParsed([]);
      setPhase('done');
      setNote('');
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      setPhase('ready');
      setNote('');
    }
  }

  const busy = phase === 'reading' || phase === 'staging' || phase === 'validating' || phase === 'promoting';
  const canPromote = phase === 'ready' && staged.length > 0 && failures.length === 0 && blockers.length === 0;

  return (
    <div style={{ maxWidth: 940 }}>
      <h2 style={{ fontSize: 20, fontWeight: 600, margin: '0 0 6px' }}>Data upload</h2>
      <p style={{ fontSize: 13, lineHeight: 1.55, color: 'var(--ink-muted)', maxWidth: '64ch' }}>
        Files are read here, staged, and checked against the constraints production actually
        enforces before anything is replaced. A load is all or nothing: if any row fails, nothing
        is written. Tables you do not upload are left untouched.
      </p>

      <div className="upload-drop">
        <input
          type="file"
          multiple
          accept=".xlsx,.xls,.csv"
          disabled={busy || !schema}
          onChange={(e) => handleFiles(e.target.files)}
        />
        <div className="upload-hint">
          .xlsx or .csv — sheet names are matched to tables, column headers to columns.
        </div>
      </div>

      {busy && <p className="upload-status">{note}</p>}
      {error && <p className="upload-error">{error}</p>}
      {result && <p className="upload-ok">{result}</p>}

      {parsed.length > 0 && (
        <Section title="What was read">
          <table className="upload-table">
            <thead>
              <tr><Th>Sheet</Th><Th>Table</Th><Th>Header row</Th><Th>Rows</Th><Th>Unmapped columns</Th></tr>
            </thead>
            <tbody>
              {parsed.map((t) => (
                <tr key={t.sheetName}>
                  <Td>{t.sheetName}</Td>
                  <Td mono>{t.unrecognised ? <span className="upload-warn">not recognised — skipped</span> : t.targetTable}</Td>
                  <Td>{t.headerRowIndex + 1}</Td>
                  <Td>{t.rows.length.toLocaleString()}</Td>
                  {/* Columns the file carries that no target column matched.
                      Shown rather than dropped quietly: a silently ignored
                      column is a successful-looking load of partial data. */}
                  <Td>{t.unmappedColumns.length === 0 ? '—' : <span className="upload-warn">{t.unmappedColumns.join(', ')}</span>}</Td>
                </tr>
              ))}
            </tbody>
          </table>
        </Section>
      )}

      {staged.length > 0 && (
        <Section title="Staged">
          <p className="upload-sub">Counted in the database, not in the browser.</p>
          <table className="upload-table">
            <thead><tr><Th>Table</Th><Th>Rows</Th></tr></thead>
            <tbody>
              {staged.map((s) => (
                <tr key={s.table_name}><Td mono>{s.table_name}</Td><Td>{s.rows_staged.toLocaleString()}</Td></tr>
              ))}
            </tbody>
          </table>
        </Section>
      )}

      {blockers.length > 0 && (
        <Section title="Cannot promote">
          {blockers.map((b, i) => (
            <p key={i} className="upload-error">{b.detail}</p>
          ))}
        </Section>
      )}

      {failures.length > 0 && (
        <Section title={`${failures.length} row${failures.length > 1 ? 's' : ''} rejected`}>
          <p className="upload-sub">Row numbers are the line in the uploaded file.</p>
          <table className="upload-table">
            <thead><tr><Th>Table</Th><Th>Row</Th><Th>Problem</Th></tr></thead>
            <tbody>
              {failures.slice(0, 100).map((f, i) => (
                <tr key={i}>
                  <Td mono>{f.table_name}</Td>
                  <Td>{f.source_row ?? '—'}</Td>
                  <Td>{f.detail}</Td>
                </tr>
              ))}
            </tbody>
          </table>
          {failures.length > 100 && (
            <p className="upload-sub">Showing the first 100 of {failures.length}.</p>
          )}
        </Section>
      )}

      {phase === 'ready' && (
        <div className="upload-actions">
          <button className="upload-promote" disabled={!canPromote} onClick={promote}>
            Replace production data
          </button>
          {!canPromote && staged.length > 0 && (
            <span className="upload-sub">
              {blockers.length > 0
                ? 'Resolve the blocker above first.'
                : 'Fix the rejected rows and upload again.'}
            </span>
          )}
        </div>
      )}
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section style={{ marginTop: 22 }}>
      <h3 style={{ fontSize: 14, fontWeight: 600, margin: '0 0 8px' }}>{title}</h3>
      {children}
    </section>
  );
}

function Th({ children }: { children: React.ReactNode }) {
  return <th style={{ textAlign: 'left', fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--ink-faint)', padding: '6px 10px 6px 0', borderBottom: '1px solid var(--border)' }}>{children}</th>;
}

function Td({ children, mono }: { children: React.ReactNode; mono?: boolean }) {
  return <td style={{ padding: '6px 10px 6px 0', borderBottom: '1px solid var(--border)', fontSize: 12.5, fontFamily: mono ? 'var(--mono)' : undefined, verticalAlign: 'top' }}>{children}</td>;
}

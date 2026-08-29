import type { RawTable, SourceAdapter } from './types';

/**
 * The file adapter (ING-1).
 *
 * SourceAdapter exists so the platform is not welded to spreadsheets: the
 * same contract is what an HRIS export or a warehouse extract would
 * implement later. This is the first implementation, not the only intended
 * one, which is why the parsing lives behind the interface rather than
 * inside the upload screen.
 *
 * Two things it deliberately does not do.
 *
 * It does not guess at a sheet whose name it cannot match to a table, and
 * it does not quietly drop a column it cannot place. Both are reported and
 * shown, because a loader that silently ignores half a file produces a
 * successful-looking load of partial data — which is worse than a refusal,
 * since nothing about the result says anything is missing.
 *
 * It also does not use the `xlsx` npm package. That package is abandoned
 * at 0.18.5 and carries CVE-2023-30533, prototype pollution triggered by a
 * crafted file; the advisory notes that workflows not reading arbitrary
 * files are unaffected, and reading an arbitrary uploaded file is exactly
 * what this does. exceljs is maintained and is loaded dynamically, so a
 * megabyte of spreadsheet parser stays out of the bundle for the many
 * users who never open this screen.
 */

export interface ParsedTable extends RawTable {
  /** Worksheet or file the rows came from, for reporting against the source. */
  sheetName: string;
  /** Columns present in the file that no target column matched. */
  unmappedColumns: string[];
  /** Set when the sheet name matched no known table; rows are not staged. */
  unrecognised?: boolean;
}

/** lowercase, non-alphanumeric collapsed to underscore: "Employee ID" -> employee_id */
function normalise(s: string): string {
  return s
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}

/**
 * Match a sheet name to a table, allowing the plural/singular slip that
 * spreadsheets always contain ("Employee" vs `employees`).
 */
function matchTable(sheetName: string, knownTables: string[]): string | null {
  const n = normalise(sheetName);
  const candidates = [n, `${n}s`, n.replace(/s$/, '')];
  for (const c of candidates) {
    const hit = knownTables.find((t) => t === c);
    if (hit) return hit;
  }
  return null;
}

/**
 * Find the header row.
 *
 * Real extracts put a title, a date, or a blank line above the headers, so
 * row 0 is not reliable. The header is taken to be the first row that is
 * mostly non-empty text and is followed by a row of similar width — which
 * distinguishes a header from a stray title cell sitting alone above it.
 */
function findHeaderRow(rows: unknown[][]): number {
  for (let i = 0; i < Math.min(rows.length, 20); i++) {
    const row = rows[i] ?? [];
    const filled = row.filter((c) => c !== null && c !== undefined && String(c).trim() !== '');
    if (filled.length < 2) continue;
    const allText = filled.every((c) => typeof c === 'string' || typeof c === 'number');
    const next = rows[i + 1] ?? [];
    const nextFilled = next.filter((c) => c !== null && c !== undefined && String(c).trim() !== '');
    if (allText && nextFilled.length >= Math.ceil(filled.length / 2)) return i;
  }
  return 0;
}

/** Excel serial dates arrive as numbers or Dates; the database wants ISO. */
function normaliseValue(v: unknown): unknown {
  if (v === undefined || v === '') return null;
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  // exceljs returns rich text and formula cells as objects rather than scalars.
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    if (typeof o.text === 'string') return o.text;
    if ('result' in o) return normaliseValue(o.result);
    if (Array.isArray(o.richText)) {
      return (o.richText as { text?: string }[]).map((p) => p.text ?? '').join('');
    }
    return null;
  }
  return v;
}

function buildTable(
  sheetName: string,
  grid: unknown[][],
  knownTables: string[],
  columnsByTable: Record<string, string[]>,
): ParsedTable {
  const headerRowIndex = findHeaderRow(grid);
  const rawHeaders = (grid[headerRowIndex] ?? []).map((h) => String(h ?? '').trim());
  const target = matchTable(sheetName, knownTables);

  const targetColumns = target ? (columnsByTable[target] ?? []) : [];
  const mapped = rawHeaders.map((h) => {
    const n = normalise(h);
    return targetColumns.includes(n) ? n : null;
  });

  const unmappedColumns = rawHeaders.filter((h, i) => h !== '' && mapped[i] === null);

  const rows: Record<string, unknown>[] = [];
  for (let r = headerRowIndex + 1; r < grid.length; r++) {
    const line = grid[r] ?? [];
    if (line.every((c) => c === null || c === undefined || String(c).trim() === '')) continue;

    const row: Record<string, unknown> = {};
    mapped.forEach((col, i) => {
      if (col) row[col] = normaliseValue(line[i]);
    });
    // The file's own line number, 1-based as a spreadsheet shows it, so a
    // validation failure names a row the uploader can actually go and look at.
    row._source_row = r + 1;
    rows.push(row);
  }

  return {
    targetTable: target ?? '',
    headerRowIndex,
    columns: rawHeaders,
    rows,
    sheetName,
    unmappedColumns,
    unrecognised: target === null,
  };
}

/** Minimal RFC-4180 CSV: quoted fields, embedded commas, doubled quotes. */
function parseCsv(text: string): unknown[][] {
  const rows: unknown[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else { quoted = false; }
      } else field += c;
      continue;
    }
    if (c === '"') { quoted = true; continue; }
    if (c === ',') { row.push(field); field = ''; continue; }
    if (c === '\r') continue;
    if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; continue; }
    field += c;
  }
  if (field !== '' || row.length > 0) { row.push(field); rows.push(row); }
  return rows;
}

export class FileAdapter implements SourceAdapter {
  #knownTables: string[];
  #columnsByTable: Record<string, string[]>;

  constructor(knownTables: string[], columnsByTable: Record<string, string[]>) {
    this.#knownTables = knownTables;
    this.#columnsByTable = columnsByTable;
  }

  async parse(source: File | Blob | ArrayBuffer, fileName: string): Promise<RawTable[]> {
    return this.parseDetailed(source, fileName);
  }

  async parseDetailed(
    source: File | Blob | ArrayBuffer,
    fileName: string,
  ): Promise<ParsedTable[]> {
    const buffer =
      source instanceof ArrayBuffer ? source : await (source as Blob).arrayBuffer();

    if (/\.csv$/i.test(fileName)) {
      const grid = parseCsv(new TextDecoder().decode(buffer));
      const sheet = fileName.replace(/\.[^.]+$/, '');
      return [buildTable(sheet, grid, this.#knownTables, this.#columnsByTable)];
    }

    // Loaded on demand: this screen is rarely opened, and the parser is
    // large enough to be worth keeping out of everyone else's bundle.
    const ExcelJS = await import('exceljs');
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buffer);

    const out: ParsedTable[] = [];
    wb.eachSheet((sheet) => {
      const grid: unknown[][] = [];
      sheet.eachRow({ includeEmpty: true }, (row) => {
        const values = row.values as unknown[];
        // exceljs pads index 0; drop it so columns line up with headers.
        grid.push(values.slice(1));
      });
      if (grid.length === 0) return;
      out.push(buildTable(sheet.name, grid, this.#knownTables, this.#columnsByTable));
    });
    return out;
  }
}

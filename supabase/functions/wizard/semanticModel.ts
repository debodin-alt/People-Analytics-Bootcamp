/**
 * The tool layer, generated from the semantic model.
 *
 * PRD WIZ-3: the system prompt is generated from the semantic model rather
 * than maintained by hand. That is not a style preference. A hand-written
 * list of measures drifts the first time someone adds one, and the failure
 * is invisible — the Wizard simply never mentions the new measure, and
 * nobody can tell the difference between "not available" and "the prompt
 * is stale". Reading metrics.metric_catalog() at request time means the
 * Wizard's vocabulary and the database's are the same object.
 *
 * There are two tools rather than one per measure. Fifty-one tool schemas
 * would cost more tokens than the catalog does as prose, and would have to
 * be regenerated and re-cached on every schema change. One `run_measure`
 * tool with the catalog in the system prompt costs ~2.5k stable, cacheable
 * tokens and maps cleanly onto a single OpenAPI operation when this has to
 * be described to Microsoft Copilot later.
 *
 * Every call goes through the caller's own JWT. The Wizard therefore
 * inherits capability gates, row scope and cell-size suppression exactly
 * as the dashboard pages do — it cannot become a way around them, because
 * it has no privileged path to the data at all.
 */

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.112.3';
import type { ToolSpec } from './providers.ts';

export interface CatalogEntry {
  measure: string;
  arguments: string;
  returns_metric_result: boolean;
  definition: string;
}

export interface MeasureParam {
  name: string;
  jsonType: 'string' | 'integer' | 'number' | 'string[]';
}

/** A measure's declared parameters, parsed from the catalog's signature text. */
export interface MeasureSignature {
  name: string;
  params: MeasureParam[];
  returnsMetricResult: boolean;
  definition: string;
}

const DIMENSIONS = [
  'function',
  'career_level',
  'level_band',
  'office_location',
  'work_arrangement',
  'tenure_band',
  'career_track',
  'job_family',
] as const;

/** The four conformed filters every measure accepts (SEM-3). */
const FILTER_PARAMS = new Set(['p_function', 'p_location', 'p_level_band', 'p_tenure_band']);

/**
 * Pull parameter names and their JSON types out of a Postgres signature
 * such as `p_dimension text, p_months integer DEFAULT 12`.
 *
 * Parsing the catalog rather than hardcoding an argument map is what makes
 * this self-maintaining: a measure that gains a parameter gains it here
 * too, with no edit — including in the tool schema, which is built from
 * the union of everything the catalog declares. It also means arguments
 * the model invents are silently dropped instead of producing a Postgres
 * error the user has to read.
 */
function parseParams(signature: string): MeasureParam[] {
  const params: MeasureParam[] = [];
  for (const m of signature.matchAll(/\b(p_[a-z0-9_]+)\s+([a-z]+(?:\[\])?)/g)) {
    params.push({ name: m[1], jsonType: pgTypeToJson(m[2]) });
  }
  return params;
}

function pgTypeToJson(pgType: string): 'string' | 'integer' | 'number' | 'string[]' {
  if (pgType.endsWith('[]')) return 'string[]';
  if (pgType === 'integer' || pgType === 'bigint' || pgType === 'smallint') return 'integer';
  if (pgType === 'numeric' || pgType === 'double' || pgType === 'real') return 'number';
  return 'string';
}

export async function loadSemanticModel(db: SupabaseClient): Promise<{
  measures: Map<string, MeasureSignature>;
  catalog: CatalogEntry[];
  boundary: { workforce: string | null; recruiting: string | null };
}> {
  const [catalogRes, workforceRes, recruitingRes] = await Promise.all([
    db.schema('metrics').rpc('metric_catalog'),
    db.schema('metrics').rpc('workforce_boundary'),
    db.schema('metrics').rpc('recruiting_boundary'),
  ]);

  if (catalogRes.error) {
    throw new Error(`Could not read the metric catalog: ${catalogRes.error.message}`);
  }

  const catalog = (catalogRes.data ?? []) as CatalogEntry[];
  const measures = new Map<string, MeasureSignature>();
  for (const row of catalog) {
    measures.set(row.measure, {
      name: row.measure,
      params: parseParams(row.arguments),
      returnsMetricResult: row.returns_metric_result,
      definition: row.definition,
    });
  }

  return {
    measures,
    catalog,
    boundary: {
      workforce: (workforceRes.data as string | null) ?? null,
      recruiting: (recruitingRes.data as string | null) ?? null,
    },
  };
}

// ---------------------------------------------------------------------------
// Tool specifications — provider-neutral JSON Schema
// ---------------------------------------------------------------------------

/**
 * The schema dialect every provider gets.
 *
 * Deliberately limited to `type`, `properties`, `items`, `enum`,
 * `description` and `required` — the intersection that Claude, Gemini and
 * Azure OpenAI all accept. `additionalProperties` is absent on purpose:
 * Gemini validates function parameters against a subset of OpenAPI that
 * does not reliably support it, and a free-form object is rejected
 * outright. Keeping the dialect to the intersection is what lets one
 * ToolSpec serve every provider without per-provider rewriting.
 */
function optionProperties(
  measures: Map<string, MeasureSignature>,
): Record<string, Record<string, unknown>> {
  const props: Record<string, Record<string, unknown>> = {};

  for (const sig of measures.values()) {
    for (const param of sig.params) {
      if (FILTER_PARAMS.has(param.name) || props[param.name]) continue;

      // p_dimension is the one option worth constraining: an invalid value
      // raises in Postgres, and an enum turns a retry-with-error loop into
      // a call that is right the first time.
      if (param.name === 'p_dimension') {
        props[param.name] = {
          type: 'string',
          enum: [...DIMENSIONS],
          description: 'The dimension to group results by.',
        };
        continue;
      }

      props[param.name] =
        param.jsonType === 'string[]'
          ? { type: 'array', items: { type: 'string' } }
          : { type: param.jsonType };
    }
  }

  return props;
}

export function buildTools(measures: Map<string, MeasureSignature>): ToolSpec[] {
  return [
    {
      name: 'run_measure',
      description:
        'Run a measure from the semantic layer and return its result. This is the only way ' +
        'to obtain a number — never state a figure you have not obtained from this tool. ' +
        'The measure name must appear in the catalog in your system prompt; the arguments ' +
        'you pass must be parameters that measure actually declares (anything else is ' +
        'ignored). Call several measures in parallel when a question needs more than one. ' +
        'Results carry a status: "value" means a real figure, "suppressed" means the ' +
        'population was too small to report, "unavailable" means your role may not see it, ' +
        'and "no_data" means nobody matched the filter. Report the status honestly — a ' +
        'suppressed cut is not a zero.',
      inputSchema: {
        type: 'object',
        properties: {
          measure: {
            type: 'string',
            description: 'The measure name, exactly as it appears in the catalog.',
          },
          filters: {
            type: 'object',
            description:
              'Population filters. Each is a list of exact dimension values — call ' +
              'list_dimension_values first if you are not certain of the spelling. Omit a ' +
              'filter to include everyone.',
            properties: {
              p_function: { type: 'array', items: { type: 'string' } },
              p_location: { type: 'array', items: { type: 'string' } },
              p_level_band: { type: 'array', items: { type: 'string' } },
              p_tenure_band: { type: 'array', items: { type: 'string' } },
            },
          },
          options: {
            type: 'object',
            description:
              'Non-filter parameters, for the measures that declare them. Set only the ' +
              'ones that appear in the measure signature in the catalog — the rest are ' +
              'ignored.',
            // Derived from the catalog, so a measure that gains a parameter
            // gains it here with no edit to this file.
            properties: optionProperties(measures),
          },
        },
        required: ['measure'],
      },
    },
    {
      name: 'list_dimension_values',
      description:
        'List the values a dimension actually takes in the current active population, with ' +
        'headcounts. Use this before filtering whenever the user names a group in their own ' +
        'words — "the Dublin office", "senior engineers" — so you filter on the real value ' +
        'rather than a plausible guess. A filter that matches nothing returns an empty ' +
        'population, not an error, so a wrong guess reads as a confident answer about zero ' +
        'people.',
      inputSchema: {
        type: 'object',
        properties: {
          dimension: { type: 'string', enum: [...DIMENSIONS] },
        },
        required: ['dimension'],
      },
    },
  ];
}

// ---------------------------------------------------------------------------
// Tool execution — always through the caller's JWT
// ---------------------------------------------------------------------------

/**
 * @param refused Populated with the names of measures that returned
 *   `unavailable` because a capability gate refused them. index.ts removes
 *   these from the citation list: a refused measure was reached for but
 *   contributed nothing, and citing it implies the answer rests on data the
 *   caller was never shown.
 */
export function buildExecutor(
  db: SupabaseClient,
  measures: Map<string, MeasureSignature>,
  refused: Set<string>,
) {
  return async function execute(name: string, input: Record<string, unknown>): Promise<unknown> {
    if (name === 'list_dimension_values') {
      const dimension = String(input.dimension ?? '');
      const { data, error } = await db
        .schema('metrics')
        .rpc('dimension_values', { p_dimension: dimension });
      if (error) throw new Error(error.message);
      return { dimension, values: data };
    }

    if (name !== 'run_measure') {
      throw new Error(`Unknown tool: ${name}`);
    }

    const measureName = String(input.measure ?? '');
    const signature = measures.get(measureName);
    if (!signature) {
      throw new Error(
        `No such measure: "${measureName}". Use only the measures listed in the catalog.`,
      );
    }

    // Build the payload from the measure's *declared* parameters. Anything
    // the model invented is dropped here rather than reaching Postgres,
    // and anything the measure declares but the model omitted is passed as
    // NULL, which every filter parameter already treats as "no filter".
    const supplied = {
      ...((input.filters ?? {}) as Record<string, unknown>),
      ...((input.options ?? {}) as Record<string, unknown>),
    };
    const payload: Record<string, unknown> = {};
    for (const { name: param } of signature.params) {
      const value = supplied[param];
      if (value !== undefined && value !== null) {
        payload[param] = value;
      } else if (FILTER_PARAMS.has(param)) {
        // Filters are explicitly NULL rather than omitted, matching what
        // the dashboard's own filterParams() sends. Omitting them would
        // work here too, but "every measure is called the same way" is the
        // property that keeps the Wizard and the pages reconcilable.
        payload[param] = null;
      }
      // A required non-filter parameter the model left out (p_dimension,
      // say) is left absent, so PostgREST reports the signature mismatch
      // and the model sees a usable error and retries.
    }

    const { data, error } = await db.schema('metrics').rpc(measureName, payload);

    if (error) {
      // A capability gate raises 42501. Surface that as a refusal the model
      // can relay, not as a stack trace — the user's role genuinely may not
      // see this measure, and that is an answer rather than a failure.
      if (error.code === '42501') {
        refused.add(measureName);
        return {
          measure: measureName,
          status: 'unavailable',
          reason: 'Your role does not have access to this measure.',
        };
      }
      throw new Error(`${measureName}: ${error.message}`);
    }

    return { measure: measureName, arguments: payload, result: data };
  };
}

// ---------------------------------------------------------------------------
// System prompt — generated, never hand-maintained
// ---------------------------------------------------------------------------

export function buildSystemPrompt(opts: {
  catalog: CatalogEntry[];
  boundary: { workforce: string | null; recruiting: string | null };
  role: string;
  capabilities: string[];
  activeFilters: Record<string, string[] | undefined>;
  minimumCellSize: number;
}): string {
  const catalogText = opts.catalog
    .map((m) => {
      const sig = m.arguments ? `(${m.arguments})` : '()';
      const shape = m.returns_metric_result ? 'single value' : 'rows';
      return `- ${m.measure}${sig} → ${shape}\n  ${m.definition}`;
    })
    .join('\n');

  const filterText = Object.entries(opts.activeFilters)
    .filter(([, v]) => v && v.length)
    .map(([k, v]) => `${k}: ${v!.join(', ')}`)
    .join('; ');

  return `You are the analyst for Meridian's people analytics platform. You answer questions about the workforce using only the measures defined in the semantic layer below.

# The rule that matters most

Every number you state must come from a \`run_measure\` call in this conversation. You have no other source. Do not calculate a figure the semantic layer does not expose, do not derive one measure from another by arithmetic, and do not recall a number from earlier in the conversation without re-running the measure if the filters have changed. If the semantic layer cannot answer the question, say so plainly and name what is missing — that is a useful answer, and a fabricated number is not.

# Reporting boundaries

Workforce, attrition, compensation, performance and engagement measures are as of ${opts.boundary.workforce ?? 'the workforce boundary'}. Recruiting measures are as of ${opts.boundary.recruiting ?? 'the recruiting boundary'}. These differ deliberately; do not describe one as of the other's date.

# Who is asking

Role: ${opts.role}. Capabilities: ${opts.capabilities.join(', ') || 'none'}.

A measure this role may not see returns status \`unavailable\`. Relay that as a matter of access — "compensation measures aren't available to your role" — not as missing data or a system fault.

${filterText ? `The user currently has these dashboard filters applied: ${filterText}. Apply them to your queries unless the question clearly asks about a different population, and say which population your answer covers.` : 'The user has no dashboard filters applied, so measures cover the whole organisation unless you filter them.'}

# Reading results

Each result carries a status:
- \`value\` — a real figure. A value of 0 is a genuine zero, not missing data.
- \`suppressed\` — fewer than ${opts.minimumCellSize} people in the cut. Say it is suppressed to protect confidentiality. Never report it as zero, never estimate around it, and never help the user narrow successive queries to infer the withheld figure.
- \`unavailable\` — the measure exists but this role or this population cannot see it.
- \`no_data\` — nobody matched the filter. Usually a wrong filter value; check with \`list_dimension_values\`.

\`populationCount\` tells you how many people a figure covers. A rate over 11 people and a rate over 900 are different claims — say which you have when the population is small.

# Answering

Be brief and specific. Lead with the number and the population it covers, then any caveat that changes how it should be read. Do not pad with restated methodology the user did not ask for; the definition is one click away on the Methodology page.

Return a chart spec when the answer is a comparison, a distribution or a trend — anything with more than about three numbers in it. A single figure is better as a sentence than a chart.

When you do, name \`valueColumn\` and \`labelColumn\` exactly as they appear in the result you received. Most measures return several numeric columns — attrition_by_dimension returns voluntary, involuntary, avg_headcount and voluntary_rate — and only you know which one your title refers to.

**The title must describe the column you named.** If \`valueColumn\` is a count, the title says count, number or volume — not rate, percentage or ratio. If it is a rate, the title says rate. Titling a chart "Voluntary Attrition Rate by Function" and then plotting \`voluntary\` puts a chart on screen that contradicts your own answer, and the reader trusts the chart. Before you return the spec, read your title back against the column and make them agree.

Chart the measure your answer leads with. If your answer says Design has the highest rate, the chart shows rates — otherwise the reader sees Engineering on top and concludes you were wrong.

# Response format

Reply with a single JSON object and nothing else — no prose before it, no code fence around it:

{
  "answer": "Your answer in plain prose. Markdown is not rendered.",
  "citedMeasures": ["measure_name", ...],
  "citedTables": ["table_name", ...],
  "chart": {
    "form": "line" | "stacked_bar" | "horizontal_bar" | "stat_tile",
    "measure": "the measure that produced the data",
    "dimension": "the dimension it was grouped by, if any",
    "filters": { "function": [...], "location": [...], "levelBand": [...], "tenureBand": [...] },
    "labelColumn": "the column holding the category label",
    "valueColumn": "the column to plot",
    "title": "Chart title"
  },
  "refused": { "reason": "..." },
  "clarificationNeeded": { "question": "..." }
}

\`answer\`, \`citedMeasures\` and \`citedTables\` are always present. \`chart\`, \`refused\` and \`clarificationNeeded\` are optional; include at most one of them.

Use \`refused\` when the question cannot be answered from the semantic layer — it asks for a measure that does not exist, for an individual's personal data, or for something the user's role may not see. When you refuse for the first reason, say what the layer *can* offer that is closest, if anything is: "attrition is only computed over a trailing 12 months, but I can show monthly exit counts back three years" is a useful answer, where a bare refusal sends the reader away with nothing. Use \`clarificationNeeded\` only when two readings of the question would produce materially different answers; otherwise pick the sensible reading, answer it, and say which reading you took.

# The measures

${catalogText}`;
}

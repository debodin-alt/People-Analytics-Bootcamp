/** Distinct dimension values, verified against the Meridian source files directly. */

export const FUNCTIONS = [
  'Engineering',
  'Product',
  'Sales',
  'Marketing',
  'Customer Success',
  'Data & Analytics',
  'Design',
  'Finance',
  'Legal',
  'People',
  'Workplace',
  'IT',
  'Other G&A',
  'Executive',
] as const;

export const OFFICE_LOCATIONS = ['Boston', 'Denver', 'Dublin', 'Toronto', 'Remote-US'] as const;

export const TENURE_BANDS = ['<1 year', '1-3 years', '3-5 years', '5-8 years', '8+ years'] as const;

export const LEVEL_BANDS = [
  'Entry / Mid IC',
  'Senior IC',
  'Staff+ IC',
  'First-Line Manager',
  'Sr Manager',
  'Director',
  'VP+',
] as const;

export const CAREER_LEVELS = ['P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'M3', 'M4', 'M5', 'M6', 'M7', 'M8'] as const;

/** The minimum cell size below which any demographic or manager-level cut is suppressed (SEM-9, NFR-5). */
export const MINIMUM_CELL_SIZE = 5;

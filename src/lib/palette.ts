/**
 * Validated palette — PRD_Class2 §10.10. Slots are assigned in fixed order,
 * never cycled. Color follows the entity so cross-filtering never repaints
 * the survivors.
 */

export const paletteLight = {
  surface: '#FFFFFF',
  pagePlane: '#F4F6F8',
  gridline: '#E1E0D9',
  ink: '#1A1F2B',
  inkMuted: '#5B6472',
  series: ['#2A6FA8', '#E07B1F', '#2DA67A', '#EDA100', '#E87BA4', '#008300', '#4A3AA7', '#E34948'],
} as const;

export const paletteDark = {
  surface: '#1A1F2B',
  pagePlane: '#1A1F2B',
  gridline: '#2C2C2A',
  ink: '#EEF1F5',
  inkMuted: '#A7B0BD',
  series: ['#3987E5', '#D95926', '#199E70', '#C98500', '#D55181', '#008300', '#9085E9', '#E66767'],
} as const;

export const statusColors = {
  good: '#0CA30C',
  warning: '#FAB219',
  serious: '#EC835A',
  critical: '#D03B3B',
} as const;

/** Slots 1-3 only — the cap for scatter and small-multiple forms (§10.10). */
export function seriesColors(mode: 'light' | 'dark', count: number): string[] {
  const palette = mode === 'dark' ? paletteDark : paletteLight;
  return palette.series.slice(0, count);
}

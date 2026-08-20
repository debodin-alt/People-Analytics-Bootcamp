import { NavLink, Outlet, useLocation } from 'react-router-dom';
import { useTheme } from '../../context/ThemeContext';
import { useFilters } from '../../context/FilterContext';
import { FUNCTIONS, OFFICE_LOCATIONS, LEVEL_BANDS, TENURE_BANDS } from '../../lib/constants';
import { useDataFreshness } from '../../lib/useDataFreshness';
import { useSession, type Capability } from '../../context/SessionContext';

// `requires` mirrors the route guards in App.tsx. Hiding a nav item is
// presentation only — the measures behind each page refuse server-side
// regardless of what is rendered here.
const NAV_ITEMS: { to: string; label: string; requires?: Capability }[] = [
  { to: '/', label: 'Executive Overview' },
  { to: '/workforce', label: 'Workforce', requires: 'dimension_cuts' },
  { to: '/attrition', label: 'Attrition & Retention', requires: 'dimension_cuts' },
  { to: '/compensation', label: 'Compensation', requires: 'compensation' },
  { to: '/recruiting', label: 'Recruiting', requires: 'dimension_cuts' },
  { to: '/engagement', label: 'Engagement', requires: 'dimension_cuts' },
  { to: '/talent', label: 'Talent & Performance', requires: 'dimension_cuts' },
  { to: '/wizard', label: 'Wizard' },
  { to: '/methodology', label: 'Methodology' },
  { to: '/admin/upload', label: 'Admin: Data Upload', requires: 'governance' },
];

function pageTitleFor(pathname: string): string {
  const match = NAV_ITEMS.find((item) => item.to === pathname);
  if (match) return match.label;
  if (pathname.startsWith('/employees/')) return 'Employee 360';
  if (pathname.startsWith('/managers/')) return 'Manager View';
  return 'Meridian People Analytics';
}

export function AppShell() {
  const { theme, toggle } = useTheme();
  const { filters, setFunction, setLocation, setLevelBand, setTenureBand, setComparison, clearAll } = useFilters();
  const location = useLocation();
  const freshness = useDataFreshness();
  const { role, employeeId, can, signOut } = useSession();
  const visibleNav = NAV_ITEMS.filter((item) => !item.requires || can(item.requires));

  const toggleListValue = (
    current: string[] | undefined,
    value: string,
    setter: (v: string[]) => void,
  ) => {
    const set = new Set(current ?? []);
    if (set.has(value)) set.delete(value);
    else set.add(value);
    setter([...set]);
  };

  const hasActiveFilters =
    (filters.function?.length ?? 0) > 0 ||
    (filters.location?.length ?? 0) > 0 ||
    (filters.levelBand?.length ?? 0) > 0 ||
    (filters.tenureBand?.length ?? 0) > 0;

  return (
    <div className="app-shell">
      <nav className="app-nav">
        <div className="brand">Meridian</div>
        {visibleNav.map((item) => (
          <NavLink key={item.to} to={item.to} className={({ isActive }) => (isActive ? 'active' : '')} end={item.to === '/'}>
            {item.label}
          </NavLink>
        ))}
      </nav>

      <header className="app-header">
        <div className="page-title">{pageTitleFor(location.pathname)}</div>
        <div className="header-right">
          <span>
            {freshness.status === 'loading' && 'Loading data freshness…'}
            {freshness.status === 'no_data' && 'No data loaded yet'}
            {freshness.status === 'ready' && `As of ${freshness.asOf} · ${freshness.dataLoadId}`}
            {freshness.status === 'error' && 'Data freshness unavailable'}
          </span>
          <span title={employeeId ? `Linked to ${employeeId}` : 'Not linked to an employee record'}>
            Signed in as <strong style={{ color: 'var(--ink)' }}>{role}</strong>
          </span>
          <button onClick={toggle} aria-label="Toggle theme" style={{ background: 'none', border: '1px solid var(--border)', borderRadius: 6, padding: '4px 8px', cursor: 'pointer' }}>
            {theme === 'dark' ? '☾' : '☀'}
          </button>
          <button
            onClick={signOut}
            style={{ background: 'none', border: '1px solid var(--border)', borderRadius: 6, padding: '4px 8px', cursor: 'pointer', fontSize: 12 }}
          >
            Sign out
          </button>
        </div>
      </header>

      <div className="filter-bar">
        <MultiSelect label="Function" options={[...FUNCTIONS]} selected={filters.function ?? []} onToggle={(v) => toggleListValue(filters.function, v, setFunction)} />
        <MultiSelect label="Location" options={[...OFFICE_LOCATIONS]} selected={filters.location ?? []} onToggle={(v) => toggleListValue(filters.location, v, setLocation)} />
        <MultiSelect label="Level band" options={[...LEVEL_BANDS]} selected={filters.levelBand ?? []} onToggle={(v) => toggleListValue(filters.levelBand, v, setLevelBand)} />
        <MultiSelect label="Tenure band" options={[...TENURE_BANDS]} selected={filters.tenureBand ?? []} onToggle={(v) => toggleListValue(filters.tenureBand, v, setTenureBand)} />
        <select value={filters.comparison ?? 'none'} onChange={(e) => setComparison(e.target.value as never)}>
          <option value="none">No comparison</option>
          <option value="prior_period">vs prior period</option>
          <option value="same_period_last_year">vs same period last year</option>
        </select>
        {hasActiveFilters && (
          <button className="clear-link" onClick={clearAll}>
            Clear all filters
          </button>
        )}
      </div>

      <main className="app-main">
        <Outlet />
      </main>
    </div>
  );
}

function MultiSelect({
  label,
  options,
  selected,
  onToggle,
}: {
  label: string;
  options: string[];
  selected: string[];
  onToggle: (value: string) => void;
}) {
  return (
    <details style={{ position: 'relative' }}>
      <summary
        style={{
          listStyle: 'none',
          cursor: 'pointer',
          border: '1px solid var(--border)',
          borderRadius: 6,
          padding: '5px 8px',
          fontSize: 12,
          background: 'var(--surface)',
        }}
      >
        {label}
        {selected.length > 0 ? ` (${selected.length})` : ''}
      </summary>
      <div
        style={{
          position: 'absolute',
          top: '110%',
          left: 0,
          zIndex: 10,
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 8,
          padding: 8,
          minWidth: 180,
          maxHeight: 240,
          overflowY: 'auto',
          boxShadow: '0 8px 20px rgba(0,0,0,0.12)',
        }}
      >
        {options.map((opt) => (
          <label key={opt} style={{ display: 'flex', gap: 6, alignItems: 'center', fontSize: 12, padding: '3px 0' }}>
            <input type="checkbox" checked={selected.includes(opt)} onChange={() => onToggle(opt)} />
            {opt}
          </label>
        ))}
      </div>
    </details>
  );
}

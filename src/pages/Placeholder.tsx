export function Placeholder({ title, note }: { title: string; note?: string }) {
  return (
    <div style={{ padding: 40, textAlign: 'center', color: 'var(--ink-muted)' }}>
      <h2 style={{ color: 'var(--ink)', marginBottom: 8 }}>{title}</h2>
      <p>{note ?? 'Not built yet.'}</p>
    </div>
  );
}

import { useSession } from '../context/SessionContext';

/**
 * Shown to a user who authenticated successfully but has no app_users
 * row. Authentication and authorisation are separate: proving who you are
 * does not entitle you to anything until an administrator maps the
 * account to a role.
 */
export function NoAccess() {
  const { session, signOut } = useSession();
  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: 'var(--page-plane)',
        padding: 20,
      }}
    >
      <div
        style={{
          maxWidth: 460,
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 12,
          padding: 28,
        }}
      >
        <h1 style={{ fontSize: 16, margin: '0 0 10px' }}>Account not yet granted access</h1>
        <p style={{ fontSize: 13, color: 'var(--ink-muted)', lineHeight: 1.6, margin: '0 0 10px' }}>
          You are signed in as <strong>{session?.user?.email}</strong>, but this account has not been assigned a role in
          the platform, so it can read no data.
        </p>
        <p style={{ fontSize: 13, color: 'var(--ink-muted)', lineHeight: 1.6, margin: '0 0 18px' }}>
          An administrator needs to map the account to an employee record and a role.
        </p>
        <button
          onClick={signOut}
          style={{
            padding: '8px 14px',
            border: '1px solid var(--border)',
            borderRadius: 7,
            background: 'transparent',
            cursor: 'pointer',
            fontSize: 13,
          }}
        >
          Sign out
        </button>
      </div>
    </div>
  );
}

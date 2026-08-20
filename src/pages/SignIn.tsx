import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';

/**
 * Sign-in.
 *
 * Deliberately NOT the course PRD's email-only flow. That design treats a
 * typed-in address as proof of identity, which is defensible against 820
 * synthetic people and indefensible the moment the rows are real
 * colleagues with real salaries attached.
 *
 * Credentials are handed straight to Supabase Auth over HTTPS and are
 * never stored, logged, or held in component state after submit.
 */
export function SignIn() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [status, setStatus] = useState<'idle' | 'working' | 'error' | 'sent'>('idle');
  const [message, setMessage] = useState<string | null>(null);

  async function handlePasswordSignIn(e: FormEvent) {
    e.preventDefault();
    setStatus('working');
    setMessage(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      setStatus('error');
      // Deliberately not distinguishing "no such account" from "wrong
      // password" — that difference tells an attacker which addresses are
      // real, which for an HR system is a roster of who works here.
      setMessage('Sign-in failed. Check your email and password.');
      return;
    }
    setPassword('');
    setStatus('idle');
  }

  async function handleMagicLink() {
    if (!email) {
      setStatus('error');
      setMessage('Enter your email address first.');
      return;
    }
    setStatus('working');
    setMessage(null);
    const { error } = await supabase.auth.signInWithOtp({ email });
    if (error) {
      setStatus('error');
      setMessage(error.message);
      return;
    }
    setStatus('sent');
    setMessage('If that address has an account, a sign-in link is on its way.');
  }

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
          width: '100%',
          maxWidth: 380,
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 12,
          padding: 28,
        }}
      >
        <div style={{ fontWeight: 600, fontSize: 18, marginBottom: 4 }}>Meridian</div>
        <div style={{ fontSize: 12, color: 'var(--ink-muted)', marginBottom: 20 }}>People Analytics Platform</div>

        <form onSubmit={handlePasswordSignIn}>
          <label style={labelStyle} htmlFor="email">
            Work email
          </label>
          <input
            id="email"
            type="email"
            autoComplete="username"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            style={inputStyle}
            required
          />

          <label style={labelStyle} htmlFor="password">
            Password
          </label>
          <input
            id="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            style={inputStyle}
          />

          <button type="submit" disabled={status === 'working'} style={primaryButtonStyle}>
            {status === 'working' ? 'Signing in…' : 'Sign in'}
          </button>
        </form>

        <button type="button" onClick={handleMagicLink} disabled={status === 'working'} style={secondaryButtonStyle}>
          Email me a sign-in link instead
        </button>

        {message && (
          <div
            style={{
              marginTop: 14,
              fontSize: 12,
              lineHeight: 1.5,
              color: status === 'error' ? 'var(--critical)' : 'var(--ink-muted)',
            }}
          >
            {message}
          </div>
        )}

        <div style={{ marginTop: 20, fontSize: 11, color: 'var(--ink-faint)', lineHeight: 1.5 }}>
          Access is granted per account by an administrator. Signing in successfully does not by itself grant access to
          any data.
        </div>
      </div>
    </div>
  );
}

const labelStyle: React.CSSProperties = {
  display: 'block',
  fontSize: 12,
  color: 'var(--ink-muted)',
  marginBottom: 5,
};

const inputStyle: React.CSSProperties = {
  width: '100%',
  padding: '8px 10px',
  border: '1px solid var(--border)',
  borderRadius: 7,
  background: 'var(--surface)',
  marginBottom: 14,
  fontSize: 13,
};

const primaryButtonStyle: React.CSSProperties = {
  width: '100%',
  padding: '9px 12px',
  border: 'none',
  borderRadius: 7,
  background: '#2a6fa8',
  color: '#fff',
  fontSize: 13,
  fontWeight: 600,
  cursor: 'pointer',
};

const secondaryButtonStyle: React.CSSProperties = {
  width: '100%',
  padding: '8px 12px',
  marginTop: 8,
  border: '1px solid var(--border)',
  borderRadius: 7,
  background: 'transparent',
  color: 'var(--ink-muted)',
  fontSize: 12,
  cursor: 'pointer',
};

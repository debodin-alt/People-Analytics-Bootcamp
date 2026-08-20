import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';

export type AppRole = 'admin' | 'executive' | 'manager' | 'viewer';
export type Capability =
  | 'company_aggregates'
  | 'dimension_cuts'
  | 'compensation'
  | 'sensitive_attributes'
  | 'individual_detail'
  | 'governance';

interface SessionContextValue {
  /** Supabase auth session, or null when signed out. */
  session: Session | null;
  /** App role from app_users, or null when the account has no mapping yet. */
  role: AppRole | null;
  employeeId: string | null;
  capabilities: Capability[];
  /** True until both the auth session and the role mapping have resolved. */
  loading: boolean;
  can: (capability: Capability) => boolean;
  signOut: () => Promise<void>;
}

const Ctx = createContext<SessionContextValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [authResolved, setAuthResolved] = useState(false);
  const [role, setRole] = useState<AppRole | null>(null);
  const [employeeId, setEmployeeId] = useState<string | null>(null);
  const [capabilities, setCapabilities] = useState<Capability[]>([]);
  const [contextResolved, setContextResolved] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setAuthResolved(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
      setAuthResolved(true);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  // The role is read from the database, never from the JWT or from local
  // state the client could set. An authenticated user with no app_users
  // row gets no capabilities — absence is denial, not a default role.
  useEffect(() => {
    let cancelled = false;
    if (!session) {
      setRole(null);
      setEmployeeId(null);
      setCapabilities([]);
      setContextResolved(authResolved);
      return;
    }
    setContextResolved(false);
    supabase
      .schema('metrics')
      .rpc('current_session_context')
      .then(({ data, error }) => {
        if (cancelled) return;
        const row = Array.isArray(data) ? data[0] : data;
        if (error || !row) {
          setRole(null);
          setEmployeeId(null);
          setCapabilities([]);
        } else {
          setRole((row.app_role as AppRole) ?? null);
          setEmployeeId((row.employee_id as string) ?? null);
          setCapabilities((row.capabilities as Capability[]) ?? []);
        }
        setContextResolved(true);
      });
    return () => {
      cancelled = true;
    };
  }, [session, authResolved]);

  const value = useMemo<SessionContextValue>(
    () => ({
      session,
      role,
      employeeId,
      capabilities,
      loading: !authResolved || !contextResolved,
      can: (capability) => capabilities.includes(capability),
      signOut: async () => {
        await supabase.auth.signOut();
      },
    }),
    [session, role, employeeId, capabilities, authResolved, contextResolved],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useSession() {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useSession must be used within SessionProvider');
  return ctx;
}

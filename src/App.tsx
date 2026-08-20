import { Navigate, Route, Routes } from 'react-router-dom';
import { AppShell } from './components/shell/AppShell';
import { useSession, type Capability } from './context/SessionContext';
import { SignIn } from './pages/SignIn';
import { NoAccess } from './pages/NoAccess';
import { ExecutiveOverview } from './pages/ExecutiveOverview';
import { Workforce } from './pages/Workforce';
import { Attrition } from './pages/Attrition';
import { Compensation } from './pages/Compensation';
import { Recruiting } from './pages/Recruiting';
import { Engagement } from './pages/Engagement';
import { Talent } from './pages/Talent';
import { Wizard } from './pages/Wizard';
import { Methodology } from './pages/Methodology';
import { AdminUpload } from './pages/AdminUpload';
import { EmployeeDetail } from './pages/EmployeeDetail';
import { ManagerView } from './pages/ManagerView';

/**
 * Route-level capability gate. This is convenience and clarity — it keeps
 * a user from landing on a page of refusals. It is NOT the security
 * control: the measures themselves refuse, server-side, regardless of
 * what the client renders.
 */
function RequireCapability({ capability, children }: { capability: Capability; children: React.ReactNode }) {
  const { can } = useSession();
  return can(capability) ? <>{children}</> : <Navigate to="/" replace />;
}

export function App() {
  const { session, role, loading } = useSession();

  if (loading) {
    return (
      <div
        style={{
          minHeight: '100vh',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: 'var(--ink-faint)',
          fontSize: 13,
        }}
      >
        Loading…
      </div>
    );
  }

  if (!session) return <SignIn />;
  if (!role) return <NoAccess />;

  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<ExecutiveOverview />} />
        <Route
          path="workforce"
          element={
            <RequireCapability capability="dimension_cuts">
              <Workforce />
            </RequireCapability>
          }
        />
        <Route
          path="attrition"
          element={
            <RequireCapability capability="dimension_cuts">
              <Attrition />
            </RequireCapability>
          }
        />
        <Route
          path="compensation"
          element={
            <RequireCapability capability="compensation">
              <Compensation />
            </RequireCapability>
          }
        />
        <Route
          path="recruiting"
          element={
            <RequireCapability capability="dimension_cuts">
              <Recruiting />
            </RequireCapability>
          }
        />
        <Route
          path="engagement"
          element={
            <RequireCapability capability="dimension_cuts">
              <Engagement />
            </RequireCapability>
          }
        />
        <Route
          path="talent"
          element={
            <RequireCapability capability="dimension_cuts">
              <Talent />
            </RequireCapability>
          }
        />
        <Route path="wizard" element={<Wizard />} />
        <Route path="methodology" element={<Methodology />} />
        <Route
          path="admin/upload"
          element={
            <RequireCapability capability="governance">
              <AdminUpload />
            </RequireCapability>
          }
        />
        <Route
          path="employees/:employeeId"
          element={
            <RequireCapability capability="individual_detail">
              <EmployeeDetail />
            </RequireCapability>
          }
        />
        <Route
          path="managers/:managerId"
          element={
            <RequireCapability capability="individual_detail">
              <ManagerView />
            </RequireCapability>
          }
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

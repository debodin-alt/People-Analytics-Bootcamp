import { Route, Routes } from 'react-router-dom';
import { AppShell } from './components/shell/AppShell';
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

export function App() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<ExecutiveOverview />} />
        <Route path="workforce" element={<Workforce />} />
        <Route path="attrition" element={<Attrition />} />
        <Route path="compensation" element={<Compensation />} />
        <Route path="recruiting" element={<Recruiting />} />
        <Route path="engagement" element={<Engagement />} />
        <Route path="talent" element={<Talent />} />
        <Route path="wizard" element={<Wizard />} />
        <Route path="methodology" element={<Methodology />} />
        <Route path="admin/upload" element={<AdminUpload />} />
        <Route path="employees/:employeeId" element={<EmployeeDetail />} />
        <Route path="managers/:managerId" element={<ManagerView />} />
      </Route>
    </Routes>
  );
}

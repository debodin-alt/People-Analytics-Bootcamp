import { useParams } from 'react-router-dom';
import { Placeholder } from './Placeholder';

export function EmployeeDetail() {
  const { employeeId } = useParams();
  return <Placeholder title="Employee 360" note={`${employeeId} — Day 3 scope in the PRD.`} />;
}

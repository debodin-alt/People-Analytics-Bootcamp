import { useParams } from 'react-router-dom';
import { Placeholder } from './Placeholder';

export function ManagerView() {
  const { managerId } = useParams();
  return <Placeholder title="Manager View" note={`${managerId} — Day 3 scope in the PRD.`} />;
}

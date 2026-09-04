import { Forkop } from '../../../types';

export function getOutboundFooterLabel(outbound: Forkop.Outbound) {
  return (
    outbound.urlTestInfo?.selectedName ||
    outbound.priorityInfo?.selectedName ||
    outbound.description ||
    outbound.type
  );
}

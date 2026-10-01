export type RestartConflictObservation = {
  since: number;
  lastSeen: number;
  samples: number;
  confirmed: boolean;
};

// Confirm only consecutive idle observations. A transition or a polling gap
// starts a new observation period; the backend restart guard stays immediate.
export function observeRestartConflict(
  previous: RestartConflictObservation | undefined,
  blocked: boolean,
  transitioning: boolean,
  now: number,
): RestartConflictObservation | undefined {
  if (!blocked || transitioning) return undefined;
  if (!previous || now < previous.lastSeen || now - previous.lastSeen > 15000)
    return { since: now, lastSeen: now, samples: 1, confirmed: false };
  const samples = previous.samples + (now > previous.lastSeen ? 1 : 0);
  return {
    since: previous.since,
    lastSeen: now,
    samples,
    confirmed: samples >= 2 && now - previous.since >= 5000,
  };
}

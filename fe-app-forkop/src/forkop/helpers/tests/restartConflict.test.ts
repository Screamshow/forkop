import { describe, expect, it } from 'vitest';
import { observeRestartConflict } from '../restartConflict';

describe('restart conflict warning', () => {
  it('requires repeated idle observations over five seconds', () => {
    const first = observeRestartConflict(undefined, true, false, 1000);
    expect(first?.confirmed).toBe(false);
    expect(observeRestartConflict(first, true, false, 2000)?.confirmed).toBe(
      false,
    );
    expect(observeRestartConflict(first, true, false, 6000)?.confirmed).toBe(
      true,
    );
  });
  it('resets on transition or recovery', () => {
    const first = observeRestartConflict(undefined, true, false, 1000);
    expect(observeRestartConflict(first, true, true, 6000)).toBeUndefined();
    expect(observeRestartConflict(first, false, false, 6000)).toBeUndefined();
  });
  it('does not confirm after a polling gap or a repeated render', () => {
    const first = observeRestartConflict(undefined, true, false, 1000);
    expect(observeRestartConflict(first, true, false, 20000)?.confirmed).toBe(
      false,
    );
    expect(observeRestartConflict(first, true, false, 1000)?.samples).toBe(1);
  });
});

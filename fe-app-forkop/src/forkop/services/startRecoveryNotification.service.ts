import { ForkopLogNotification } from './logNotificationDeduper.service';

type NotificationEmitter = (notification: ForkopLogNotification) => void;

export function isRecoverableStartFailureLog(line: string) {
  const lower = line.toLowerCase();
  return (
    lower.includes('controlled sing-box transition refused:') ||
    lower.includes('sing-box did not reach a stable running state after start')
  );
}

function isRetryScheduledLog(line: string) {
  return line.includes('Forkop start failed; scheduled an automatic retry');
}

function isRecoverySucceededLog(line: string) {
  return line.includes('Forkop recovered automatically after a failed start');
}

function isRecoveryFailedLog(line: string) {
  return (
    line.includes('Forkop automatic recovery attempt failed') ||
    line.includes('Forkop startup retry suppressed')
  );
}

// Startup failures that are followed by Forkop's own retry are not final
// failures. Hold their red toast briefly: the next log line either schedules
// recovery (show a warning instead) or leaves the original fatal visible.
export class StartRecoveryNotificationController {
  private pendingFailure?: ForkopLogNotification;

  constructor(private readonly emit: NotificationEmitter) {}

  handle(line: string) {
    if (isRecoverableStartFailureLog(line)) {
      this.pendingFailure ||= { kind: 'error', line };
      return true;
    }

    if (isRetryScheduledLog(line)) {
      this.pendingFailure = undefined;
      this.emit({ kind: 'start-recovery-pending', line });
      return true;
    }

    if (isRecoverySucceededLog(line)) {
      this.pendingFailure = undefined;
      this.emit({ kind: 'start-recovery-succeeded', line });
      return true;
    }

    if (isRecoveryFailedLog(line)) {
      this.pendingFailure = undefined;
      return false;
    }

    return false;
  }
}

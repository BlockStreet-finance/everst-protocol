export enum AlertLevel {
  INFO = "INFO",
  WARN = "WARN",
  ERROR = "ERROR",
}

export interface Alert {
  level: AlertLevel;
  feed: string;
  message: string;
  timestamp: Date;
}

/**
 * Simple alerter that logs to console. Can be extended to push to
 * Telegram, PagerDuty, Slack, etc.
 */
export function sendAlert(alert: Alert): void {
  const prefix = `[${alert.level}][${alert.feed}]`;
  const ts = alert.timestamp.toISOString();

  switch (alert.level) {
    case AlertLevel.ERROR:
      console.error(`${ts} ${prefix} ${alert.message}`);
      break;
    case AlertLevel.WARN:
      console.warn(`${ts} ${prefix} ${alert.message}`);
      break;
    default:
      console.log(`${ts} ${prefix} ${alert.message}`);
  }
}

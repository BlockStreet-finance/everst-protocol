export declare enum AlertLevel {
    INFO = "INFO",
    WARN = "WARN",
    ERROR = "ERROR"
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
export declare function sendAlert(alert: Alert): void;

// Dates as the Mac app writes them (RootView.swift `Dates`). Its region is India in
// English, so days come before months: "5 November", "5 Nov", "7:30 AM".
const locale = "en-IN";

const shortDate = new Intl.DateTimeFormat(locale, { day: "numeric", month: "short" });
const longDate = new Intl.DateTimeFormat(locale, { day: "numeric", month: "long" });
const weekday = new Intl.DateTimeFormat(locale, { weekday: "long" });

export const Dates = {
  /** "5 Nov" */
  short: (date: Date) => shortDate.format(date),
  /** "5 November" */
  long: (date: Date) => longDate.format(date),
  /** The last week by weekday, older by date. */
  relative(date: Date, now: Date = new Date()): string {
    const days = Math.floor((now.getTime() - date.getTime()) / 86_400_000);
    return days < 7 ? weekday.format(date) : Dates.short(date);
  },
  /** "7:30 AM", in upper case whatever the platform's data says. */
  time(date: Date): string {
    const hours = date.getHours();
    const minutes = String(date.getMinutes()).padStart(2, "0");
    return `${hours % 12 || 12}:${minutes} ${hours < 12 ? "AM" : "PM"}`;
  },
  /** "now", "2 minutes ago", "yesterday": Foundation's named relative format. */
  named(date: Date, now: Date = new Date()): string {
    const seconds = Math.round((date.getTime() - now.getTime()) / 1000);
    if (Math.abs(seconds) < 60) return "now";
    const words = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
    const units: [Intl.RelativeTimeFormatUnit, number][] = [
      ["minute", 60],
      ["hour", 3600],
      ["day", 86_400],
      ["week", 604_800],
    ];
    let unit: Intl.RelativeTimeFormatUnit = "minute";
    let size = 60;
    for (const [name, span] of units) if (Math.abs(seconds) >= span) [unit, size] = [name, span];
    return words.format(Math.trunc(seconds / size), unit);
  },
};

// When a routine runs. Mirrors the `when` object in the routines operations, and
// `Schedule` in gui/Sources/ReaderLogic/Logic.swift.

export type ScheduleKind = "manual" | "daily" | "weekdays" | "weekly";

export interface Schedule {
  kind: ScheduleKind;
  /** "HH:MM", in the computer's time zone. */
  time?: string | null;
  /** ISO weekdays, 1 for Monday through 7 for Sunday. */
  days?: number[] | null;
}

const dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const shortDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/** The first chip of the When line. */
function repeatWords(schedule: Schedule): string {
  switch (schedule.kind) {
    case "manual":
      return "Only when I run it";
    case "daily":
      return "Every day";
    case "weekdays":
      return "Every weekday";
    case "weekly": {
      const days = [...(schedule.days ?? [])].sort((a, b) => a - b);
      if (days.length === 0) return "Every week";
      if (days.length === 1) return "Every " + dayNames[(days[0] - 1) % 7];
      return "On " + days.map((d) => shortDays[(d - 1) % 7]).join(", ");
    }
  }
}

/** One line, as the routine list shows it: "Weekdays 07:30". */
function summary(schedule: Schedule): string {
  const time = schedule.time ?? "";
  switch (schedule.kind) {
    case "manual":
      return "Manual";
    case "daily":
      return `Daily ${time}`.trim();
    case "weekdays":
      return `Weekdays ${time}`.trim();
    case "weekly":
      return `${repeatWords(schedule).replaceAll("Every ", "")} ${time}`.trim();
  }
}

/** Every half hour of the day, for the time chip's menu. */
const halfHours: readonly string[] = Array.from({ length: 48 }, (_, i) =>
  `${String(Math.floor(i / 2)).padStart(2, "0")}:${String((i % 2) * 30).padStart(2, "0")}`,
);

export const Schedule = { repeatWords, summary, halfHours };

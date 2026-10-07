import {
  addDays,
  addWeeks,
  areIntervalsOverlapping,
  eachDayOfInterval,
  format,
  isWeekend,
  parseISO,
  startOfWeek,
} from "date-fns";
import type { Alert, DateRange, Snapshot, WorkItem } from "./types";

export const OVERLOAD_THRESHOLD = 1.0;
export const WARNING_THRESHOLD = 0.85;
const MAX_CONCURRENT_ITEMS = 3;

export const toISO = (d: Date) => format(d, "yyyy-MM-dd");

export function weekStart(date: string | Date): string {
  const d = typeof date === "string" ? parseISO(date) : date;
  return toISO(startOfWeek(d, { weekStartsOn: 1 }));
}

/** Monday-based week keys starting at the week of `from`. */
export function weekRange(from: Date, count: number): string[] {
  const first = startOfWeek(from, { weekStartsOn: 1 });
  return Array.from({ length: count }, (_, i) => toISO(addWeeks(first, i)));
}

function inRanges(day: string, ranges: DateRange[]) {
  return ranges.some((r) => day >= r.start && day <= r.end);
}

function workingDays(range: DateRange, holidays: Set<string>): string[] {
  if (range.end < range.start) return [];
  return eachDayOfInterval({ start: parseISO(range.start), end: parseISO(range.end) })
    .filter((d) => !isWeekend(d))
    .map(toISO)
    .filter((d) => !holidays.has(d));
}

export interface WeekLoad {
  week: string;
  capacity: number;
  load: number;
  /** load / capacity; Infinity when there is load but no capacity. */
  utilization: number;
}

export type LoadMatrix = Record<string, Record<string, WeekLoad>>;

export function computeLoad(snapshot: Snapshot, weeks: string[]): LoadMatrix {
  const holidays = new Set(snapshot.holidays.map((h) => h.date));
  const matrix: LoadMatrix = {};

  for (const person of snapshot.people) {
    matrix[person.id] = {};
    for (const week of weeks) {
      const days = workingDays({ start: week, end: toISO(addDays(parseISO(week), 4)) }, holidays);
      const available = days.filter((d) => !inRanges(d, person.daysOff)).length;
      matrix[person.id][week] = { week, capacity: available * person.capacityPerDay, load: 0, utilization: 0 };
    }
  }

  for (const item of snapshot.workItems) {
    if (!item.assigneeId || !matrix[item.assigneeId]) continue;
    const days = workingDays(item, holidays);
    if (days.length === 0) continue;
    const perDay = item.remainingWork / days.length;
    for (const day of days) {
      const cell = matrix[item.assigneeId][weekStart(day)];
      if (cell) cell.load += perDay;
    }
  }

  for (const row of Object.values(matrix)) {
    for (const cell of Object.values(row)) {
      cell.utilization = cell.capacity > 0 ? cell.load / cell.capacity : cell.load > 0 ? Infinity : 0;
    }
  }
  return matrix;
}

const overlaps = (a: DateRange, b: DateRange) =>
  areIntervalsOverlapping(
    { start: parseISO(a.start), end: parseISO(a.end) },
    { start: parseISO(b.start), end: parseISO(b.end) },
    { inclusive: true },
  );

const pct = (n: number) => `${Math.round(n * 100)}%`;

export function computeAlerts(snapshot: Snapshot, weeks: string[], load: LoadMatrix): Alert[] {
  const alerts: Alert[] = [];
  const people = new Map(snapshot.people.map((p) => [p.id, p]));
  const visible: DateRange = { start: weeks[0], end: toISO(addDays(parseISO(weeks[weeks.length - 1]), 6)) };
  const items = snapshot.workItems.filter((i) => overlaps(i, visible));

  for (const person of snapshot.people) {
    for (const week of weeks) {
      const cell = load[person.id][week];
      if (cell.load === 0) continue;
      if (cell.utilization > OVERLOAD_THRESHOLD) {
        alerts.push({
          id: `overload-${person.id}-${week}`,
          kind: "overload",
          severity: "critical",
          personId: person.id,
          week,
          message: Number.isFinite(cell.utilization)
            ? `${person.name} está com ${pct(cell.utilization)} de utilização na semana de ${fmtDay(week)} (${Math.round(cell.load)}h de ${Math.round(cell.capacity)}h).`
            : `${person.name} tem ${Math.round(cell.load)}h alocadas na semana de ${fmtDay(week)}, mas nenhuma hora disponível.`,
        });
      } else if (cell.utilization >= WARNING_THRESHOLD) {
        alerts.push({
          id: `near-${person.id}-${week}`,
          kind: "overload",
          severity: "warning",
          personId: person.id,
          week,
          message: `${person.name} chega a ${pct(cell.utilization)} na semana de ${fmtDay(week)}: perto do limite.`,
        });
      }
    }
  }

  for (const item of items) {
    if (!item.assigneeId) {
      alerts.push({
        id: `unassigned-${item.id}`,
        kind: "unassigned",
        severity: "warning",
        workItemId: item.id,
        message: `#${item.id} "${item.title}" não tem responsável.`,
      });
      continue;
    }
    const person = people.get(item.assigneeId);
    if (!person) continue;
    for (const off of person.daysOff) {
      if (overlaps(item, off)) {
        alerts.push({
          id: `absence-${item.id}-${off.start}`,
          kind: "absence",
          severity: "warning",
          personId: person.id,
          workItemId: item.id,
          message: `#${item.id} "${item.title}" cai na ausência de ${person.name} (${fmtDay(off.start)} a ${fmtDay(off.end)}).`,
        });
      }
    }
    for (const h of snapshot.holidays) {
      if (h.date >= item.start && h.date <= item.end) {
        alerts.push({
          id: `holiday-${item.id}-${h.date}`,
          kind: "holiday",
          severity: "info",
          personId: person.id,
          workItemId: item.id,
          message: `#${item.id} "${item.title}" atravessa o feriado ${h.name} (${fmtDay(h.date)}).`,
        });
      }
    }
  }

  // Too many items in flight at once for the same person.
  for (const person of snapshot.people) {
    const own = items.filter((i) => i.assigneeId === person.id);
    for (const week of weeks) {
      const range = { start: week, end: toISO(addDays(parseISO(week), 4)) };
      const active = own.filter((i) => overlaps(i, range));
      if (active.length > MAX_CONCURRENT_ITEMS) {
        alerts.push({
          id: `overlap-${person.id}-${week}`,
          kind: "overlap",
          severity: "warning",
          personId: person.id,
          week,
          message: `${person.name} tem ${active.length} itens em paralelo na semana de ${fmtDay(week)}.`,
        });
      }
    }
  }

  const rank = { critical: 0, warning: 1, info: 2 };
  return alerts.sort((a, b) => rank[a.severity] - rank[b.severity]);
}

export function fmtDay(iso: string) {
  return format(parseISO(iso), "dd/MM");
}

/** Moves an item to another person and/or week, keeping its duration. */
export function reallocate(item: WorkItem, assigneeId: string, targetWeek: string): WorkItem {
  const shift = Math.round((parseISO(targetWeek).getTime() - parseISO(weekStart(item.start)).getTime()) / 86_400_000);
  return {
    ...item,
    assigneeId,
    start: toISO(addDays(parseISO(item.start), shift)),
    end: toISO(addDays(parseISO(item.end), shift)),
  };
}

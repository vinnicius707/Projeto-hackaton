// Dates are ISO strings (yyyy-MM-dd) so the snapshot is plain JSON.

export interface DateRange {
  start: string;
  end: string;
}

export interface Person {
  id: string;
  name: string;
  role?: string;
  /** Working hours per day available for project work. */
  capacityPerDay: number;
  daysOff: DateRange[];
}

export interface Holiday {
  date: string;
  name: string;
}

export interface Iteration {
  id: string;
  name: string;
  path: string;
  start: string;
  end: string;
}

export interface WorkItem {
  id: number;
  title: string;
  type: string;
  state: string;
  project: string;
  assigneeId: string | null;
  start: string;
  end: string;
  /** Remaining effort in hours, spread evenly across working days between start and end. */
  remainingWork: number;
  url?: string;
}

export interface Snapshot {
  source: "demo" | "azure-devops";
  syncedAt: string;
  people: Person[];
  holidays: Holiday[];
  iterations: Iteration[];
  workItems: WorkItem[];
}

export type AlertKind = "overload" | "absence" | "holiday" | "overlap" | "unassigned";

export interface Alert {
  id: string;
  kind: AlertKind;
  severity: "critical" | "warning" | "info";
  message: string;
  personId?: string;
  workItemId?: number;
  week?: string;
}

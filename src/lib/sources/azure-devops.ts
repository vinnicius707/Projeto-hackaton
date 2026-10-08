import type { DateRange, Holiday, Iteration, Person, Snapshot, WorkItem } from "../types";

// Azure DevOps REST API 7.1: https://learn.microsoft.com/rest/api/azure/devops
const API_VERSION = "7.1";
const DEFAULT_HOURS_PER_DAY = 6;

export interface AzureDevOpsConfig {
  org: string;
  project: string;
  team: string;
  pat: string;
}

export function azureDevOpsConfig(): AzureDevOpsConfig | null {
  const { AZDO_ORG, AZDO_PROJECT, AZDO_TEAM, AZDO_PAT } = process.env;
  if (!AZDO_ORG || !AZDO_PROJECT || !AZDO_PAT) return null;
  return { org: AZDO_ORG, project: AZDO_PROJECT, team: AZDO_TEAM || `${AZDO_PROJECT} Team`, pat: AZDO_PAT };
}

interface AdoIdentity {
  id: string;
  displayName: string;
  uniqueName?: string;
}

interface AdoCapacity {
  teamMember: AdoIdentity;
  activities: { capacityPerDay: number; name: string }[];
  daysOff: { start: string; end: string }[];
}

export async function azureDevOpsSnapshot(cfg: AzureDevOpsConfig): Promise<Snapshot> {
  const base = `https://dev.azure.com/${encodeURIComponent(cfg.org)}`;
  const project = encodeURIComponent(cfg.project);
  const team = encodeURIComponent(cfg.team);
  const auth = `Basic ${Buffer.from(`:${cfg.pat}`).toString("base64")}`;

  async function call<T>(url: string, init?: RequestInit): Promise<T> {
    const sep = url.includes("?") ? "&" : "?";
    const res = await fetch(`${url}${sep}api-version=${API_VERSION}`, {
      ...init,
      headers: { Authorization: auth, "Content-Type": "application/json", ...init?.headers },
      cache: "no-store",
    });
    if (!res.ok) throw new Error(`Azure DevOps ${res.status} em ${url}: ${await res.text()}`);
    return res.json() as Promise<T>;
  }

  // 1. Iterations (sprints) of the team.
  const { value: rawIterations } = await call<{
    value: { id: string; name: string; path: string; attributes: { startDate?: string; finishDate?: string } }[];
  }>(`${base}/${project}/${team}/_apis/work/teamsettings/iterations`);
  const iterations: Iteration[] = rawIterations
    .filter((i) => i.attributes.startDate && i.attributes.finishDate)
    .map((i) => ({
      id: i.id,
      name: i.name,
      path: i.path,
      start: i.attributes.startDate!.slice(0, 10),
      end: i.attributes.finishDate!.slice(0, 10),
    }));

  // 2. Capacity and days off per member, plus team days off (treated as holidays).
  const people = new Map<string, Person>();
  const holidays: Holiday[] = [];
  for (const it of iterations) {
    const cap = await call<{ teamMembers?: AdoCapacity[]; value?: AdoCapacity[] }>(
      `${base}/${project}/${team}/_apis/work/teamsettings/iterations/${it.id}/capacities`,
    );
    for (const m of cap.teamMembers ?? cap.value ?? []) {
      const perDay = m.activities.reduce((sum, a) => sum + (a.capacityPerDay || 0), 0);
      const daysOff: DateRange[] = m.daysOff.map((o) => ({ start: o.start.slice(0, 10), end: o.end.slice(0, 10) }));
      const existing = people.get(m.teamMember.id);
      if (existing) {
        existing.daysOff.push(...daysOff);
        if (perDay > 0) existing.capacityPerDay = perDay;
      } else {
        people.set(m.teamMember.id, {
          id: m.teamMember.id,
          name: m.teamMember.displayName,
          capacityPerDay: perDay || DEFAULT_HOURS_PER_DAY,
          daysOff,
        });
      }
    }
    const teamOff = await call<{ daysOff: { start: string; end: string }[] }>(
      `${base}/${project}/${team}/_apis/work/teamsettings/iterations/${it.id}/teamdaysoff`,
    );
    for (const o of teamOff.daysOff) {
      for (let day = new Date(o.start); day <= new Date(o.end); day.setUTCDate(day.getUTCDate() + 1)) {
        holidays.push({ date: day.toISOString().slice(0, 10), name: `Folga do time (${it.name})` });
      }
    }
  }

  // 3. Open work items of the project.
  const wiql = await call<{ workItems: { id: number }[] }>(`${base}/${project}/${team}/_apis/wit/wiql`, {
    method: "POST",
    body: JSON.stringify({
      query: `SELECT [System.Id] FROM WorkItems
              WHERE [System.TeamProject] = @project
                AND [System.State] NOT IN ('Closed', 'Done', 'Removed')
                AND [System.WorkItemType] IN ('User Story', 'Product Backlog Item', 'Task', 'Bug')
              ORDER BY [System.ChangedDate] DESC`,
    }),
  });
  const ids = wiql.workItems.map((w) => w.id);
  const fields = [
    "System.Id",
    "System.Title",
    "System.WorkItemType",
    "System.State",
    "System.TeamProject",
    "System.AssignedTo",
    "System.IterationPath",
    "Microsoft.VSTS.Scheduling.StartDate",
    "Microsoft.VSTS.Scheduling.TargetDate",
    "Microsoft.VSTS.Scheduling.RemainingWork",
    "Microsoft.VSTS.Scheduling.OriginalEstimate",
  ];
  const byPath = new Map(iterations.map((i) => [i.path, i]));
  const workItems: WorkItem[] = [];
  for (let i = 0; i < ids.length; i += 200) {
    const batch = await call<{ value: { id: number; fields: Record<string, unknown>; _links?: { html?: { href: string } } }[] }>(
      `${base}/${project}/_apis/wit/workitems?ids=${ids.slice(i, i + 200).join(",")}&fields=${fields.join(",")}`,
    );
    for (const wi of batch.value) {
      const f = wi.fields;
      const iteration = byPath.get(f["System.IterationPath"] as string);
      const start = (f["Microsoft.VSTS.Scheduling.StartDate"] as string | undefined)?.slice(0, 10) ?? iteration?.start;
      const end = (f["Microsoft.VSTS.Scheduling.TargetDate"] as string | undefined)?.slice(0, 10) ?? iteration?.end;
      if (!start || !end) continue; // Not scheduled anywhere: nothing to plot.
      const assignee = f["System.AssignedTo"] as AdoIdentity | undefined;
      if (assignee && !people.has(assignee.id)) {
        people.set(assignee.id, { id: assignee.id, name: assignee.displayName, capacityPerDay: DEFAULT_HOURS_PER_DAY, daysOff: [] });
      }
      workItems.push({
        id: wi.id,
        title: f["System.Title"] as string,
        type: f["System.WorkItemType"] as string,
        state: f["System.State"] as string,
        project: f["System.TeamProject"] as string,
        assigneeId: assignee?.id ?? null,
        start,
        end,
        remainingWork:
          (f["Microsoft.VSTS.Scheduling.RemainingWork"] as number | undefined) ??
          (f["Microsoft.VSTS.Scheduling.OriginalEstimate"] as number | undefined) ??
          0,
        url: `https://dev.azure.com/${cfg.org}/${cfg.project}/_workitems/edit/${wi.id}`,
      });
    }
  }

  return {
    source: "azure-devops",
    syncedAt: new Date().toISOString(),
    people: [...people.values()].sort((a, b) => a.name.localeCompare(b.name)),
    holidays,
    iterations,
    workItems,
  };
}

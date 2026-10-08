import { fmtDay, OVERLOAD_THRESHOLD, WARNING_THRESHOLD, type LoadMatrix } from "@/lib/capacity";
import type { Person } from "@/lib/types";

export function utilizationClass(u: number, load: number) {
  if (load === 0) return "bg-zinc-100 text-zinc-400 dark:bg-zinc-800 dark:text-zinc-500";
  if (u > OVERLOAD_THRESHOLD) return "bg-red-500 text-white";
  if (u >= WARNING_THRESHOLD) return "bg-amber-400 text-amber-950";
  if (u >= 0.5) return "bg-emerald-500 text-white";
  return "bg-emerald-200 text-emerald-900 dark:bg-emerald-900 dark:text-emerald-100";
}

export function Heatmap({ people, weeks, load }: { people: Person[]; weeks: string[]; load: LoadMatrix }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full border-separate border-spacing-1 text-sm">
        <thead>
          <tr>
            <th className="w-40 text-left font-normal text-zinc-500">Pessoa</th>
            {weeks.map((w) => (
              <th key={w} className="font-normal text-zinc-500">
                {fmtDay(w)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {people.map((p) => (
            <tr key={p.id}>
              <td className="truncate pr-2">
                {p.name}
                {p.role && <span className="block text-xs text-zinc-500">{p.role}</span>}
              </td>
              {weeks.map((w) => {
                const cell = load[p.id][w];
                const label = Number.isFinite(cell.utilization) ? `${Math.round(cell.utilization * 100)}%` : "—";
                return (
                  <td
                    key={w}
                    title={`${Math.round(cell.load)}h alocadas de ${Math.round(cell.capacity)}h disponíveis`}
                    className={`h-10 min-w-14 rounded text-center font-medium tabular-nums ${utilizationClass(cell.utilization, cell.load)}`}
                  >
                    {label}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="mt-3 flex gap-4 text-xs text-zinc-500">
        <Legend className="bg-emerald-200" label="< 50%" />
        <Legend className="bg-emerald-500" label="50–84%" />
        <Legend className="bg-amber-400" label="85–100%" />
        <Legend className="bg-red-500" label="> 100%" />
      </div>
    </div>
  );
}

function Legend({ className, label }: { className: string; label: string }) {
  return (
    <span className="flex items-center gap-1">
      <span className={`inline-block h-3 w-3 rounded-sm ${className}`} /> {label}
    </span>
  );
}

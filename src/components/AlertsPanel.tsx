import type { Alert } from "@/lib/types";

const styles: Record<Alert["severity"], string> = {
  critical: "border-red-300 bg-red-50 text-red-900 dark:border-red-800 dark:bg-red-950 dark:text-red-100",
  warning: "border-amber-300 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100",
  info: "border-zinc-200 bg-zinc-50 text-zinc-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200",
};

const labels: Record<Alert["kind"], string> = {
  overload: "Sobrecarga",
  absence: "Ausência",
  holiday: "Feriado",
  overlap: "Sobreposição",
  unassigned: "Sem responsável",
};

export function AlertsPanel({ alerts }: { alerts: Alert[] }) {
  if (alerts.length === 0) return <p className="text-sm text-zinc-500">Nenhum conflito no período. 🎉</p>;
  return (
    <ul className="flex max-h-[70vh] flex-col gap-2 overflow-y-auto">
      {alerts.map((a) => (
        <li key={a.id} className={`rounded-md border p-2 text-sm ${styles[a.severity]}`}>
          <span className="block text-xs font-semibold uppercase tracking-wide opacity-70">{labels[a.kind]}</span>
          {a.message}
        </li>
      ))}
    </ul>
  );
}

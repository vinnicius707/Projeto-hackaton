"use client";

import { useEffect, useMemo, useState } from "react";
import { computeAlerts, computeLoad, reallocate, weekRange } from "@/lib/capacity";
import type { Snapshot, WorkItem } from "@/lib/types";
import { AlertsPanel } from "./AlertsPanel";
import { Heatmap } from "./Heatmap";
import { Timeline } from "./Timeline";

const WEEKS = 8;

export function Dashboard() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  // Local what-if reallocations, keyed by work item id. Azure DevOps is not changed.
  const [moves, setMoves] = useState<Record<number, WorkItem>>({});

  async function sync() {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch("/api/snapshot");
      const body = await res.json();
      if (!res.ok) throw new Error(body.error ?? res.statusText);
      setSnapshot(body);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial sync on mount
    sync();
  }, []);

  const weeks = useMemo(() => (snapshot ? weekRange(new Date(snapshot.syncedAt), WEEKS) : []), [snapshot]);

  const planned = useMemo<Snapshot | null>(
    () => snapshot && { ...snapshot, workItems: snapshot.workItems.map((i) => moves[i.id] ?? i) },
    [snapshot, moves],
  );
  const load = useMemo(() => planned && computeLoad(planned, weeks), [planned, weeks]);
  const alerts = useMemo(() => planned && load && computeAlerts(planned, weeks, load), [planned, weeks, load]);

  function move(itemId: number, personId: string, week: string) {
    const item = planned?.workItems.find((i) => i.id === itemId);
    if (item) setMoves((m) => ({ ...m, [itemId]: reallocate(item, personId, week) }));
  }

  const moveCount = Object.keys(moves).length;

  return (
    <div className="mx-auto flex w-full max-w-7xl flex-col gap-6 p-6">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Capacidade do time</h1>
          <p className="text-sm text-zinc-500">
            {snapshot
              ? `Fonte: ${snapshot.source === "demo" ? "dados de demonstração" : "Azure DevOps"} · sincronizado às ${new Date(snapshot.syncedAt).toLocaleTimeString("pt-BR")}`
              : "Carregando…"}
          </p>
        </div>
        <div className="flex gap-2">
          {moveCount > 0 && (
            <button
              onClick={() => setMoves({})}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              Desfazer {moveCount} realocação{moveCount > 1 ? "ões" : ""}
            </button>
          )}
          <button
            onClick={sync}
            disabled={loading}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {loading ? "Sincronizando…" : "Sincronizar"}
          </button>
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
          Falha ao sincronizar: {error}
        </div>
      )}

      {planned && load && alerts && (
        <div className="grid gap-6 lg:grid-cols-[1fr_320px]">
          <div className="flex min-w-0 flex-col gap-6">
            <Section title="Utilização por semana">
              <Heatmap people={planned.people} weeks={weeks} load={load} />
            </Section>
            <Section title="Timeline" hint="Arraste um item para outra pessoa ou semana para simular a realocação.">
              <Timeline snapshot={planned} weeks={weeks} movedIds={new Set(Object.keys(moves).map(Number))} onMove={move} />
            </Section>
          </div>
          <Section title={`Alertas (${alerts.length})`}>
            <AlertsPanel alerts={alerts} />
          </Section>
        </div>
      )}
    </div>
  );
}

function Section({ title, hint, children }: { title: string; hint?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-lg border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
      <h2 className="font-medium">{title}</h2>
      {hint && <p className="mb-2 text-xs text-zinc-500">{hint}</p>}
      <div className="mt-3">{children}</div>
    </section>
  );
}

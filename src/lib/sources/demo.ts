import { addDays, startOfWeek } from "date-fns";
import { toISO } from "../capacity";
import type { Person, Snapshot, WorkItem } from "../types";

// Dates are relative to the current week so the demo always looks "live".
export function demoSnapshot(today = new Date()): Snapshot {
  const monday = startOfWeek(today, { weekStartsOn: 1 });
  const d = (offset: number) => toISO(addDays(monday, offset));

  const people: Person[] = [
    { id: "ana", name: "Ana Souza", role: "Tech Lead", capacityPerDay: 6, daysOff: [] },
    { id: "bruno", name: "Bruno Lima", role: "Backend", capacityPerDay: 6, daysOff: [{ start: d(14), end: d(18) }] },
    { id: "carla", name: "Carla Mendes", role: "Frontend", capacityPerDay: 6, daysOff: [] },
    { id: "diego", name: "Diego Rocha", role: "QA", capacityPerDay: 4, daysOff: [{ start: d(9), end: d(10) }] },
    { id: "elisa", name: "Elisa Prado", role: "Fullstack", capacityPerDay: 6, daysOff: [] },
  ];

  const items: Array<Omit<WorkItem, "project" | "state"> & { state?: string }> = [
    { id: 1201, title: "Integração com API do terminal", type: "User Story", assigneeId: "bruno", start: d(0), end: d(11), remainingWork: 60 },
    { id: 1202, title: "Fila de agendamento de caminhões", type: "Task", assigneeId: "bruno", start: d(7), end: d(18), remainingWork: 40 },
    { id: 1203, title: "Tela de gate-in", type: "User Story", assigneeId: "carla", start: d(0), end: d(4), remainingWork: 24 },
    { id: 1204, title: "Dashboard de pátio", type: "User Story", assigneeId: "carla", start: d(7), end: d(18), remainingWork: 70 },
    { id: 1205, title: "Revisão de arquitetura", type: "Task", assigneeId: "ana", start: d(0), end: d(2), remainingWork: 10 },
    { id: 1206, title: "Mentoria e code review", type: "Task", assigneeId: "ana", start: d(0), end: d(25), remainingWork: 30 },
    { id: 1207, title: "Testes de regressão do release", type: "Task", assigneeId: "diego", start: d(7), end: d(11), remainingWork: 20 },
    { id: 1208, title: "Automação de testes E2E", type: "Task", assigneeId: "diego", start: d(14), end: d(25), remainingWork: 30 },
    { id: 1209, title: "Migração do banco de cargas", type: "User Story", assigneeId: "elisa", start: d(0), end: d(9), remainingWork: 40 },
    { id: 1210, title: "Relatório de produtividade", type: "Task", assigneeId: "elisa", start: d(21), end: d(32), remainingWork: 30 },
    { id: 1211, title: "Notificações push", type: "Task", assigneeId: "carla", start: d(14), end: d(18), remainingWork: 16 },
    { id: 1212, title: "Ajuste de performance em consultas", type: "Bug", assigneeId: "bruno", start: d(14), end: d(16), remainingWork: 12 },
    { id: 1213, title: "Exportação CSV de movimentações", type: "Task", assigneeId: null, start: d(21), end: d(25), remainingWork: 16 },
    { id: 1214, title: "Login com SSO", type: "User Story", assigneeId: "ana", start: d(28), end: d(39), remainingWork: 40 },
  ];

  const sprint = (n: number) => ({
    id: `sprint-${n}`,
    name: `Sprint ${n}`,
    path: `Porto\\Sprint ${n}`,
    start: d((n - 1) * 14),
    end: d((n - 1) * 14 + 11),
  });

  return {
    source: "demo",
    syncedAt: new Date().toISOString(),
    people,
    holidays: [{ date: d(24), name: "Feriado municipal" }],
    iterations: [sprint(1), sprint(2), sprint(3)],
    workItems: items.map((i) => ({ state: "Active", project: "Porto", ...i })),
  };
}

"use client";

import {
  DndContext,
  PointerSensor,
  pointerWithin,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import { fmtDay, weekStart } from "@/lib/capacity";
import type { Snapshot, WorkItem } from "@/lib/types";

const LABEL_WIDTH = "160px";
const LANE_HEIGHT = 30;

const typeColors: Record<string, string> = {
  "User Story": "bg-blue-500",
  "Product Backlog Item": "bg-blue-500",
  Task: "bg-violet-500",
  Bug: "bg-rose-500",
};

interface Props {
  snapshot: Snapshot;
  weeks: string[];
  movedIds: Set<number>;
  onMove: (itemId: number, personId: string, week: string) => void;
}

interface Placed {
  item: WorkItem;
  col: number;
  span: number;
  lane: number;
}

/** Places items on week columns and stacks overlapping ones in lanes. */
function layout(items: WorkItem[], weeks: string[]): { placed: Placed[]; lanes: number } {
  const first = weeks[0];
  const last = weeks[weeks.length - 1];
  const laneEnds: number[] = [];
  const placed: Placed[] = [];
  const visible = items
    .filter((i) => weekStart(i.end) >= first && weekStart(i.start) <= last)
    .sort((a, b) => a.start.localeCompare(b.start));
  for (const item of visible) {
    const s = weekStart(item.start);
    const e = weekStart(item.end);
    const col = s < first ? 0 : weeks.indexOf(s);
    const endCol = e > last ? weeks.length - 1 : weeks.indexOf(e);
    let lane = laneEnds.findIndex((end) => end < col);
    if (lane === -1) lane = laneEnds.length;
    laneEnds[lane] = endCol;
    placed.push({ item, col, span: endCol - col + 1, lane });
  }
  return { placed, lanes: Math.max(1, laneEnds.length) };
}

export function Timeline({ snapshot, weeks, movedIds, onMove }: Props) {
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 4 } }));
  const unassigned = snapshot.workItems.filter((i) => !i.assigneeId);
  const rows = [
    ...snapshot.people.map((p) => ({ id: p.id, name: p.name, items: snapshot.workItems.filter((i) => i.assigneeId === p.id) })),
    ...(unassigned.length ? [{ id: "", name: "Sem responsável", items: unassigned }] : []),
  ];
  const columns = `${LABEL_WIDTH} repeat(${weeks.length}, minmax(64px, 1fr))`;

  function handleDragEnd(e: DragEndEvent) {
    const itemId = e.active.data.current?.itemId as number | undefined;
    const target = e.over?.data.current as { personId: string; week: string } | undefined;
    if (itemId !== undefined && target?.personId) onMove(itemId, target.personId, target.week);
  }

  return (
    <DndContext sensors={sensors} collisionDetection={pointerWithin} onDragEnd={handleDragEnd}>
      <div className="overflow-x-auto">
        <div className="min-w-[720px] text-sm">
          <div className="grid gap-x-1 pb-1 text-zinc-500" style={{ gridTemplateColumns: columns }}>
            <span>Pessoa</span>
            {weeks.map((w) => (
              <span key={w} className="text-center">
                {fmtDay(w)}
              </span>
            ))}
          </div>
          {rows.map((row) => {
            const { placed, lanes } = layout(row.items, weeks);
            return (
              <div
                key={row.id || "unassigned"}
                className="grid gap-x-1 border-t border-zinc-200 py-1 dark:border-zinc-800"
                style={{ gridTemplateColumns: columns, gridTemplateRows: `repeat(${lanes}, ${LANE_HEIGHT}px)` }}
              >
                <span className="truncate self-center" style={{ gridRow: `1 / span ${lanes}` }}>
                  {row.name}
                </span>
                {weeks.map((w, i) => (
                  <DropCell key={w} personId={row.id} week={w} col={i + 2} lanes={lanes} />
                ))}
                {placed.map((p) => (
                  <Bar key={p.item.id} placed={p} moved={movedIds.has(p.item.id)} />
                ))}
              </div>
            );
          })}
        </div>
      </div>
    </DndContext>
  );
}

function DropCell({ personId, week, col, lanes }: { personId: string; week: string; col: number; lanes: number }) {
  const { setNodeRef, isOver } = useDroppable({
    id: `cell-${personId || "unassigned"}-${week}`,
    data: { personId, week },
    disabled: !personId,
  });
  return (
    <div
      ref={setNodeRef}
      className={`rounded ${isOver ? "bg-blue-100 dark:bg-blue-950" : "bg-zinc-50 dark:bg-zinc-800/40"}`}
      style={{ gridColumn: col, gridRow: `1 / span ${lanes}` }}
    />
  );
}

function Bar({ placed, moved }: { placed: Placed; moved: boolean }) {
  const { item, col, span, lane } = placed;
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({
    id: `item-${item.id}`,
    data: { itemId: item.id },
  });
  return (
    <div
      ref={setNodeRef}
      {...listeners}
      {...attributes}
      title={`#${item.id} ${item.title}\n${fmtDay(item.start)} → ${fmtDay(item.end)} · ${item.remainingWork}h restantes`}
      className={`z-10 m-0.5 flex cursor-grab items-center truncate rounded px-2 text-xs font-medium text-white shadow-sm active:cursor-grabbing ${
        typeColors[item.type] ?? "bg-zinc-500"
      } ${moved ? "ring-2 ring-amber-400 ring-offset-1" : ""} ${isDragging ? "z-20 opacity-80 shadow-lg" : ""}`}
      style={{
        gridColumn: `${col + 2} / span ${span}`,
        gridRow: lane + 1,
        transform: transform ? `translate3d(${transform.x}px, ${transform.y}px, 0)` : undefined,
      }}
    >
      <span className="truncate">
        #{item.id} {item.title}
      </span>
    </div>
  );
}

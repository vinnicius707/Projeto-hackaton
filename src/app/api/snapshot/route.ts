import { connection } from "next/server";
import { getSnapshot } from "@/lib/data";

export async function GET() {
  await connection(); // Always sync at request time.
  try {
    return Response.json(await getSnapshot());
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 502 });
  }
}

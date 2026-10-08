import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Capacidade do time",
  description: "Capacidade, alocação e alertas do time a partir do Azure DevOps",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="pt-BR" className="h-full antialiased">
      <body className="min-h-full bg-zinc-50 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">{children}</body>
    </html>
  );
}

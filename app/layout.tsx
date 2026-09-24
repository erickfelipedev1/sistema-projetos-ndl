import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Controle de Processos",
  description: "Fluxo de processos da equipe de projetos",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pt-BR">
      <body>{children}</body>
    </html>
  );
}

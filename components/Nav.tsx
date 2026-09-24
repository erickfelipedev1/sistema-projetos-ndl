"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const LINKS = [
  { href: "/", label: "Painel" },
  { href: "/processos", label: "Processos" },
  { href: "/minhas", label: "Minhas tarefas" },
  { href: "/configuracoes", label: "Configurações" },
];

export default function Nav({ contagemMinhas }: { contagemMinhas: number }) {
  const path = usePathname();
  return (
    <nav className="flex gap-1 overflow-x-auto">
      {LINKS.map((l) => {
        const ativo = l.href === "/" ? path === "/" : path.startsWith(l.href);
        return (
          <Link key={l.href} href={l.href}
            className={`whitespace-nowrap rounded-lg px-3 py-1.5 text-sm font-medium ${ativo ? "bg-indigo-50 text-indigo-700" : "text-slate-600 hover:bg-slate-100"}`}>
            {l.label}
            {l.href === "/minhas" && contagemMinhas > 0 && (
              <span className="ml-1.5 rounded-full bg-indigo-600 px-1.5 text-[11px] text-white">{contagemMinhas}</span>
            )}
          </Link>
        );
      })}
    </nav>
  );
}

"use client";

import { useEffect, useRef } from "react";
import { MoreHorizontal } from "lucide-react";

/** menu "mais opções" — fecha ao clicar fora */
export default function Menu({ children, rotulo = "Mais opções" }: { children: React.ReactNode; rotulo?: string }) {
  const ref = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const f = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) ref.current.open = false; };
    document.addEventListener("click", f);
    return () => document.removeEventListener("click", f);
  }, []);
  return (
    <details ref={ref} className="relative">
      <summary className="btn-ghost w-8 cursor-pointer px-0" aria-label={rotulo} title={rotulo}><MoreHorizontal size={16} /></summary>
      <div className="absolute right-0 z-30 mt-1 w-56 rounded-md border border-line bg-surface p-1 shadow-[var(--shadow-pop)]">{children}</div>
    </details>
  );
}

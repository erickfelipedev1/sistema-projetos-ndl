"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";

/** seletor que troca um parâmetro da URL ao mudar */
export default function ParamSelect({ nome, valor, opcoes, vazio, className = "input" }: {
  nome: string; valor: string; opcoes: { valor: string; rotulo: string }[]; vazio: string; className?: string;
}) {
  const router = useRouter();
  const sp = useSearchParams();
  const path = usePathname();
  return (
    <select className={className} value={valor} aria-label={vazio}
      onChange={(e) => { const u = new URLSearchParams(sp.toString()); if (e.target.value) u.set(nome, e.target.value); else u.delete(nome); router.replace(`${path}?${u.toString()}`, { scroll: false }); }}>
      <option value="">{vazio}</option>
      {opcoes.map((o) => <option key={o.valor} value={o.valor}>{o.rotulo}</option>)}
    </select>
  );
}

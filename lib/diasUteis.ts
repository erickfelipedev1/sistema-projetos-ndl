// Mesma regra do banco (public.dias_uteis_entre): conta dias úteis em (a, b]
function parse(d: string) {
  const [y, m, day] = d.slice(0, 10).split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, day));
}
function iso(d: Date) {
  return d.toISOString().slice(0, 10);
}
export function hojeBR() {
  return new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
}
export function paraDataBR(ts: string) {
  return new Date(ts).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
}
export function diasUteisEntre(a: string, b: string, feriados: Set<string>) {
  const ini = parse(a), fim = parse(b);
  const sinal = fim >= ini ? 1 : -1;
  const [x, y] = sinal === 1 ? [ini, fim] : [fim, ini];
  let n = 0;
  const d = new Date(x);
  while (d < y) {
    d.setUTCDate(d.getUTCDate() + 1);
    const dow = d.getUTCDay();
    if (dow !== 0 && dow !== 6 && !feriados.has(iso(d))) n++;
  }
  return n * sinal;
}
export function addDiasUteis(inicio: string, n: number, feriados: Set<string>) {
  const d = parse(inicio);
  let c = 0;
  while (c < n) {
    d.setUTCDate(d.getUTCDate() + 1);
    const dow = d.getUTCDay();
    if (dow !== 0 && dow !== 6 && !feriados.has(iso(d))) c++;
  }
  return iso(d);
}

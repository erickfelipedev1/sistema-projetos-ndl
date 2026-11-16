import { redirect } from "next/navigation";

// a antiga aba Sourcing virou a etapa Distribuição
export default function Sourcing() {
  redirect("/distribuicao");
}

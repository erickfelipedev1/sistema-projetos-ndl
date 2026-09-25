import "server-only";
import { createClient } from "@supabase/supabase-js";

// Cliente com a service role: só no servidor. Precisa da variável SUPABASE_SERVICE_ROLE_KEY.
export function createAdminClient() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new Error("Falta configurar SUPABASE_SERVICE_ROLE_KEY");
  return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", {headers:cors});
  try {
    const authHeader = req.headers.get("Authorization") || "";
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const caller = createClient(url, anon, {global:{headers:{Authorization:authHeader}}});
    const {data:{user}} = await caller.auth.getUser();
    if (!user) throw new Error("Não autenticado");
    const admin = createClient(url, service);
    const callerEmail = String(user.email || "").trim().toLowerCase();
    const providers = Array.isArray(user.app_metadata?.providers) ? user.app_metadata.providers : [];
    if (!callerEmail.endsWith("@ifms.edu.br") || (user.app_metadata?.provider !== "google" && !providers.includes("google"))) {
      throw new Error("Use sua conta Google institucional @ifms.edu.br.");
    }
    const {data:profile} = await admin.from("profiles").select("id,role,active").eq("email",callerEmail).single();
    if (!profile?.active || profile.role !== "admin") throw new Error("Somente administradores do SIGLAB podem cadastrar usuários internos.");
    const body = await req.json();
    if (body.action === "update-email") {
      const targetId = String(body.user_id || "");
      const newEmail = String(body.email || "").trim().toLowerCase();
      if (!targetId || !/^[^\s@]+@ifms\.edu\.br$/i.test(newEmail)) throw new Error("Informe um e-mail institucional @ifms.edu.br.");
      const {data:emailOwner,error:ownerError} = await admin.from("profiles").select("id").eq("email",newEmail).neq("id",targetId).maybeSingle();
      if (ownerError) throw ownerError;
      if (emailOwner) throw new Error("Este e-mail já pertence a outro usuário.");
      const {error:authEmailError} = await admin.auth.admin.updateUserById(targetId,{email:newEmail,email_confirm:true});
      if (authEmailError) throw authEmailError;
      const {error:profileEmailError} = await admin.from("profiles").update({email:newEmail}).eq("id",targetId);
      if (profileEmailError) throw profileEmailError;
      return new Response(JSON.stringify({ok:true,email:newEmail}),{headers:{...cors,"Content-Type":"application/json"}});
    }
    const {email,siape,full_name,role} = body;
    const normalizedEmail = String(email || "").trim().toLowerCase();
    if (!/^[^\s@]+@ifms\.edu\.br$/i.test(normalizedEmail) || !siape || !full_name || !["tecnico","supervisor","admin"].includes(role)) throw new Error("Dados inválidos");
    // A senha aleatoria nunca e entregue ao usuario. O acesso ocorre somente
    // pelo provedor Google, que vincula a identidade pelo e-mail institucional.
    const temporaryPassword = `${crypto.randomUUID()}Aa1!`;
    const {data:created,error} = await admin.auth.admin.createUser({email:normalizedEmail,password:temporaryPassword,email_confirm:true,user_metadata:{full_name,siape,role}});
    if (error) throw error;
    const {error:profileError} = await admin.from("profiles").insert({id:created.user.id,email:normalizedEmail,siape,full_name,role});
    if (profileError) { await admin.auth.admin.deleteUser(created.user.id); throw profileError; }
    const {error:serverError} = await admin.from("servers").upsert({email:normalizedEmail,siape,full_name,active:true},{onConflict:"siape"});
    if (serverError) { await admin.from("profiles").delete().eq("id",created.user.id); await admin.auth.admin.deleteUser(created.user.id); throw serverError; }
    return new Response(JSON.stringify({ok:true,id:created.user.id}),{headers:{...cors,"Content-Type":"application/json"}});
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return new Response(JSON.stringify({ok:false,error:message}),{status:400,headers:{...cors,"Content-Type":"application/json"}});
  }
});

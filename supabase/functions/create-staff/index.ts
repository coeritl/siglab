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
    const {data:profile} = await admin.from("profiles").select("role,active").eq("id",user.id).single();
    if (!profile?.active || profile.role !== "tecnico") throw new Error("Sem permissão");
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
    const {email,password,siape,full_name,role} = body;
    if (!email || !password || !siape || !full_name || !["tecnico","supervisor"].includes(role)) throw new Error("Dados inválidos");
    const {data:created,error} = await admin.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{full_name,siape,role}});
    if (error) throw error;
    const {error:profileError} = await admin.from("profiles").insert({id:created.user.id,email,siape,full_name,role});
    if (profileError) { await admin.auth.admin.deleteUser(created.user.id); throw profileError; }
    return new Response(JSON.stringify({ok:true,id:created.user.id}),{headers:{...cors,"Content-Type":"application/json"}});
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return new Response(JSON.stringify({ok:false,error:message}),{status:400,headers:{...cors,"Content-Type":"application/json"}});
  }
});

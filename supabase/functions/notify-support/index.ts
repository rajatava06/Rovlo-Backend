// =============================================================================
//  notify-support — push notifications for the Support chat.
//
//  Called by the app right after a support message is stored:
//    • a customer wrote  → every support agent's phone gets
//                          "New support message from <name>"
//    • an agent replied  → that customer's phone gets "Rovlo Support replied"
//
//      supabase.functions.invoke('notify-support', body: { thread_user?, preview })
//
//  Secret required: FCM_SERVICE_ACCOUNT (Firebase service-account JSON).
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function b64url(input: ArrayBuffer | string) {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let s = "";
  bytes.forEach((b) => (s += String.fromCharCode(b)));
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function googleAccessToken(sa: { client_email: string; private_key: string }) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claim}`));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claim}.${b64url(sig)}`,
    }),
  });
  if (!res.ok) throw new Error(`Google token error: ${await res.text()}`);
  return (await res.json()).access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: userData } = await userClient.auth.getUser();
    const caller = userData?.user;
    if (!caller) return json({ error: "Sign in required" }, 401);

    const { thread_user, preview } = await req.json().catch(() => ({}));
    const text = String(preview ?? "").slice(0, 120) || "📷 Photo";

    const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!saRaw) return json({ sent: 0, note: "FCM_SERVICE_ACCOUNT secret is not set." });
    const sa = JSON.parse(saRaw);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: isAgent } = await userClient.rpc("is_support_agent");

    let tokens: { id: string; token: string }[] = [];
    let title: string;

    if (isAgent === true && thread_user) {
      // An agent replied → tell that customer.
      const { data } = await admin.from("profiles").select("id,fcm_token").eq("id", thread_user).not("fcm_token", "is", null);
      tokens = (data ?? []).map((r) => ({ id: r.id, token: r.fcm_token }));
      title = "Rovlo Support replied";
    } else {
      // A customer wrote → tell all agents.
      const { data: agents } = await admin.from("support_agents").select("email");
      const emails = (agents ?? []).map((a) => String(a.email).toLowerCase());
      const { data: me } = await admin.from("profiles").select("name").eq("id", caller.id).maybeSingle();
      if (emails.length) {
        const { data } = await admin.from("profiles").select("id,email,fcm_token").not("fcm_token", "is", null);
        tokens = (data ?? [])
          .filter((r) => emails.includes(String(r.email ?? "").toLowerCase()))
          .map((r) => ({ id: r.id, token: r.fcm_token }));
      }
      title = `New support message${me?.name ? ` from ${me.name}` : ""}`;
    }

    if (!tokens.length) return json({ sent: 0, note: "No registered devices to notify." });

    const accessToken = await googleAccessToken(sa);
    const endpoint = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
    let sent = 0;
    const dead: string[] = [];
    await Promise.all(tokens.map(async (t) => {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({ message: { token: t.token, notification: { title, body: text } } }),
      });
      if (res.ok) sent++;
      else if (res.status === 404 || res.status === 400) dead.push(t.id);
    }));
    if (dead.length) await admin.from("profiles").update({ fcm_token: null }).in("id", dead);

    return json({ sent });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});

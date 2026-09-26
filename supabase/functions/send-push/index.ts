// =============================================================================
//  send-push — delivers an admin broadcast as a real push notification (FCM).
//
//  Called by the Admin Panel right after it inserts a row into `broadcasts`:
//      supabase.functions.invoke('send-push', body: { title, body, target })
//
//  Secret required:  FCM_SERVICE_ACCOUNT  (the Firebase service-account JSON,
//  pasted as one line). Only admins (public.is_admin()) may call it.
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
  const assertion = `${header}.${claim}.${b64url(sig)}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
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
    const { data: isAdmin } = await userClient.rpc("is_admin");
    if (isAdmin !== true) return json({ error: "Admins only" }, 403);

    const { title, body, target } = await req.json();
    if (!title || !body) return json({ error: "title and body are required" }, 400);

    const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!saRaw) return json({ sent: 0, note: "FCM_SERVICE_ACCOUNT secret is not set." });
    const sa = JSON.parse(saRaw);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    let q = admin.from("profiles").select("id,fcm_token").not("fcm_token", "is", null).eq("is_blocked", false);
    if (target === "Active Users") q = q.eq("is_paused", false);
    const { data: rows, error } = await q;
    if (error) throw error;

    const accessToken = await googleAccessToken(sa);
    const endpoint = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

    let sent = 0;
    const dead: string[] = [];
    // Small batches keep us well inside the function's time limit.
    for (let i = 0; i < (rows ?? []).length; i += 50) {
      const batch = rows!.slice(i, i + 50);
      await Promise.all(batch.map(async (r) => {
        const res = await fetch(endpoint, {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: { token: r.fcm_token, notification: { title, body } },
          }),
        });
        if (res.ok) sent++;
        else if (res.status === 404 || res.status === 400) dead.push(r.id);
      }));
    }
    if (dead.length) await admin.from("profiles").update({ fcm_token: null }).in("id", dead);

    return json({ sent, removedInvalid: dead.length });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});

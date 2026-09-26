// =============================================================================
//  notify-like — push notification when someone likes you / you match.
//
//  Called by the app right after a like is stored:
//      supabase.functions.invoke('notify-like', body: { to: '<user id>' })
//
//  • Only a like → "<name> liked you 💙 — open Chats to accept"
//  • Both liked  → "It's a match with <name> 🎉"
//
//  The function re-checks the like in the database, so it cannot be used to
//  spam arbitrary notifications. Secret required: FCM_SERVICE_ACCOUNT.
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

    const { to } = await req.json().catch(() => ({}));
    if (!to || to === caller.id) return json({ error: "to is required" }, 400);

    const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!saRaw) return json({ sent: 0, note: "FCM_SERVICE_ACCOUNT secret is not set." });
    const sa = JSON.parse(saRaw);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // The like must really exist.
    const { data: like } = await admin.from("likes").select("kind")
      .eq("from_user", caller.id).eq("to_user", to).eq("kind", "like").maybeSingle();
    if (!like) return json({ sent: 0, note: "No like found." });

    const { data: back } = await admin.from("likes").select("kind")
      .eq("from_user", to).eq("to_user", caller.id).eq("kind", "like").maybeSingle();
    const matched = !!back;

    const { data: me } = await admin.from("profiles").select("name").eq("id", caller.id).maybeSingle();
    const { data: target } = await admin.from("profiles")
      .select("fcm_token,is_blocked").eq("id", to).maybeSingle();
    if (!target?.fcm_token || target.is_blocked) return json({ sent: 0, note: "Recipient has no device." });

    const name = (me?.name as string | undefined)?.split(" ")[0] || "Someone";
    const title = matched ? `It's a match with ${name}! 🎉` : `${name} liked you 💙`;
    const body = matched ? "You can chat now — say hi!" : "Open Chats to accept and start talking.";

    const accessToken = await googleAccessToken(sa);
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ message: { token: target.fcm_token, notification: { title, body } } }),
    });
    if (res.status === 404 || res.status === 400) {
      await admin.from("profiles").update({ fcm_token: null }).eq("id", to);
    }
    return json({ sent: res.ok ? 1 : 0, matched });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});

// =============================================================================
//  sync-events — fills public.events for a city from real event sources.
//
//  Called by the app whenever the Hotlist location changes:
//      supabase.functions.invoke('sync-events', body: { city, lat, lng })
//
//  Sources (each is optional — a provider is used only if its key is set):
//    • SEARCHAPI_KEY      Google Events via SearchApi.io (engine=google_events).
//                         Returns real District / BookMyShow / etc. ticket links.
//    • SERPAPI_KEY        Google Events via SerpApi (same idea, different vendor)
//    • TICKETMASTER_KEY   Ticketmaster Discovery API (free, US/EU/AU/… coverage)
//
//  Results are cached per city for EVENTS_TTL_HOURS (default 24) so the free
//  quotas of the providers last. API keys never reach the app.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const TTL_HOURS = Number(Deno.env.get("EVENTS_TTL_HOURS") ?? "24");
const SEARCHAPI_KEY = Deno.env.get("SEARCHAPI_KEY");
const SERPAPI_KEY = Deno.env.get("SERPAPI_KEY");
const SERPAPI_GL = Deno.env.get("SERPAPI_GL") ?? "in";
const TM_KEY = Deno.env.get("TICKETMASTER_KEY");

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CITY_ALIASES: Record<string, string> = {
  bangalore: "bengaluru",
  bombay: "mumbai",
  calcutta: "kolkata",
  madras: "chennai",
  "new delhi": "delhi",
  "delhi ncr": "delhi",
  gurgaon: "gurugram",
  "new york city": "new york",
};

const CATEGORY_COLORS: Record<string, string> = {
  Nightlife: "#8B5CF6",
  "Live Music": "#00A6FB",
  Festivals: "#FF5722",
  Comedy: "#FFB800",
  "Food & Drink": "#EC4899",
  "Art & Culture": "#D97706",
  Sports: "#10B981",
  Events: "#2196F3",
};

type EventRow = Record<string, unknown>;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function cityKeyOf(city: string) {
  const k = city.trim().toLowerCase().replace(/\s+/g, " ");
  return CITY_ALIASES[k] ?? k;
}

function classify(text: string, hint = ""): string {
  const t = `${text} ${hint}`.toLowerCase();
  if (/(stand-?up|comedy|comedian|open mic)/.test(t)) return "Comedy";
  if (/(festival|\bfest\b|carnival|mela)/.test(t)) return "Festivals";
  if (/(nightlife|night club|nightclub|club night|\bdj\b|party|rooftop)/.test(t)) return "Nightlife";
  if (/(food|wine|tasting|brunch|culinary|beer|cocktail|dining|street food)/.test(t)) return "Food & Drink";
  if (/(concert|live music|band|gig|music|orchestra|jazz|acoustic|tour)/.test(t)) return "Live Music";
  if (/(art|exhibition|theatre|theater|museum|heritage|dance|culture|workshop|film|drama)/.test(t)) return "Art & Culture";
  if (/(sport|match|cricket|football|marathon|run|league|tournament)/.test(t)) return "Sports";
  return "Events";
}

async function sha1(s: string) {
  const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

// Google Events only gives a free-text "when" ("Sat, Oct 28, 7 – 11 PM").
// Parse it best-effort so events can be sorted; the text itself is what we show.
function parseWhen(when?: string): { startsAt: string | null; time: string | null } {
  if (!when) return { startsAt: null, time: null };
  const m = when.toLowerCase().match(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})\b/);
  const tm = when.match(/(\d{1,2})(?::(\d{2}))?\s*(AM|PM)/i);
  const time = tm ? when.slice(when.indexOf(tm[0])).trim() : null;
  if (!m) return { startsAt: null, time };
  const now = new Date();
  const month = MONTHS.indexOf(m[1]);
  const day = Number(m[2]);
  let hour = 19;
  let minute = 0;
  if (tm) {
    hour = Number(tm[1]) % 12 + (tm[3].toUpperCase() === "PM" ? 12 : 0);
    minute = Number(tm[2] ?? 0);
  }
  let year = now.getUTCFullYear();
  let d = new Date(Date.UTC(year, month, day, hour, minute));
  if (d.getTime() < now.getTime() - 36 * 3600 * 1000) {
    d = new Date(Date.UTC(year + 1, month, day, hour, minute));
  }
  return { startsAt: d.toISOString(), time };
}

// ── Provider: Google Events via SearchApi.io ────────────────────────────────
async function fromSearchApi(city: string, cityKey: string): Promise<EventRow[]> {
  if (!SEARCHAPI_KEY) return [];
  const url = new URL("https://www.searchapi.io/api/v1/search");
  url.searchParams.set("engine", "google_events");
  url.searchParams.set("q", `Events in ${city}`);
  url.searchParams.set("hl", "en");
  url.searchParams.set("gl", SERPAPI_GL);
  url.searchParams.set("api_key", SEARCHAPI_KEY);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`SearchApi ${res.status}: ${await res.text()}`);
  const data = await res.json();
  const list: any[] = data.events ?? [];

  const rows: EventRow[] = [];
  for (const e of list) {
    const title: string | undefined = e.title;
    if (!title) continue;
    // e.start_time looks like "Sep 26, 8:00 PM"; e.date like "Sat, Sep 26".
    const { startsAt, time } = parseWhen(e.start_time ?? e.date);
    const category = classify(title, e.category ?? "");
    const q = encodeURIComponent(`${title} ${city}`);
    const link: string | undefined = e.link;
    const seller: string | undefined = e.seller;
    const onDistrict = !!link && /(^|\.)district\.in/.test(seller ?? link);
    rows.push({
      source: "searchapi",
      external_id: e.entity_id ?? await sha1(`${title}|${e.start_time ?? ""}|${cityKey}`),
      title,
      category,
      city,
      city_key: cityKey,
      venue: e.venue ?? null,
      address: e.address ?? null,
      starts_at: startsAt,
      date_label: e.date ?? null,
      time_label: time,
      image_url: e.thumbnail ?? null,
      description: e.category ? `${e.category} at ${e.venue ?? city}.` : null,
      ticket_url: link ?? null,
      google_url: `https://www.google.com/search?q=${q}+tickets`,
      // Real District listing when Google found one, otherwise a District search.
      district_url: onDistrict ? link : `https://www.google.com/search?q=site:district.in+${q}`,
      tags: seller ? [`Tickets: ${seller}`] : [],
      // Google lists the most relevant events first — call those "Hot picks".
      is_featured: typeof e.position === "number" && e.position <= 5,
      theme_color: CATEGORY_COLORS[category],
    });
  }
  return rows;
}

// ── Provider: Google Events via SerpApi ─────────────────────────────────────
async function fromSerpApi(city: string, cityKey: string): Promise<EventRow[]> {
  if (!SERPAPI_KEY) return [];
  const url = new URL("https://serpapi.com/search.json");
  url.searchParams.set("engine", "google_events");
  url.searchParams.set("q", `Events in ${city}`);
  url.searchParams.set("hl", "en");
  url.searchParams.set("gl", SERPAPI_GL);
  url.searchParams.set("api_key", SERPAPI_KEY);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`SerpApi ${res.status}: ${await res.text()}`);
  const data = await res.json();
  const list: any[] = data.events_results ?? [];

  const rows: EventRow[] = [];
  for (const e of list) {
    const title: string = e.title;
    if (!title) continue;
    const when: string | undefined = e.date?.when;
    const { startsAt, time } = parseWhen(when);
    const address: string[] = e.address ?? [];
    const category = classify(title, e.description ?? "");
    const ticket = (e.ticket_info ?? [])[0];
    const dateLabel = when ? when.split(",").slice(0, 2).join(",").trim() : e.date?.start_date ?? null;
    const q = encodeURIComponent(`${title} ${city}`);
    rows.push({
      source: "serpapi",
      external_id: await sha1(`${title}|${when ?? ""}|${cityKey}`),
      title,
      category,
      city,
      city_key: cityKey,
      venue: e.venue?.name ?? address[0] ?? null,
      address: address.join(", ") || null,
      starts_at: startsAt,
      date_label: dateLabel,
      time_label: time,
      image_url: e.image ?? e.thumbnail ?? null,
      description: e.description ?? null,
      ticket_url: ticket?.link ?? e.link ?? null,
      google_url: e.link ?? `https://www.google.com/search?q=${q}+tickets`,
      district_url: `https://www.google.com/search?q=site:district.in+${q}`,
      rating: e.venue?.rating ? Math.min(5, Number(e.venue.rating)) : null,
      tags: (e.venue?.reviews ?? 0) > 500 ? ["Popular venue"] : [],
      theme_color: CATEGORY_COLORS[category],
    });
  }
  return rows;
}

// ── Provider: Ticketmaster Discovery API ────────────────────────────────────
async function fromTicketmaster(
  city: string,
  cityKey: string,
  lat?: number,
  lng?: number,
): Promise<EventRow[]> {
  if (!TM_KEY) return [];
  const url = new URL("https://app.ticketmaster.com/discovery/v2/events.json");
  url.searchParams.set("apikey", TM_KEY);
  url.searchParams.set("size", "40");
  url.searchParams.set("sort", "date,asc");
  if (lat != null && lng != null) {
    url.searchParams.set("latlong", `${lat},${lng}`);
    url.searchParams.set("radius", "60");
    url.searchParams.set("unit", "km");
  } else {
    url.searchParams.set("city", city);
  }
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Ticketmaster ${res.status}: ${await res.text()}`);
  const data = await res.json();
  const list: any[] = data._embedded?.events ?? [];

  return list.map((e) => {
    const venue = e._embedded?.venues?.[0];
    const segment = e.classifications?.[0]?.segment?.name ?? "";
    const genre = e.classifications?.[0]?.genre?.name ?? "";
    const category = classify(e.name, `${segment} ${genre}`);
    const price = e.priceRanges?.[0];
    const local = e.dates?.start?.localDate as string | undefined;
    const localTime = e.dates?.start?.localTime as string | undefined;
    const dateLabel = local
      ? new Date(`${local}T00:00:00Z`).toLocaleDateString("en-GB", {
        weekday: "short", day: "2-digit", month: "short", year: "numeric", timeZone: "UTC",
      })
      : null;
    let timeLabel: string | null = null;
    if (localTime) {
      const [h, m] = localTime.split(":").map(Number);
      timeLabel = `${h % 12 || 12}:${String(m).padStart(2, "0")} ${h >= 12 ? "PM" : "AM"}`;
    }
    const cur = price?.currency === "USD" ? "$" : price?.currency === "EUR" ? "€" :
      price?.currency === "GBP" ? "£" : `${price?.currency ?? ""} `;
    const img = [...(e.images ?? [])].sort((a: any, b: any) => (b.width ?? 0) - (a.width ?? 0))[0];
    const lineup = (e._embedded?.attractions ?? []).map((a: any) => a.name).filter(Boolean);
    return {
      source: "ticketmaster",
      external_id: e.id,
      title: e.name,
      category,
      city: venue?.city?.name ?? city,
      city_key: cityKey,
      venue: venue?.name ?? null,
      address: [venue?.address?.line1, venue?.city?.name].filter(Boolean).join(", ") || null,
      lat: venue?.location?.latitude ? Number(venue.location.latitude) : null,
      lng: venue?.location?.longitude ? Number(venue.location.longitude) : null,
      starts_at: e.dates?.start?.dateTime ?? null,
      date_label: dateLabel,
      time_label: timeLabel,
      image_url: img?.url ?? null,
      price_text: price ? `${cur}${Math.round(price.min)} onwards` : null,
      description: e.info ?? e.pleaseNote ?? null,
      lineup,
      ticket_url: e.url ?? null,
      google_url: `https://www.google.com/search?q=${encodeURIComponent(`${e.name} ${city} tickets`)}`,
      district_url: `https://www.google.com/search?q=site:district.in+${encodeURIComponent(e.name)}`,
      tags: [],
      theme_color: CATEGORY_COLORS[category],
    };
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    // Only signed-in app users may trigger a sync (protects the provider quota).
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData } = await userClient.auth.getUser();
    if (!userData?.user) return json({ error: "Sign in required" }, 401);

    const body = await req.json().catch(() => ({}));
    const city: string = String(body.city ?? "").trim();
    if (!city) return json({ error: "city is required" }, 400);
    const lat = typeof body.lat === "number" ? body.lat : undefined;
    const lng = typeof body.lng === "number" ? body.lng : undefined;
    const force = body.force === true;
    const cityKey = cityKeyOf(city);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    if (!force) {
      const { data: log } = await admin
        .from("event_sync_log").select("fetched_at,result_count")
        .eq("city_key", cityKey).maybeSingle();
      if (log && Date.now() - new Date(log.fetched_at).getTime() < TTL_HOURS * 3600 * 1000) {
        return json({ cached: true, count: log.result_count });
      }
    }

    if (!SEARCHAPI_KEY && !SERPAPI_KEY && !TM_KEY) {
      return json({ cached: false, count: 0, note: "No event provider key configured (SEARCHAPI_KEY / SERPAPI_KEY / TICKETMASTER_KEY)." });
    }

    const started = new Date().toISOString();
    const errors: string[] = [];
    const results = await Promise.all([
      fromSearchApi(city, cityKey).catch((e) => { errors.push(String(e)); return []; }),
      fromSerpApi(city, cityKey).catch((e) => { errors.push(String(e)); return []; }),
      fromTicketmaster(city, cityKey, lat, lng).catch((e) => { errors.push(String(e)); return []; }),
    ]);
    const rows = results.flat();

    if (rows.length > 0) {
      const { error } = await admin.from("events")
        .upsert(rows.map((r) => ({ ...r, fetched_at: started, is_active: true })), {
          onConflict: "source,external_id",
        });
      if (error) throw error;

      // Drop this city's provider events that no longer appear in the feed.
      await admin.from("events").delete()
        .eq("city_key", cityKey).in("source", ["searchapi", "serpapi", "ticketmaster"])
        .lt("fetched_at", started);
    }

    // Cache the result unless every provider failed, so a temporary outage is
    // retried on the next visit instead of being remembered for a day.
    if (rows.length > 0 || errors.length === 0) {
      await admin.from("event_sync_log").upsert({
        city_key: cityKey,
        provider: [SEARCHAPI_KEY ? "searchapi" : null, SERPAPI_KEY ? "serpapi" : null, TM_KEY ? "ticketmaster" : null].filter(Boolean).join("+"),
        fetched_at: started,
        result_count: rows.length,
      });
    }

    return json({ cached: false, count: rows.length, errors });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});

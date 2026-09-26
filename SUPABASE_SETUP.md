# Rovlo — Supabase setup (database, login, events, map, release)

The Flutter app now talks **directly to Supabase**. There is no server to host.
Security comes from Row Level Security (RLS) written in `supabase/schema.sql`.

```
Flutter app ──► Supabase Auth      (Google / Apple sign-in, sessions)
            ──► Postgres + RLS     (profiles, likes, chats, events, admins…)
            ──► Storage            (profile photos, chat images)
            ──► Realtime           (live chat + admin broadcasts)
            ──► Edge Functions     sync-events    (Google Events / Ticketmaster → events table)
                                   send-push      (admin broadcast → FCM push)
                                   notify-support (support chat → FCM push)
                                   notify-like    ("X liked you" / match → FCM push)
                                   notify-chat    (chat request / accepted / new message → FCM push)
```

The old Node server in this folder (`src/`) is **no longer used** by the app
(it only kept data in memory). You can delete it or keep it for reference.

---

## 0. What you must give / do (checklist)

| # | Item | Needed for | Required? |
|---|------|-----------|-----------|
| 1 | Supabase **Project URL** + **anon key** | everything | **Yes** |
| 2 | Google **Web client ID + secret** — **reuse the ones Firebase already created** (see §3) | Google sign-in | **Yes** |
| 3 | Your app's **SHA-1 / SHA-256** fingerprints (debug + release) added in Google Cloud / Firebase | Google sign-in on Android | **Yes** |
| 4 | **SearchApi.io key** (recommended), or SerpApi / Ticketmaster (set as Supabase secrets) | real events in the Hotlist | One of them |
| 5 | **MapTiler key** | nicer map tiles + satellite | No (map works without) |
| 6 | Firebase **service-account JSON** (Supabase secret) | real push notifications | No |
| 7 | Apple Services ID + key | Sign in with Apple (iOS) | Only for iOS release |
| 8 | An **SMS provider** (Twilio etc.) | real phone-OTP | Not wired yet (see §9) |
| 9 | *(nothing new)* — re-run `schema.sql`, deploy `notify-chat` | map chat requests + encrypted chat (§7b-3) | Yes (SQL) / push optional |

---

## 1. Create the Supabase project (free)

1. Go to <https://supabase.com> → **Start your project** → sign in with GitHub.
2. **New project** → name `rovlo`, choose a strong database password (save it),
   pick the region closest to your users (e.g. *Mumbai / ap-south-1*).
3. Wait ~2 minutes until the project is ready.
4. **Project Settings → API**. Copy:
   * **Project URL** → `SUPABASE_URL`
   * **anon public** key → `SUPABASE_ANON_KEY`

   ⚠️ Never put the **secret / service_role** key (`sb_secret_…`) in the app or
   in git. The app only ever gets the **publishable** key. If a secret key was
   ever pasted into a chat or committed, regenerate it (Settings → API Keys).

## 2. Create the tables (one paste)

1. Dashboard → **SQL Editor → New query**.
2. Open `Rovlo-Backend/supabase/schema.sql`, copy everything, paste, **Run**.
   It is safe to run again later.
   (Re-run it after updating the app: the "Going to…" trips feature added section 6,
   `save_trip`, `travelers_going_to`, `delete_trip` and new `trips` columns.)
3. Check **Table Editor**: you should see `profiles`, `likes`, `messages`,
   `broadcasts`, `events`, `trips`, `saved_events`, `admin_emails`, …
4. **Admins:** copy `supabase/seed_admins.example.sql` to `seed_admins.sql`
   (git-ignored), put your real admin / support emails in it and run it in the
   SQL editor. To add another admin later:
   `insert into public.admin_emails(email) values ('someone@gmail.com');`
   (the person just signs in with that Google account — no app update needed).

## 3. Google sign-in (reuses your existing Firebase setup)

You already configured Google sign-in in Firebase (SHA-1 fingerprints,
`google-services.json`, the Web client). Nothing of that is thrown away — the
app still uses the same Google account picker. Supabase only needs to *trust*
the same Google Web client:

1. **Firebase Console → Authentication → Sign-in method → Google → “Web SDK
   configuration”**. Copy the **Web client ID** and **Web client secret**.
   (Put that Web client ID into `GOOGLE_WEB_CLIENT_ID` in `.env`.)
2. **Supabase → Authentication → Providers → Google** → enable, paste that
   **Client ID** and **Client Secret**, turn ON **“Skip nonce check”**, save.
3. **Supabase → Authentication → URL Configuration** — nothing needed for the
   native app.

Because the SHA-1 keys are already registered in Firebase, Google sign-in works
the same as before. Just make sure the **release** keystore’s SHA-1 (and the
Play App-Signing SHA-1 if you publish on Google Play) is added there too:
```
keytool -list -v -keystore <your-release>.jks -alias <alias>
```
Firebase → Project settings → Your apps → Android → *Add fingerprint*.

### Optional: guest button for testing
Debug builds show “Explore as Guest”. It needs **Authentication → Sign In /
Providers → Anonymous sign-ins → enable**. It never appears in release builds.

## 4. Put the values in the app (`Rovlo/assets/config/app_config.json` and/or `Rovlo/.env`)

> `app_config.json` (copy of `app_config.example.json`) is bundled into the app and
> git-ignored, so plain `flutter run` works. `.env` is optional for these values.

```
SUPABASE_URL=https://xxxx.supabase.co
SUPABASE_ANON_KEY=sb_publishable_...     # the *publishable* (or legacy anon) key — NEVER the secret key
GOOGLE_WEB_CLIENT_ID=123-abc.apps.googleusercontent.com
MAPTILER_KEY=            # optional
# + the existing FIREBASE_* lines (push notifications)
```
Run / build **always** with the file:
```
flutter run --dart-define-from-file=.env
flutter build apk --release --dart-define-from-file=.env
flutter build appbundle --release --dart-define-from-file=.env
```
If you forget `--dart-define-from-file`, the app opens but sign-in shows
*“The app is not connected to its server”*. `.env` is git-ignored — keep it out
of the repository.

## 5. Events in the Hotlist (Google Events / District)

**District (by Zomato) has no public API** and scraping it breaks its terms and
breaks whenever they change their site, so Rovlo does not do that. Instead:

* **Google Events via SearchApi.io (recommended) or SerpApi** – real,
  location-wise events for Indian and global cities (the same data you see when
  you Google “events in Pune”). Results even include the seller’s own link —
  district.in, bookmyshow, etc. — and Rovlo opens those directly.
* **Ticketmaster Discovery API** – free and generous, but covers mainly
  US/Canada/UK/EU/Australia/Mexico (not India).
* In the ticket sheet the “Find on District” button opens a district.in search
  for that event, so users can still compare there.

### 5a. Get a key
* **SearchApi.io**: <https://www.searchapi.io> → *Dashboard → API key*.
* **SerpApi** (alternative): <https://serpapi.com> → *Dashboard → API key*.
  Both have a small free monthly quota (check their pricing pages). Because results are cached per city (24 h by default), one
  search serves *all* users of that city for a day.
* **Ticketmaster**: <https://developer.ticketmaster.com> → *Get your API key*
  (free, 5 000 calls/day) → copy the **Consumer Key**.

### 5b. Deploy the function (one time, needs Node)
```bash
npm i -g supabase                # or: npx supabase ...
cd Rovlo-Backend
supabase login
supabase link --project-ref YOUR-PROJECT-REF
supabase secrets set SEARCHAPI_KEY=xxxxxxxx          # or SERPAPI_KEY=…
supabase secrets set TICKETMASTER_KEY=xxxxxxxx     # optional
supabase secrets set SERPAPI_GL=in                 # country bias for Google (in, us, gb…)
supabase secrets set EVENTS_TTL_HOURS=24           # optional
supabase functions deploy sync-events
```
How it works: when the Hotlist opens, the app detects the city (GPS →
reverse-geocode), shows what is already stored, and calls `sync-events`. The
function refreshes that city only if it is older than the TTL, so the free
quotas last. Users can also type any other city.

To test manually: Dashboard → **Edge Functions → sync-events → Test**
(body `{"city":"Pune","force":true}` — must be sent with a signed-in user token,
so easier to test from the app).

You can also add your own events: Table Editor → `events` → insert a row with
`source = admin`, `title`, `city`, `city_key` (lower-case city), `starts_at`, …

## 6. Map (free)

The map uses **OpenStreetMap data through `flutter_map` — no key, no billing.**
For a serious launch, OpenStreetMap's public tile server asks apps not to
generate heavy traffic, so create a free **MapTiler** account
(<https://cloud.maptiler.com> → *Account → Keys*), copy the key into
`MAPTILER_KEY` in `.env`. Free tier: 100 000 tile requests/month, includes real
satellite imagery and a dark map. Without the key, the app uses OSM (street),
OpenTopoMap (terrain) and Esri (satellite) — fine for testing and light use.

Place search uses OpenStreetMap **Nominatim** (max 1 request/second, only on
submit). Location permissions are already in the Android manifest.

## 7. Real push notifications + Support chat

### 7a. Who is an admin / support agent
* **Admins** (`admin_emails` table).
  They see the Admin Dashboard (Profile tab → *Admin Panel*): the roster of
  **all signed-in users**, block / delete, and *Push Notification*.
* **Support agents** (`support_agents` table). Their Admin
  Dashboard gets a third tab, **Support**, with every customer conversation.
  Add another agent with
  `insert into public.support_agents(email) values ('someone@gmail.com');`

### 7b. Push notifications (admin broadcasts + support alerts)
Sending needs a Firebase *service account* (only the server ever sees it):
1. Firebase Console → **Project settings → Service accounts → Generate new
   private key** → a `.json` file downloads. In *Google Cloud → APIs* make sure
   **Firebase Cloud Messaging API (V1)** is enabled (it is by default).
2. Supabase Dashboard → **Edge Functions → Secrets** → *Add new secret*:
   name `FCM_SERVICE_ACCOUNT`, value = the **entire contents** of that JSON file.
3. Deploy the functions (needs `npx supabase login`, or send me a temporary
   access token):
   ```
   npx supabase functions deploy send-push
   npx supabase functions deploy notify-support
   npx supabase functions deploy notify-like
   ```
Phones register their token automatically after sign-in (stored in
`profiles.fcm_token`). Users must allow notifications (Android 13+ asks once).

### 7b-2. Likes → requests → chat
* Liking someone sends them a **request**. They see it in **Chats → New Matches**
  as “Likes you” (with a notification + push) and can **Accept** or **Decline**.
* Until they accept, you see them as “Pending” and nobody can message.
* Accept = like back → it becomes a match and chat opens (enforced by the
  database, not only the app). Re-run `supabase/schema.sql` once for this.

### 7b-3. Map → chat request → encrypted 1-to-1 chat

Everything here is **free** and needs **no new keys** — it only needs the SQL
re-run and one more function deployed.

**What the app does**
* **Map:** everyone who is sharing their location (Ghost Mode off) appears with
  their profile picture — even if they never opened the map tab. They stay at
  their last live location (card shows “Live location · 3 hours ago”) until
  their next update. Pins refresh every ~20 s; a **green dot** = online now.
* **Share location in chat:** attach (📎) → *Share my location* → the other
  person taps the bubble and lands on the in-app map with a pin + Directions.
* **Notifications:** a first message shows “New chat from …”; tapping any chat
  notification opens the app on the **Chats** tab. Re-deploy `notify-chat`.
* **Tap a pin → "Request to chat".** The other person gets an in-app banner with
  **Accept / Decline** (also under *Chats → Chat requests*) and, if the app is
  closed, a push notification. You can chat only after they accept
  (enforced by the database, not just the app). A declined request can be
  re-sent after 24 h.
* **Chat:** end-to-end encrypted, live *typing…*, **ticks** (🕓 sending · ✓ sent ·
  ✓✓ delivered · blue ✓✓ read), **Online / Offline** in the header and chat list,
  encrypted photos, and a **microphone** button for voice typing in
  **English and हिन्दी**.

**Setup (once)**
1. Re-run `supabase/schema.sql` in the SQL editor (section 14). It adds
   `chat_requests`, `user_keys`, encrypted-message columns, delivery receipts,
   the private `chat-secure` storage bucket, and makes the database **refuse
   plaintext messages**.
2. Realtime is used for presence / typing / receipts. Nothing to switch on — but
   confirm *Database → Replication → supabase_realtime* lists `messages`,
   `chat_requests` (the SQL does this for you).
3. Push for requests / messages (optional, same `FCM_SERVICE_ACCOUNT` secret as
   §7b):
   ```
   npx supabase functions deploy notify-chat
   ```
   Without it everything still works while the app is open; only the
   "app is closed" push is missing.
4. Rebuild the app (`flutter pub get`, then run/build with
   `--dart-define-from-file=.env` as before). New Android permission:
   `RECORD_AUDIO` (already added).

**How the encryption works (and its limits)**
* Every phone creates an X25519 key pair on first login. The **private key never
  leaves the phone** (Android Keystore / iOS Keychain); only the public key is
  stored in `user_keys`.
* Messages and photos are sealed with AES-256-GCM using a secret only the two
  phones can compute. The database, Supabase staff and Rovlo see ciphertext only.
  Push notifications never contain message text.
* In a chat tap the 🔒 icon to see the **safety code**; if it is identical on
  both phones nobody is in the middle.
* **One phone per account.** The private key is not backed up: after uninstalling
  the app / new phone, old messages cannot be read (new ones work). Logging into
  the same account on two phones at once will make them overwrite each other's key.
* The Rovlo assistant and *Rovlo Support* threads are **not** end-to-end
  encrypted (support staff must be able to read them).
* People who have not updated / opened the new app have no key yet — you'll see
  "This person has not set up secure chat yet" until they do.

**Voice typing** uses the phone's own speech recogniser (Google on Android, Apple
on iOS) — free. Hindi needs the Hindi voice pack: *Settings → Google → Voice →
Languages* (most phones have it already). Tap the mic, pick English / हिन्दी,
speak, tap **Done**; the text lands in the message box so you can check it first.

**Scale note:** *online* status uses one shared Realtime Presence channel, which
is perfect for thousands of users on the free tier but should move to
per-region channels if you ever reach tens of thousands online at once.

### 7b-4. Profile verification (blue tick) — photo verification, no ID

1. **User** (Profile → Verify): step 1 a straight **selfie**, step 2 a selfie doing a
   **random pose** (👍 ✌️ 👋 …) — the front camera opens *inside the app* with an
   animated oval guide and a 3-2-1 countdown. Then "Sent for verification!".
2. **Admin** (Profile → Admin Panel → **Verification** tab): sees the profile photos
   plus both selfies (tap to zoom) and the pose that was asked, then **Approve**
   (blue tick + live notice in the user's app) or **Reject** (with a reason).
3. Photos live in the **private** `verification-docs` bucket (owner + admins only)
   and are **deleted as soon as the request is reviewed**.
4. Only an admin approval can set `is_verified`. Re-run `supabase/schema.sql`
   (section 15) to enable it.

**Why no ID / Aadhaar:** collecting Aadhaar (or ID cards) puts Indian ID-specific
rules on you. This flow collects **no identity document** — only two selfies used
for a one-off comparison and then deleted. General privacy law (India's DPDP Act)
still applies to face photos: keep the consent text on the screen, delete after
review (done automatically) and mention it in your privacy policy.

### 7b-6. SOS button

Profile → **SOS** → confirm → full-screen emergency mode:
* **Loud siren** on the phone's *alarm* volume at maximum (works on silent),
  vibration, and the screen stays on. The user's volume is restored afterwards.
* Finds the **exact location + street address** and builds a message with a
  Google Maps link.
* **Call 112** (911 / 999 / 000 / 111 by country) opens the dialler ready to call.
* **Text my location** opens the SMS app with the message already written to all
  saved emergency contacts; **Share location** sends it through WhatsApp etc.

Honest limits: Android/iOS do not let an app place a call or send an SMS silently
(and Google Play forbids it), so the person taps **Call / Send** once; and the app
cannot itself dispatch police or an ambulance — the call to 112 does that.

### 7b-5. Rovlo Plus page

Free is active; **Plus ₹199** and **Advanced ₹499** are shown slightly blurred with
a "COMING SOON" label until you integrate real payments and set
`AppConstants.paymentsEnabled = true` (see §9). Tiers can only be changed by the
server, never by the app.

### 7c. Support chat
* Every user has a **“Rovlo Support”** conversation at the top of the Chats tab
  (text and photos only).
* Messages are stored in `support_messages` (RLS: users see only their own
  thread; only support agents see all).
* Agents open **Admin Dashboard → Support**, tap a customer, and reply. New
  messages appear live and trigger a push notification to the agents’ phones
  (and a push to the customer when support replies).
* Re-run `supabase/schema.sql` in the SQL editor once to create the support
  tables (safe to run again).

## 8. Make sure it works in the RELEASE build

* Build with `--dart-define-from-file=.env` (see §4).
* `INTERNET` permission is in the main manifest (release builds include it).
* Sign the release with your keystore (`android/key.properties`) and add that
  keystore's SHA-1 to Firebase (§3c) — otherwise Google sign-in works in debug
  but fails in release.
* Test the *release APK* on a real phone before uploading:
  `flutter build apk --release --dart-define-from-file=.env` then install it.
* Supabase free projects **pause after 7 days of no activity**; open the
  dashboard and click *Restore* if that happens (Pro plan avoids this).

## 9. Known gaps you should decide on before a public launch

* **Phone OTP is switched off** (`AppConstants.phoneOtpEnabled = false`): the
  fake demo code `123456` no longer ships. The number is just saved on the
  profile as *unverified*; sign-in security comes from Google/Apple. To verify
  numbers for real, connect an SMS service (Supabase Phone Auth + Twilio /
  MessageBird / Vonage, or Firebase Phone Auth — SMS costs money), then set the
  flag to `true`.
* **“Verified” badge and Rovlo+ subscription are set by the app itself**
  (demo flows). A user could flip them with a modified app. Before charging
  real money, do payments with Google Play Billing / Razorpay / Stripe and set
  `subscription_tier` / `is_verified` from a server (Edge Function / webhook).
  The checkout screen must not collect real card numbers itself.
* The map exposes *approximate* locations (rounded to ~100 m). A person stays on
  the map at their **last live location** (shown as “Live location · 3 hours
  ago”) until they open the app again and it refreshes; only **Ghost Mode**
  removes them. Mention this in your privacy policy. Location shared inside a
  chat is exact, end-to-end encrypted and sent only when the user confirms.
* `AppConstants.termsUrl` / `privacyUrl` point at `https://rovlo.app/...`; Google
  Play requires a working privacy-policy page — host it before publishing.

// Sahafi Colony Portal — Supabase connection config.
//
// 1. Create a free project at https://supabase.com
// 2. Open the SQL editor and run schema.sql (in this repo) once, against that project.
// 3. In Project Settings -> API, copy the "Project URL" and the "anon public" key
//    (never the service_role key) into the two fields below.
// 4. Copy this file to config.js (same folder) and fill it in — config.js is the file
//    index.html actually loads, and it's the one file this app needs to go live.
//
// The anon key is meant to be public — it's the same key Supabase's own client-side
// docs tell you to ship in a browser bundle. Row Level Security in schema.sql is what
// actually controls what that key can do (nothing, directly — every access goes
// through the functions the schema defines, each of which checks a session token or
// admin status before touching data).
window.PORTAL_CONFIG = {
  SUPABASE_URL: "https://YOUR-PROJECT-REF.supabase.co",
  SUPABASE_ANON_KEY: "YOUR-ANON-PUBLIC-KEY",
};

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!url || !key) {
  console.error("Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");
  process.exit(1);
}

const response = await fetch(`${url}/rest/v1/exam_papers?select=paper_id&limit=1`, {
  headers: { apikey: key, Authorization: `Bearer ${key}` },
});

const body = await response.text();
console.log(`Supabase HTTP ${response.status}`);
console.log(body || "(empty response)");

if (!response.ok) process.exit(1);

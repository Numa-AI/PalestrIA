// Edge Function: image-proxy
// Proxy per immagini esercizi (apilyfta.com) — aggiunge CORS headers
// per permettere al client di convertire le immagini in base64 per il PDF.

const ALLOWED_ORIGIN = "https://apilyfta.com/static/";

Deno.serve(async (req) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Max-Age": "86400",
      },
    });
  }

  const url = new URL(req.url).searchParams.get("url");
  if (!url || !url.startsWith(ALLOWED_ORIGIN)) {
    return new Response("URL non consentito", { status: 400 });
  }

  try {
    const resp = await fetch(url);
    if (!resp.ok) {
      return new Response("Immagine non trovata", { status: resp.status });
    }

    return new Response(resp.body, {
      headers: {
        "Content-Type": resp.headers.get("Content-Type") || "image/png",
        "Access-Control-Allow-Origin": "*",
        "Cache-Control": "public, max-age=604800",
      },
    });
  } catch (e) {
    return new Response("Errore proxy: " + e.message, { status: 500 });
  }
});

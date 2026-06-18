// Edge Function: image-proxy
// Proxy per immagini esercizi (apilyfta.com) — aggiunge CORS headers
// per permettere al client di convertire le immagini in base64 per il PDF.

// Host consentito (match ESATTO sull'hostname, non startsWith: evita bypass tipo
// "apilyfta.com.evil.com") + path richiesto sotto /static/.
const ALLOWED_HOST = "apilyfta.com";
const ALLOWED_PATH_PREFIX = "/static/";

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
  if (!url) {
    return new Response("URL non consentito", { status: 400 });
  }

  // Valida hostname ESATTO + schema https + path sotto /static/ (anti-SSRF).
  let target: URL;
  try {
    target = new URL(url);
  } catch {
    return new Response("URL non valido", { status: 400 });
  }
  if (
    target.protocol !== "https:" ||
    target.hostname !== ALLOWED_HOST ||
    !target.pathname.startsWith(ALLOWED_PATH_PREFIX)
  ) {
    return new Response("URL non consentito", { status: 400 });
  }

  try {
    // redirect:'manual' → non seguiamo redirect upstream (anti-relay/SSRF).
    const resp = await fetch(target.toString(), { redirect: "manual" });
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
    return new Response("Errore proxy: " + (e instanceof Error ? e.message : String(e)), { status: 500 });
  }
});

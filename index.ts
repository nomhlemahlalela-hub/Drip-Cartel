// =====================================================================
//  payment-webhook — turns a gateway callback into a paid order
//
//  Deploy:  supabase functions deploy payment-webhook --no-verify-jwt
//  Secrets: supabase secrets set OZOW_PRIVATE_KEY=... PAYFAST_PASSPHRASE=... YOCO_WEBHOOK_SECRET=...
//
//  Point each gateway's "notify URL" at:
//    https://<project>.supabase.co/functions/v1/payment-webhook?gw=ozow
//    ...?gw=payfast     ...?gw=yoco
//
//  Nothing here trusts the browser: the order is only marked paid when the
//  signature checks out AND the amount matches what the database says is owed.
// =====================================================================

/// <reference path="./index.d.ts" />

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,      // service role: bypasses RLS, never ships to the browser
  { auth: { persistSession: false } },
);

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha512 = async (s: string) => hex(await crypto.subtle.digest("SHA-512", enc.encode(s)));
const md5 = async (s: string) => {
  // PayFast still signs with MD5; Deno has no built-in MD5, so use the std module
  const { crypto: stdCrypto } = await import("https://deno.land/std@0.224.0/crypto/mod.ts");
  return hex(await stdCrypto.subtle.digest("MD5", enc.encode(s)));
};

// ---------- Ozow: SHA512 of the concatenated fields + private key ----------
async function checkOzow(p: Record<string, string>) {
  const key = Deno.env.get("OZOW_PRIVATE_KEY") ?? "";
  const raw = [p.SiteCode, p.TransactionId, p.TransactionReference, p.Amount, p.Status,
    p.Optional1, p.Optional2, p.Optional3, p.Optional4, p.Optional5,
    p.CurrencyCode, p.IsTest, p.StatusMessage].join("") + key;
  const ok = (await sha512(raw.toLowerCase())) === (p.Hash ?? "").toLowerCase();
  return {
    ok: ok && p.Status === "Complete",
    order_no: p.TransactionReference,
    amount: Math.round(parseFloat(p.Amount ?? "0") * 100),
    ref: p.TransactionId,
  };
}

// ---------- PayFast: MD5 of the posted fields in order + passphrase ----------
async function checkPayFast(p: Record<string, string>, body: string) {
  const pass = Deno.env.get("PAYFAST_PASSPHRASE") ?? "";
  const pairs = body.split("&").filter((kv) => !kv.startsWith("signature="));
  const raw = pairs.join("&") + (pass ? `&passphrase=${encodeURIComponent(pass).replace(/%20/g, "+")}` : "");
  const ok = (await md5(raw)) === p.signature;
  return {
    ok: ok && p.payment_status === "COMPLETE",
    order_no: p.m_payment_id,
    amount: Math.round(parseFloat(p.amount_gross ?? "0") * 100),
    ref: p.pf_payment_id,
  };
}

// ---------- Yoco: HMAC-SHA256 over id.timestamp.body ----------
async function checkYoco(req: Request, body: string) {
  const secret = (Deno.env.get("YOCO_WEBHOOK_SECRET") ?? "").replace(/^whsec_/, "");
  const id = req.headers.get("webhook-id") ?? "";
  const ts = req.headers.get("webhook-timestamp") ?? "";
  const sig = (req.headers.get("webhook-signature") ?? "").split(" ").pop()?.split(",").pop() ?? "";
  const key = await crypto.subtle.importKey("raw", Uint8Array.from(atob(secret), (c) => c.charCodeAt(0)),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${id}.${ts}.${body}`));
  const expect = btoa(String.fromCharCode(...new Uint8Array(mac)));
  const e = JSON.parse(body);
  return {
    ok: expect === sig && e.type === "payment.succeeded",
    order_no: e.payload?.metadata?.order_no,
    amount: e.payload?.amount,
    ref: e.payload?.id,
  };
}

Deno.serve(async (req) => {
  const gw = new URL(req.url).searchParams.get("gw") ?? "ozow";
  const body = await req.text();
  const form = Object.fromEntries(new URLSearchParams(body));

  let res;
  try {
    if (gw === "ozow") res = await checkOzow(form as Record<string, string>);
    else if (gw === "payfast") res = await checkPayFast(form as Record<string, string>, body);
    else if (gw === "yoco") res = await checkYoco(req, body);
    else return new Response("unknown gateway", { status: 400 });
  } catch (e) {
    console.error(gw, e);
    return new Response("bad payload", { status: 400 });
  }

  if (!res.ok || !res.order_no) {
    console.warn("rejected callback", gw, res);
    return new Response("ignored", { status: 200 });   // always 200, or gateways keep retrying
  }

  const { data: order } = await db.from("orders")
    .select("id, order_no, total_cents, status").eq("order_no", res.order_no.toUpperCase()).single();

  if (!order) return new Response("unknown order", { status: 200 });
  if (order.status !== "awaiting_payment" && order.status !== "payment_review") return new Response("already handled");

  // the amount must match what the database says is owed
  if (Math.abs((res.amount ?? 0) - order.total_cents) > 100) {
    await db.from("order_events").insert({
      order_id: order.id, status: order.status,
      note: `Gateway paid ${res.amount} but the order is ${order.total_cents}. Check manually.`,
    });
    return new Response("amount mismatch");
  }

  await db.from("orders").update({
    status: "paid", paid: true, paid_at: new Date().toISOString(),
    gateway: gw, gateway_ref: res.ref, updated_at: new Date().toISOString(),
  }).eq("id", order.id);

  await db.from("order_events").insert({
    order_id: order.id, status: "paid", note: `Payment confirmed by ${gw} (${res.ref})`,
  });

  return new Response("ok");
});
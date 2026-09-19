# Drip Cartel — backend

Supabase (Postgres + Auth + Storage + Edge Functions). Nothing here needs a server you maintain.

```
backend/
  supabase/
    schema.sql                        tables, security rules, order logic
    seed.sql                          your nine products and their stock
    functions/notify/index.ts         order emails + WhatsApp messages
    functions/payment-webhook/index.ts  Ozow / PayFast / Yoco callbacks
  web/
    dc-api.js                         the shop talks to the backend through this
    admin.html                        your control room
```

## 1. Create the project

1. supabase.com → **New project**. Pick the region closest to you (Frankfurt is the usual pick for South Africa) and save the database password somewhere safe.
2. **SQL Editor → New query** → paste all of `schema.sql` → Run.
3. New query → paste `seed.sql` → Run.
4. **Project Settings → API**: copy the **Project URL** and the **anon public** key.

Paste those two values into the top of `web/dc-api.js` *and* the top of `web/admin.html`.

The anon key belongs in the browser — that is what it is for. The **service role** key never leaves the Edge Functions.

## 2. Make yourself an admin

Sign up on the shop like a normal customer, then run:

```sql
update public.profiles set is_admin = true where email = 'you@dripcartel.co.za';
```

Open `admin.html` and sign in with that account.

## 3. Email and WhatsApp updates

```bash
npm i -g supabase
supabase login
supabase link --project-ref YOUR-PROJECT-REF

supabase secrets set RESEND_API_KEY=re_xxx MAIL_FROM="Drip Cartel <orders@dripcartel.co.za>" \
  WA_TOKEN=xxx WA_PHONE_ID=xxx HOOK_SECRET=$(openssl rand -hex 16) SITE_URL=https://dripcartel.co.za

supabase functions deploy notify --no-verify-jwt
```

- **Email** — resend.com, free for 3 000 a month. Verify your domain so mail doesn't land in spam.
- **WhatsApp** — Meta WhatsApp Cloud API. It works as written, but Meta only lets you send free-form text within 24 hours of the customer messaging you. For updates outside that window you need an approved message template; swap the `type: "text"` body in `notify/index.ts` for a template payload once yours is approved. If that is more admin than you want right now, leave `WA_TOKEN` unset and email alone will run.

Then in the Dashboard: **Database → Webhooks → Create**
- Table `orders`, events **Insert** and **Update**
- Type: Supabase Edge Function → `notify`
- HTTP header `x-hook-secret` = the `HOOK_SECRET` you generated

Every status change now messages the customer automatically. Nothing to remember.

## 4. Payments

**Today (manual).** EFT, voucher and pay-on-collection all work with no gateway. The order sits on `awaiting_payment`, the customer taps "I have paid" or uploads proof, it moves to `payment_review`, and you confirm it in the control room. Your banking details live in the `settings` table and are editable from the Settings tab.

**When you're ready for a gateway.**

```bash
supabase secrets set OZOW_PRIVATE_KEY=xxx PAYFAST_PASSPHRASE=xxx YOCO_WEBHOOK_SECRET=whsec_xxx
supabase functions deploy payment-webhook --no-verify-jwt
```

Give each gateway this notify URL:

```
https://YOUR-PROJECT.supabase.co/functions/v1/payment-webhook?gw=ozow
                                                             ?gw=payfast
                                                             ?gw=yoco
```

The function verifies the signature, checks the amount against what the database says is owed, and only then marks the order paid. A redirect back to your site never marks anything paid — that is how stores get robbed.

For **Ozow** specifically, build the payment form in a small edge function rather than the browser: the request hash needs your private key. PayFast is safe to post from the browser and `dc-api.js` has that ready in `gatewayRedirect()`.

## 5. Point the shop at the backend

In `drip-cartel.html`, add before your existing script:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="dc-api.js"></script>
```

Then replace the localStorage pieces:

| Currently in the site | Replace with |
|---|---|
| `PRODUCTS` constant | `const PRODUCTS = await DC.products()` on load |
| `signupForm` submit | `DC.signUp({...})` |
| `loginForm` submit | `DC.signIn(email, password)` |
| `signOut()` | `DC.signOut()` |
| `placeOrder()` | `DC.placeOrder({ cart, delivery, payment, contact, promo_code })` |
| profile `Save changes` | `DC.updateProfile({...})` |
| `findOrder()` / tracker | `DC.trackOrder(orderNo, phoneLast4)` |
| "I have paid" button | `DC.claimPayment(orderNo)` or `DC.uploadProof(orderId, file)` |
| `contactForm` submit | `DC.sendMessage({ name, email, body })` |
| the "Demo: move to the next stage" link | delete it — the control room does this now |

Two changes worth making while you're in there:

- The cart can stay in `localStorage`. It is a convenience, not a record.
- Prices, stock and the discount are all recalculated in the database when an order is placed. If someone edits the price in their browser, the order still comes through at your price.

## How an order moves

```
awaiting_payment → payment_review → paid → packed → shipped → delivered
                                                     ("ready for collection" for pickups)
```

- **awaiting_payment** — set automatically, except instant EFT which lands on `paid`.
- **payment_review** — the customer said they paid or uploaded proof.
- **paid** onwards — you, in the control room, or the gateway webhook.
- **cancelled** — puts every item back into stock.

Each move writes a row to `order_events`, which is what the customer sees on the tracking page, and fires the notification.

## What stops people doing things they shouldn't

Row level security is on for every table. Customers read only their own orders. The catalogue is readable by anyone but writable only by admins. The contact form is write-only for the public — only admins read messages. Proof-of-payment files go into a private bucket; the customer can upload into their own folder and nobody but they and you can open them.

Orders cannot be inserted directly at all. They go through `create_order()`, which reads prices and stock from the database itself.

## Before you go live

- Auth → set the Site URL and redirect URLs to your real domain.
- Auth → turn on email confirmation if you want verified addresses.
- Swap the placeholder FNB details in Settings for your real account.
- Set stock to what you actually have. XXL ships as 0 across the board.
- Take a backup: Database → Backups (daily on the paid tier).

/* =====================================================================
   DRIP CARTEL — browser API layer
   Drop this in before your site script:

     <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
     <script src="dc-api.js"></script>

   Then use window.DC.  Everything returns a promise and throws a plain
   Error with a message you can hand straight to toast().

   The anon key below is safe in the browser — row level security in the
   database is what protects the data. Never put the service role key here.
   ===================================================================== */
window.DC = (() => {
  const cfg = window.DRIP_CARTEL_SUPABASE || { url: 'https://YOUR-PROJECT.supabase.co', anonKey: 'YOUR-ANON-KEY' };
  const SUPABASE_URL = cfg.url;
  const SUPABASE_ANON_KEY = cfg.anonKey;

  const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const fail = (e, fallback) => { throw new Error((e && e.message) || fallback); };
  const rands = c => 'R' + Math.round((c || 0) / 100).toLocaleString('en-ZA');

  /* ---------------- auth + profile ---------------- */
  async function signUp({ email, password, full_name, username, phone, city, size, address }) {
    const { data, error } = await sb.auth.signUp({
      email: email.trim().toLowerCase(), password,
      options: { data: { full_name, username, phone, city, size, address } }
    });
    if (error) fail(error, 'Could not create your account.');
    return data.user;
  }
  async function signIn(email, password) {
    const { data, error } = await sb.auth.signInWithPassword({ email: email.trim().toLowerCase(), password });
    if (error) throw new Error('Email or password is incorrect.');
    return data.user;
  }
  const signOut = () => sb.auth.signOut();
  const onAuth = cb => sb.auth.onAuthStateChange((_e, session) => cb(session ? session.user : null));

  async function me() {
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return null;
    const { data } = await sb.from('profiles').select('*').eq('id', user.id).single();
    return data;
  }
  async function updateProfile(patch) {
    const { data: { user } } = await sb.auth.getUser();
    if (!user) fail(null, 'Sign in first.');
    const { error } = await sb.from('profiles').update(patch).eq('id', user.id);
    if (error) fail(error, 'Could not save your profile.');
  }
  async function resetPassword(email) {
    const { error } = await sb.auth.resetPasswordForEmail(email.trim().toLowerCase(),
      { redirectTo: location.origin + '/reset.html' });
    if (error) fail(error, 'Could not send the reset email.');
  }

  /* ---------------- catalogue ---------------- */
  // returns products shaped exactly like the PRODUCTS array the site already uses
  async function products() {
    const { data, error } = await sb.from('products')
      .select('*, product_variants(size, stock)')
      .eq('is_active', true).order('sort_order');
    if (error) fail(error, 'Could not load the shop.');
    return data.map(p => {
      const v = (p.product_variants || []).sort((a, b) => sizeRank(a.size) - sizeRank(b.size));
      return {
        id: p.id, name: p.name, cat: p.category, desc: p.description,
        price: p.price_cents / 100, tag: p.tag || '', limited: p.is_limited,
        sizes: v.map(x => x.size),
        out: v.filter(x => x.stock <= 0).map(x => x.size),
        stock: Object.fromEntries(v.map(x => [x.size, x.stock])),
        img: p.image_path ? imageUrl(p.image_path) : 'images/' + p.id + '.jpg'
      };
    });
  }
  const SIZE_ORDER = ['One size', 'S', 'M', 'L', 'XL', 'XXL'];
  const sizeRank = s => { const i = SIZE_ORDER.indexOf(s); return i < 0 ? 99 : i; };
  const imageUrl = path => sb.storage.from('products').getPublicUrl(path).data.publicUrl;

  async function settings() {
    const { data } = await sb.from('settings').select('*');
    return Object.fromEntries((data || []).map(r => [r.key, r.value]));
  }

  /* ---------------- checkout ---------------- */
  // cart: [{ id, size, qty }] — prices and stock are recalculated server-side
  async function placeOrder({ cart, delivery, payment, contact, promo_code }) {
    const { data, error } = await sb.rpc('create_order', {
      p: {
        items: cart.map(l => ({ product_id: l.id, size: l.size, qty: l.qty })),
        delivery_method: delivery.method,
        payment_method: payment.method,
        voucher_last4: payment.voucher_last4 || '',
        recipient_name: contact.name, phone: contact.phone,
        address: contact.address, city: contact.city,
        province: contact.province, postal_code: contact.postal,
        notes: contact.notes || '', email: contact.email,
        promo_code: promo_code || ''
      }
    });
    if (error) fail(error, 'We could not place that order.');
    return data;   // { order_no, order_id, total_cents, status }
  }

  /* ---------------- orders + tracking ---------------- */
  async function myOrders() {
    const { data, error } = await sb.from('orders')
      .select('*, order_items(*), order_events(*)')
      .order('created_at', { ascending: false });
    if (error) fail(error, 'Could not load your orders.');
    return data;
  }
  // works signed out too: order number + the last 4 digits of the phone on the order
  async function trackOrder(order_no, phone4) {
    const { data, error } = await sb.rpc('track_order', { p_order_no: order_no, p_phone4: phone4 || '' });
    if (error) fail(error, 'Could not look that order up.');
    return data;   // null when the number or phone does not match
  }
  async function claimPayment(order_no) {
    const { error } = await sb.rpc('claim_payment', { p_order_no: order_no });
    if (error) fail(error, 'Could not record that.');
  }
  async function uploadProof(order_id, file, note) {
    const { data: { user } } = await sb.auth.getUser();
    if (!user) fail(null, 'Sign in to upload proof of payment.');
    if (file.size > 5 * 1024 * 1024) fail(null, 'Keep the file under 5 MB.');
    const path = `${user.id}/${order_id}-${Date.now()}-${file.name.replace(/[^\w.\-]/g, '_')}`;
    const { error } = await sb.storage.from('proofs').upload(path, file);
    if (error) fail(error, 'Upload failed. Try again.');
    const { error: e2 } = await sb.from('payment_proofs').insert({ order_id, storage_path: path, note: note || '' });
    if (e2) fail(e2, 'Upload saved but not linked. Contact us.');
    await claimPayment_safe(order_id);
    return path;
  }
  async function claimPayment_safe(order_id) {
    const { data } = await sb.from('orders').select('order_no').eq('id', order_id).single();
    if (data) { try { await claimPayment(data.order_no); } catch (e) {} }
  }

  /* ---------------- contact form ---------------- */
  async function sendMessage({ name, email, body }) {
    const { error } = await sb.from('messages').insert({ name, email, body });
    if (error) fail(error, 'Message not sent. Try again.');
  }

  /* ---------------- gateway handoff (when you switch payments on) ----------------
     Keep the order in 'awaiting_payment' and send the customer to the gateway
     with the order number as the reference. The payment-webhook function is what
     actually marks it paid — never the redirect back to your site.              */
  function gatewayRedirect(gateway, order) {
    const amount = (order.total_cents / 100).toFixed(2);
    if (gateway === 'ozow') {
      // build this server-side in production: the hash needs your private key
      console.warn('Build the Ozow post from an edge function, not the browser.');
    }
    if (gateway === 'payfast') {
      const f = document.createElement('form');
      f.method = 'POST';
      f.action = 'https://www.payfast.co.za/eng/process';
      const fields = {
        merchant_id: 'YOUR_MERCHANT_ID', merchant_key: 'YOUR_MERCHANT_KEY',
        return_url: location.origin + '/#track', cancel_url: location.origin + '/#cart',
        notify_url: SUPABASE_URL + '/functions/v1/payment-webhook?gw=payfast',
        m_payment_id: order.order_no, amount, item_name: 'Drip Cartel ' + order.order_no
      };
      Object.entries(fields).forEach(([k, v]) => {
        const i = document.createElement('input'); i.type = 'hidden'; i.name = k; i.value = v; f.appendChild(i);
      });
      document.body.appendChild(f); f.submit();
    }
  }

  return { sb, signUp, signIn, signOut, onAuth, me, updateProfile, resetPassword,
    products, settings, imageUrl, placeOrder, myOrders, trackOrder, claimPayment,
    uploadProof, sendMessage, gatewayRedirect, rands };
})();
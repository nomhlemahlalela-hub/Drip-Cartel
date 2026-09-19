-- =====================================================================
--  DRIP CARTEL — starting catalogue.  Run after schema.sql.
--  Re-running it is safe: it updates instead of duplicating.
-- =====================================================================

insert into public.products (id, name, category, description, price_cents, tag, is_limited, sort_order, image_path) values
 ('beanie',  'DC Beanie',            'headwear',    'Black ribbed knit · embroidered DRIP CARTEL logo · one size fits all', 8000,  '',           false, 10, null),
 ('jacket',  'DC Tracksuit Jacket',  'tops',        'Black quarter-zip · white contrast piping · DRIP CARTEL chest logo',   50000, 'New',        false, 20, null),
 ('pants',   'DC Tracksuit Pants',   'bottoms',     'Wide-leg track pants · white piping detail · DC signature leg logo',   60000, 'New',        false, 30, null),
 ('denimjkt','DC Denim Jacket',      'tops',        'Washed denim jacket · DRIP CARTEL back embroidery',                    55000, '',           false, 40, null),
 ('cargo',   'DC Cargo Pants',       'bottoms',     'Relaxed cargo fit · utility pockets · DC logo tab',                    55000, '',           false, 50, null),
 ('denimset','Denim Set: Jacket + Cargo Pants','sets','His full denim fit · save R100 against buying separately',          100000,'Save R100',   true,  60, null),
 ('tee',     'DC Logo Tee',          'tops',        'Heavyweight cotton tee · DRIP CARTEL chest print',                     25000, '',           false, 70, null),
 ('cap',     'DC Cap',               'headwear',    'Structured six-panel cap · embroidered DC monogram · adjustable strap',12000, '',           false, 80, null),
 ('bag',     'DC Crossbody Bag',     'accessories', 'Black utility crossbody · zip pockets · adjustable strap · DC logo',   18000, '',           false, 90, null)
on conflict (id) do update set
  name = excluded.name, category = excluded.category, description = excluded.description,
  price_cents = excluded.price_cents, tag = excluded.tag, is_limited = excluded.is_limited,
  sort_order = excluded.sort_order;

-- clothing sizes (XXL starts sold out, as on the current site)
insert into public.product_variants (product_id, size, stock)
select p.id, s.size, case when s.size = 'XXL' then 0 else 12 end
from public.products p
cross join (values ('S'),('M'),('L'),('XL'),('XXL')) as s(size)
where p.category in ('tops','bottoms','sets')
on conflict (product_id, size) do nothing;

-- one-size items
insert into public.product_variants (product_id, size, stock)
select p.id, 'One size', 25
from public.products p
where p.category in ('headwear','accessories')
on conflict (product_id, size) do nothing;

-- =====================================================================
--  MAKE YOURSELF AN ADMIN
--  Sign up on the site first, then run this with your email:
--
--    update public.profiles set is_admin = true where email = 'you@dripcartel.co.za';
-- =====================================================================

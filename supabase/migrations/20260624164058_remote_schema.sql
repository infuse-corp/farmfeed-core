

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "Test ";


ALTER SCHEMA "Test " OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE SCHEMA IF NOT EXISTS "develop";


ALTER SCHEMA "develop" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";








ALTER SCHEMA "public" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "hypopg" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "index_advisor" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "postgis" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."mp_attachment_type" AS ENUM (
    'image',
    'order_ref',
    'product_ref'
);


ALTER TYPE "public"."mp_attachment_type" OWNER TO "postgres";


CREATE TYPE "public"."mp_message_type" AS ENUM (
    'text',
    'attachments'
);


ALTER TYPE "public"."mp_message_type" OWNER TO "postgres";


CREATE TYPE "public"."profile_farm_type_category" AS ENUM (
    'พืช',
    'สัตว์'
);


ALTER TYPE "public"."profile_farm_type_category" OWNER TO "postgres";


CREATE TYPE "public"."profile_name_prefix" AS ENUM (
    'นาย',
    'นาง',
    'นางสาว'
);


ALTER TYPE "public"."profile_name_prefix" OWNER TO "postgres";


CREATE TYPE "public"."review_media_type" AS ENUM (
    'image',
    'video'
);


ALTER TYPE "public"."review_media_type" OWNER TO "postgres";


CREATE TYPE "public"."review_subject" AS ENUM (
    'product',
    'shop'
);


ALTER TYPE "public"."review_subject" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."aggregate_daily_usage"("target_date" "date" DEFAULT (CURRENT_DATE - 1)) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Step 1: Insert sessions for users who DID log in
  INSERT INTO mp_user_daily_summary (
    user_id, marketplace_depa_register_id, summary_date, login_count, total_minutes
  )
  SELECT
    p.id,
    p.marketplace_depa_register_id,
    target_date,
    COUNT(s.id),
    ROUND(
      COALESCE(SUM(EXTRACT(EPOCH FROM (s.logout_at - s.login_at)) / 60), 0)::NUMERIC, 2
    )
  FROM public.profile p
  LEFT JOIN mp_tb_user_sessions s
    ON s.user_id = p.id AND DATE(s.login_at) = target_date
  WHERE p.marketplace_depa_register_id IS NOT NULL  -- DEPA users only
  GROUP BY p.id, p.marketplace_depa_register_id
  ON CONFLICT (user_id, summary_date)
  DO UPDATE SET
    login_count = EXCLUDED.login_count,
    total_minutes = EXCLUDED.total_minutes,
    sent_to_external = FALSE;

  -- Step 2: Zero-fill users who didn't log in at all (no session rows)
  INSERT INTO mp_user_daily_summary (
    user_id, marketplace_depa_register_id, summary_date, login_count, total_minutes
  )
  SELECT
    p.id,
    p.marketplace_depa_register_id,
    target_date,
    0,
    0
  FROM public.profile p
  WHERE p.marketplace_depa_register_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM mp_user_daily_summary
      WHERE user_id = p.id AND summary_date = target_date
    )
  ON CONFLICT DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."aggregate_daily_usage"("target_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_cancel_order"("p_dispute_id" "uuid", "p_admin_id" "uuid", "p_internal_notes" "text", "p_public_resolution" "text", OUT "r_order_id" "uuid", OUT "r_shop_line_id" "text", OUT "r_customer_line_id" "text", OUT "r_order_code" "text", OUT "r_strike_points" integer, OUT "r_total_strike_points" integer) RETURNS "record"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_shop_id UUID;
    v_reason_type TEXT;
BEGIN
    -- 1. ดึงข้อมูลที่จำเป็น และ JOIN profile สองรอบ
    -- เราเลือก d.order_id เข้าสู่ r_order_id โดยตรงเลย
    SELECT 
        d.order_id, 
        d.shop_id, 
        d.reason_type, 
        p_shop.line_user_id, 
        p_cust.line_user_id,
        o.order_code
    INTO 
        r_order_id, 
        v_shop_id, 
        v_reason_type, 
        r_shop_line_id, 
        r_customer_line_id, 
        r_order_code
    FROM mp_order_disputes d
    JOIN shop s ON s.id = d.shop_id
    JOIN profile p_shop ON p_shop.id = s.user_id 
    JOIN profile p_cust ON p_cust.id = d.customer_id 
    JOIN mp_order_sales o ON o.order_id = d.order_id
    WHERE d.id = p_dispute_id;

    IF r_order_id IS NULL THEN
        RAISE EXCEPTION 'Dispute not found';
    END IF;

    -- 2. คำนวณโทษ (Strike Points)
    r_strike_points := CASE v_reason_type
        WHEN 'NOT_RECEIVED' THEN 2
        WHEN 'WRONG_ITEM' THEN 2
        WHEN 'DAMAGED' THEN 1
        ELSE 1
    END;

    -- 3. อัปเดตสถานะ Dispute
    UPDATE mp_order_disputes
    SET status = 'RESOLVED_CANCELLED',
        final_decision_by = p_admin_id,
        internal_notes = p_internal_notes,
        public_resolution = p_public_resolution,
        resolved_at = NOW()
    WHERE id = p_dispute_id;

    -- 4. อัปเดตสถานะ Order เป็น CANCELLED
    UPDATE mp_order_sales
    SET payment_status = 'CANCELLED',
        cancelled_at = NOW()
    WHERE order_id = r_order_id;

    -- 5. คืนสต็อกสินค้า
    WITH items_to_restock AS (
        SELECT product_variant_id, SUM(quantity) as total_qty
        FROM mp_order_items
        WHERE order_id = r_order_id
        GROUP BY product_variant_id
    )
    UPDATE mp_product_variant pv
    SET stock_quantity = pv.stock_quantity + itr.total_qty,
        is_active = TRUE
    FROM items_to_restock itr
    WHERE pv.id = itr.product_variant_id;

    -- 6. บันทึกประวัติการทำผิด
    INSERT INTO mp_seller_violations (shop_id, order_id, violation_type, strike_points, details)
    VALUES (v_shop_id, r_order_id, 'BUYER_DISPUTE_LOST', r_strike_points, p_public_resolution);

    -- 7. อัปเดตคะแนนรวม และ Blacklist
    WITH strike_totals AS (
        SELECT shop_id, SUM(strike_points) as total
        FROM mp_seller_violations
        WHERE shop_id = v_shop_id
        GROUP BY shop_id
    )
    UPDATE shop s
    SET total_strike_points = st.total,
        is_blacklisted = CASE WHEN st.total >= 5 THEN TRUE ELSE s.is_blacklisted END,
        blacklisted_at = CASE 
            WHEN st.total >= 5 AND s.is_blacklisted = FALSE THEN NOW() 
            ELSE s.blacklisted_at 
        END,
        blacklist_reason = CASE 
            WHEN st.total >= 5 AND s.is_blacklisted = FALSE THEN 'ถูกแบนอัตโนมัติ 7 วันเนื่องจากคะแนนความประพฤติครบ 5 คะแนน'
            ELSE s.blacklist_reason 
        END
    FROM strike_totals st
    WHERE s.id = v_shop_id
    RETURNING s.total_strike_points INTO r_total_strike_points;

END;
$$;


ALTER FUNCTION "public"."approve_cancel_order"("p_dispute_id" "uuid", "p_admin_id" "uuid", "p_internal_notes" "text", "p_public_resolution" "text", OUT "r_order_id" "uuid", OUT "r_shop_line_id" "text", OUT "r_customer_line_id" "text", OUT "r_order_code" "text", OUT "r_strike_points" integer, OUT "r_total_strike_points" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cc_delete_claim"("uid" "uuid", "claim" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    BEGIN
      IF NOT cc_is_claims_admin() THEN
          RETURN 'error: access denied';
      ELSE
        update auth.users set raw_app_meta_data =
          raw_app_meta_data - claim where id = uid;
        return 'OK';
      END IF;
    END;
$$;


ALTER FUNCTION "public"."cc_delete_claim"("uid" "uuid", "claim" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cc_get_claim"("uid" "uuid", "claim" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    DECLARE retval jsonb;
    BEGIN
      IF NOT cc_is_claims_admin() THEN
          RETURN '{"error":"access denied"}'::jsonb;
      ELSE
        select coalesce(raw_app_meta_data->claim, null) from auth.users into retval where id = uid::uuid;
        return retval;
      END IF;
    END;
$$;


ALTER FUNCTION "public"."cc_get_claim"("uid" "uuid", "claim" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cc_get_claims"("uid" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    DECLARE retval jsonb;
    BEGIN
      IF NOT cc_is_claims_admin() THEN
          RETURN '{"error":"access denied"}'::jsonb;
      ELSE
        select raw_app_meta_data from auth.users into retval where id = uid::uuid;
        return retval;
      END IF;
    END;
$$;


ALTER FUNCTION "public"."cc_get_claims"("uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cc_get_my_claim"("claim" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  select
  	coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb -> 'app_metadata' -> claim, null)
$$;


ALTER FUNCTION "public"."cc_get_my_claim"("claim" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cc_get_my_claims"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  select
  	coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb -> 'app_metadata', '{}'::jsonb)::jsonb
$$;


ALTER FUNCTION "public"."cc_get_my_claims"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cc_is_claims_admin"() RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
  BEGIN

    IF session_user = 'authenticator' THEN
      --------------------------------------------
      -- To disallow any authenticated app users
      -- from editing claims, delete the following
      -- block of code and replace it with:
      -- RETURN FALSE;
      --------------------------------------------

      IF extract(epoch from now()) > coalesce((current_setting('request.jwt.claims', true)::jsonb)->>'exp', '0')::numeric THEN
        return false; -- jwt expired
      END IF;
      IF coalesce((current_setting('request.jwt.claims', true)::jsonb)->'app_metadata'->'claims_admin', 'false')::bool THEN
        return true; -- user has claims_admin set to true
      ELSE
        return false; -- user does NOT have claims_admin set to true
      END IF;

      --------------------------------------------
      -- End of block
      --------------------------------------------
    ELSE -- not a user session, probably being called from a trigger ('supabase_auth_admin') or something
      return true;
    END IF;
  END;
$$;


ALTER FUNCTION "public"."cc_is_claims_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cc_set_claim"("uid" "uuid", "claim" "text", "value" "jsonb") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    BEGIN
      IF NOT cc_is_claims_admin() THEN
          RETURN 'error: access denied';
      ELSE
        update auth.users set raw_app_meta_data =
          raw_app_meta_data ||
            json_build_object(claim, value)::jsonb where id = uid;
        return 'OK';
      END IF;
    END;
$$;


ALTER FUNCTION "public"."cc_set_claim"("uid" "uuid", "claim" "text", "value" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_relay_boolean"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  news_detail jsonb := new.relay_detail;
  relay_check boolean;
begin
  relay_check := not exists (
    select 1 from jsonb_each(news_detail)
    where value <> 'true'::jsonb
  );

  update dn_iot_supply_list
  set relay = coalesce(relay_check, relay)
  where device_id = new.device_id;

  return new;
end;
$$;


ALTER FUNCTION "public"."check_relay_boolean"() OWNER TO "postgres";


CREATE PROCEDURE "public"."cleanup_unpaid_orders_24h"()
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  WITH to_cancel AS (
    SELECT os.order_id
    FROM public.mp_order_sales os
    WHERE os.paid_at IS NULL
      AND os.created_at < now() - interval '24 hours'
      AND COALESCE(os.payment_status, '') <> 'EXPIRED'
    FOR UPDATE SKIP LOCKED
  ),
  expired AS (
    UPDATE public.mp_order_sales os
    SET payment_status = 'EXPIRED'
    FROM to_cancel c
    WHERE os.order_id = c.order_id
      AND os.paid_at IS NULL
      AND COALESCE(os.payment_status, '') <> 'EXPIRED'
    RETURNING os.order_id
  ),
  qty_per_variant AS (
    SELECT oi.product_variant_id,
           SUM(COALESCE(oi.quantity, 0)) AS qty
    FROM public.mp_order_items oi
    JOIN expired e ON e.order_id = oi.order_id
    GROUP BY oi.product_variant_id
  )
  UPDATE public.mp_product_variant v
  SET stock_quantity = COALESCE(v.stock_quantity, 0) + q.qty,
      is_active = true
  FROM qty_per_variant q
  WHERE v.id = q.product_variant_id;

END;
$$;


ALTER PROCEDURE "public"."cleanup_unpaid_orders_24h"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."count_delivery_pending_active"("p_shop_id" "uuid") RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT COUNT(*)
  FROM mp_order_sales
  WHERE payment_status = 'DELIVERY_PENDING'
    AND shop_id = p_shop_id
    AND confirmed_at >= NOW() - transit_days * interval '1 day';
$$;


ALTER FUNCTION "public"."count_delivery_pending_active"("p_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_product_boost"("p_product_id" "uuid", "p_shop_id" "uuid", "p_wallet_id" bigint, "p_boost_plan_id" bigint, "p_points_cost" bigint, "p_duration_hours" integer) RETURNS "json"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_current_balance bigint;
  v_boost           tb_m_product_boost%ROWTYPE;
  v_expires_at      timestamptz;
BEGIN
  -- 1. Caller must own the wallet
  IF NOT EXISTS (
    SELECT 1 FROM tb_m_wallet
    WHERE id = p_wallet_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized' USING HINT = 'wallet_not_owned';
  END IF;

  -- 2. Caller must own the shop
  IF NOT EXISTS (
    SELECT 1 FROM shop
    WHERE id = p_shop_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized' USING HINT = 'shop_not_owned';
  END IF;

  -- 3. Product must belong to the shop
  IF NOT EXISTS (
    SELECT 1 FROM mp_product
    WHERE product_id = p_product_id AND shop_id = p_shop_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'invalid_product' USING HINT = 'product_not_in_shop';
  END IF;

  -- 4. Lock wallet row — prevents concurrent deductions on the same wallet
  SELECT balance INTO v_current_balance
  FROM tb_m_wallet
  WHERE id = p_wallet_id
  FOR UPDATE;

  IF v_current_balance IS NULL OR v_current_balance < p_points_cost THEN
    RAISE EXCEPTION 'insufficient_balance' USING HINT = 'balance_too_low';
  END IF;

  -- 5. Guard: no active boost already on this product+slot
  IF EXISTS (
    SELECT 1 FROM tb_m_product_boost
    WHERE product_id = p_product_id
      AND boost_slot = 'homepage'
      AND status = 'active'
      AND expires_at > now()
  ) THEN
    RAISE EXCEPTION 'already_boosted' USING HINT = 'active_boost_exists';
  END IF;

  -- 6. Deduct wallet
  UPDATE tb_m_wallet
  SET balance = balance - p_points_cost
  WHERE id = p_wallet_id;

  -- 7. Insert boost record
  v_expires_at := now() + (p_duration_hours || ' hours')::interval;

  INSERT INTO tb_m_product_boost (
    product_id, shop_id, wallet_id, boost_plan_id,
    points_spent, status, boost_slot, started_at, expires_at
  ) VALUES (
    p_product_id, p_shop_id, p_wallet_id, p_boost_plan_id,
    p_points_cost, 'active', 'homepage', now(), v_expires_at
  )
  RETURNING * INTO v_boost;

  -- 8. Upsert wallet history (table is one-row-per-wallet by design)
  INSERT INTO tb_h_wallet (wallet_id, amount, is_increment, note, paid_at)
  VALUES (p_wallet_id, p_points_cost, false, 'Product Boost: ' || v_boost.id::text, now())
  ON CONFLICT (wallet_id) DO UPDATE
    SET amount       = EXCLUDED.amount,
        is_increment = EXCLUDED.is_increment,
        note         = EXCLUDED.note,
        paid_at      = EXCLUDED.paid_at;

  RETURN json_build_object(
    'success', true,
    'data', json_build_object(
      'id',           v_boost.id,
      'product_id',   v_boost.product_id,
      'shop_id',      v_boost.shop_id,
      'wallet_id',    v_boost.wallet_id,
      'boost_plan_id',v_boost.boost_plan_id,
      'points_spent', v_boost.points_spent,
      'status',       v_boost.status,
      'boost_slot',   v_boost.boost_slot,
      'started_at',   v_boost.started_at,
      'expires_at',   v_boost.expires_at,
      'cancelled_at', v_boost.cancelled_at,
      'created_at',   v_boost.created_at
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    -- Transaction auto-rolls back; return structured error to caller
    RETURN json_build_object(
      'success', false,
      'error',   SQLERRM,
      'hint',    COALESCE(pg_exception_hint(), '')
    );
END;
$$;


ALTER FUNCTION "public"."create_product_boost"("p_product_id" "uuid", "p_shop_id" "uuid", "p_wallet_id" bigint, "p_boost_plan_id" bigint, "p_points_cost" bigint, "p_duration_hours" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cron_nightly_vacuum"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$begin
  if not cc_is_claims_admin() then
    return 'error: access denied';
  else
    delete from ha_states where created_at < now() - interval '3 months';
    delete from ty_sensors where time < now() - interval '6 months';
    delete from ty_commands where time < now() - interval '6 months';
    return 'ok';
  end if;
end;$$;


ALTER FUNCTION "public"."cron_nightly_vacuum"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."debug_auth"() RETURNS "json"
    LANGUAGE "sql" STABLE
    AS $$
  select json_build_object(
    'uid', auth.uid(),
    'role', auth.role()
  );
$$;


ALTER FUNCTION "public"."debug_auth"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decrement_news_comment_count"("news_id" "text") RETURNS "void"
    LANGUAGE "sql"
    AS $_$
UPDATE dn_tb_m_news SET no_of_comment = GREATEST(COALESCE(no_of_comment,1) - 1, 0) WHERE news_id = $1;
$_$;


ALTER FUNCTION "public"."decrement_news_comment_count"("news_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decrement_news_like_count"("news_id" "text") RETURNS "void"
    LANGUAGE "sql"
    AS $_$
UPDATE dn_tb_m_news SET no_of_like = GREATEST(COALESCE(no_of_like,1) - 1, 0) WHERE news_id = $1;
$_$;


ALTER FUNCTION "public"."decrement_news_like_count"("news_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_old_pre_activity"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM pre_activity
    WHERE date < (CURRENT_DATE - INTERVAL '2 months');
END;
$$;


ALTER FUNCTION "public"."delete_old_pre_activity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_device_serial"("length" integer DEFAULT 6) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  chars TEXT := 'abcdefghijklmnopqrstuvwxyz0123456789';
  result TEXT := '';
  i INT;
BEGIN
  FOR i IN 1..length LOOP
    result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
  END LOOP;
  RETURN result;
END;
$$;


ALTER FUNCTION "public"."generate_device_serial"("length" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_amphoes"("p_pro_id" bigint) RETURNS TABLE("amp_id" bigint, "amphoe_th" "text", "amphoe_en" "text")
    LANGUAGE "sql" STABLE
    AS $$
  SELECT DISTINCT amp_id, amphoe_th, amphoe_en
  FROM sub_district
  WHERE pro_id = p_pro_id
  ORDER BY amphoe_th;
$$;


ALTER FUNCTION "public"."get_amphoes"("p_pro_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_by_postcode"("p_postcode" bigint) RETURNS TABLE("pro_id" bigint, "province_th" "text", "province_en" "text", "amp_id" bigint, "amphoe_th" "text", "amphoe_en" "text", "tam_id" bigint, "tambon_th" "text", "tambon_en" "text", "postcode" bigint)
    LANGUAGE "sql" STABLE
    AS $$
  SELECT DISTINCT pro_id, province_th, province_en, amp_id, amphoe_th, amphoe_en, tam_id, tambon_th, tambon_en, postcode
  FROM sub_district
  WHERE postcode = p_postcode
  ORDER BY province_th, amphoe_th, tambon_th;
$$;


ALTER FUNCTION "public"."get_by_postcode"("p_postcode" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_cbf_summary_simple_v1"("p_crop_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    v_yield_kg numeric := 25000;

    v_fertilizer_kgco2e numeric := 0;
    v_chemical_kgco2e numeric := 0;
    v_material_kgco2e numeric := 0;
    v_fuel_kgco2e numeric := 0;
    v_electric_kgco2e numeric := 0;

    v_total_kgco2e numeric := 0;
    v_per_kg_product numeric := 0;

    v_missing_fertilizer_ef integer := 0;
    v_missing_chemical_ef integer := 0;
    v_missing_material_ef integer := 0;
    v_missing_fuel_ef integer := 0;
    v_missing_electric_ef integer := 0;

    v_result jsonb;
begin
    -- 1) fertilizer transport
    select
        coalesce(sum(
            case
                when lower(trim(te.ef_unit)) = 'kgco2e/tkm' then
                    coalesce(f.distance, 0) * (coalesce(f.stock_amount, 0) / 1000.0) * coalesce(te.ef_value, 0)
                when lower(trim(te.ef_unit)) = 'kgco2e/km' then
                    coalesce(f.distance, 0) * coalesce(te.ef_value, 0)
                else 0
            end
        ), 0),
        count(*) filter (where te.id is null)
    into v_fertilizer_kgco2e, v_missing_fertilizer_ef
    from public.dn_tb_r_cbf_fertilizer f
    left join public.dn_tb_m_cbf_transport_ef te
        on lower(trim(te.vehicle_code)) = lower(trim(f.vehicle_code))
       and lower(trim(te.fuel_type)) = lower(trim(f.fuel_type))
       and te.loading_pct = f.loading_pct
       and te.is_active = true
    where f.app_crop_id = p_crop_id
      and coalesce(f.is_deleted, false) = false;

    -- 2) chemical transport
    select
        coalesce(sum(
            case
                when lower(trim(te.ef_unit)) = 'kgco2e/tkm' then
                    coalesce(c.distance, 0) * (coalesce(c.stock_amount, 0) / 1000.0) * coalesce(te.ef_value, 0)
                when lower(trim(te.ef_unit)) = 'kgco2e/km' then
                    coalesce(c.distance, 0) * coalesce(te.ef_value, 0)
                else 0
            end
        ), 0),
        count(*) filter (where te.id is null)
    into v_chemical_kgco2e, v_missing_chemical_ef
    from public.dn_tb_r_cbf_chemical c
    left join public.dn_tb_m_cbf_transport_ef te
        on lower(trim(te.vehicle_code)) = lower(trim(c.vehicle_code))
       and lower(trim(te.fuel_type)) = lower(trim(c.fuel_type))
       and te.loading_pct = c.loading_pct
       and te.is_active = true
    where c.app_crop_id = p_crop_id
      and coalesce(c.is_deleted, false) = false;

    -- 3) material transport
    select
        coalesce(sum(
            case
                when lower(trim(te.ef_unit)) = 'kgco2e/tkm' then
                    coalesce(m.distance, 0) * (coalesce(m.stock_amount, 0) / 1000.0) * coalesce(te.ef_value, 0)
                when lower(trim(te.ef_unit)) = 'kgco2e/km' then
                    coalesce(m.distance, 0) * coalesce(te.ef_value, 0)
                else 0
            end
        ), 0),
        count(*) filter (where te.id is null)
    into v_material_kgco2e, v_missing_material_ef
    from public.dn_tb_r_cbf_material m
    left join public.dn_tb_m_cbf_transport_ef te
        on lower(trim(te.vehicle_code)) = lower(trim(m.vehicle_code))
       and lower(trim(te.fuel_type)) = lower(trim(m.fuel_type))
       and te.loading_pct = m.loading_pct
       and te.is_active = true
    where m.app_crop_id = p_crop_id
      and coalesce(m.is_deleted, false) = false;

    -- 4) fuel usage
    select
        coalesce(sum(
            coalesce(f.litres, 0) * coalesce(ee.ef_value, 0)
        ), 0),
        count(*) filter (where ee.id is null)
    into v_fuel_kgco2e, v_missing_fuel_ef
    from public.dn_tb_r_cbf_fuel f
    left join public.dn_tb_m_cbf_energy_ef ee
        on ee.ef_type = 'fuel'
       and lower(trim(ee.fuel_type)) = lower(trim(f.fuel_type))
       and ee.is_active = true
    where f.app_crop_id = p_crop_id
      and coalesce(f.is_deleted, false) = false;

    -- 5) electric usage
    select
        coalesce(sum(
            coalesce(e.kwh, 0) * coalesce(ee.ef_value, 0)
        ), 0),
        count(*) filter (where ee.id is null)
    into v_electric_kgco2e, v_missing_electric_ef
    from public.dn_tb_r_cbf_electric e
    left join public.dn_tb_m_cbf_energy_ef ee
        on ee.ef_type = 'electricity'
       and ee.is_active = true
    where e.app_crop_id = p_crop_id
      and coalesce(e.is_deleted, false) = false;

    v_total_kgco2e :=
        coalesce(v_fertilizer_kgco2e, 0)
        + coalesce(v_chemical_kgco2e, 0)
        + coalesce(v_material_kgco2e, 0)
        + coalesce(v_fuel_kgco2e, 0)
        + coalesce(v_electric_kgco2e, 0);

    v_per_kg_product := case
        when v_yield_kg > 0 then v_total_kgco2e / v_yield_kg
        else 0
    end;

    v_result := jsonb_build_object(
        'app_crop_id', p_crop_id,
        'yield_kg', v_yield_kg,
        'total_kgco2e', round(v_total_kgco2e, 3),
        'kgco2e_per_kg_product', round(v_per_kg_product, 6),
        'breakdown', jsonb_build_object(
            'fertilizer', jsonb_build_object(
                'kgco2e', round(v_fertilizer_kgco2e, 3),
                'percent', case when v_total_kgco2e > 0 then round((v_fertilizer_kgco2e / v_total_kgco2e) * 100, 2) else 0 end
            ),
            'chemical', jsonb_build_object(
                'kgco2e', round(v_chemical_kgco2e, 3),
                'percent', case when v_total_kgco2e > 0 then round((v_chemical_kgco2e / v_total_kgco2e) * 100, 2) else 0 end
            ),
            'electric', jsonb_build_object(
                'kgco2e', round(v_electric_kgco2e, 3),
                'percent', case when v_total_kgco2e > 0 then round((v_electric_kgco2e / v_total_kgco2e) * 100, 2) else 0 end
            ),
            'fuel', jsonb_build_object(
                'kgco2e', round(v_fuel_kgco2e, 3),
                'percent', case when v_total_kgco2e > 0 then round((v_fuel_kgco2e / v_total_kgco2e) * 100, 2) else 0 end
            ),
            'material', jsonb_build_object(
                'kgco2e', round(v_material_kgco2e, 3),
                'percent', case when v_total_kgco2e > 0 then round((v_material_kgco2e / v_total_kgco2e) * 100, 2) else 0 end
            )
        ),
        'warnings', jsonb_build_object(
            'missing_transport_ef', jsonb_build_object(
                'fertilizer', v_missing_fertilizer_ef,
                'chemical', v_missing_chemical_ef,
                'material', v_missing_material_ef
            ),
            'missing_energy_ef', jsonb_build_object(
                'fuel', v_missing_fuel_ef,
                'electric', v_missing_electric_ef
            )
        )
    );

    return v_result;
end;
$$;


ALTER FUNCTION "public"."get_cbf_summary_simple_v1"("p_crop_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_pending_commands"("_batch_size" integer) RETURNS TABLE("id" bigint, "device_id" "text", "payload" "jsonb", "created_at" timestamp with time zone, "client_id" "text", "token" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  return query
  with locked as (
    select c.id
    from dn_iot_commands c
    where
      c.status = 'PENDING'
      OR (
          c.status = 'PROCESSING'
          AND c.processing_at < now() - interval '30 seconds'
        )
    order by c.created_at asc
    limit _batch_size
    for update skip locked
  ),
  updated as (
    update dn_iot_commands c
    set
      status = 'PROCESSING',
      processing_at = now()
    from locked l
    where c.id = l.id
    returning
      c.id,
      c.device_id,
      c.payload,
      c.created_at
  )
  select
    u.id,
    u.device_id,
    u.payload,
    u.created_at,
    d.client_id,
    d.token
  from updated u
  join dn_iot_devices d
    on d.id = u.device_id;
end;
$$;


ALTER FUNCTION "public"."get_pending_commands"("_batch_size" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_product_detail"("p_product_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  v_shop_id uuid;
  v_result  jsonb;
BEGIN
  SELECT s.id INTO v_shop_id
  FROM mp_product p
  JOIN shop s ON s.id = p.shop_id
  WHERE p.product_id = p_product_id;

  IF v_shop_id IS NULL THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id;
  END IF;

  SELECT jsonb_build_object(
    'product_id',                    p.product_id,
    'product_name',                  p.product_name,
    'product_shop_name',             s.name,
    'shop_user_id',                  s.user_id,
    'product_availability',          CASE WHEN p.is_pre_order THEN 'พรีออร์เดอร์' ELSE 'พร้อมส่ง' END,
    'product_location',              COALESCE(sd.province_th, ''),
    'product_img_path',              COALESCE(p.img_path, ''),
    'gallery_img_path',              COALESCE(to_jsonb(p.gallery_paths), '[]'::jsonb),
    'product_recommended',           s.subscribe,
    'product_detail',                COALESCE(p.product_detail, ''),
    'product_min_price',             COALESCE(variants.min_price, 0),
    'product_max_price',             COALESCE(variants.max_price, 0),
    'is_product_soldout',            COALESCE(variants.is_soldout, true),
    'product_total_sales',           COALESCE(total_sales.cnt, 0),
    'product_average_review_score',  reviews_agg.avg_score,
    'product_variants',              COALESCE(variants.items, '[]'::jsonb),
    'product_reviews',               COALESCE(reviews.items, '[]'::jsonb),
    'product_delivery_rates',        COALESCE(delivery.items, '[]'::jsonb)
  )
  INTO v_result
  FROM mp_product p
  JOIN  shop        s  ON s.id  = p.shop_id
  LEFT JOIN sub_district sd ON sd.id = s.sub_district_id

  LEFT JOIN LATERAL (
    SELECT
      MIN(v.price_per_unit)                                AS min_price,
      MAX(v.price_per_unit)                                AS max_price,
      BOOL_AND(COALESCE(v.stock_quantity, 0) = 0)         AS is_soldout,
      jsonb_agg(
        jsonb_build_object(
          'variant_id',           v.id,
          'price',                COALESCE(v.price_per_unit, 0),
          'variant_name',         COALESCE(v.variant_name, ''),
          'variant_weight_value', COALESCE(v.variant_weight_value, 0),
          'variant_stock',        COALESCE(v.stock_quantity, 0),
          'total_sales',          COALESCE(vc.sales_count, 0),
          'img_path',             v.img_path,
          'per_unit_discount',    COALESCE(ap.per_unit_discount, 0),
          'discounted_price',     GREATEST(
                                    COALESCE(v.price_per_unit, 0)
                                    - COALESCE(ap.per_unit_discount, 0),
                                    0
                                  ),
          'limit_qty_per_order',  ap.limit_qty_per_order
        )
        ORDER BY v.id
      ) AS items
    FROM mp_product_variant v
    LEFT JOIN LATERAL (
      SELECT COUNT(*)::int AS sales_count
      FROM mp_order_items oi
      WHERE oi.product_variant_id = v.id
    ) vc ON true
    LEFT JOIN LATERAL (
      SELECT
        LEAST(
          ROUND(COALESCE(v.price_per_unit, 0)::numeric * pp.discount_amount::numeric) / 100.0,
          COALESCE(v.price_per_unit, 0)
        )                        AS per_unit_discount,
        pp.limit_qty_per_order
      FROM mp_promotion_products pp
      JOIN mp_promotion prom ON prom.id = pp.promotion_id
      WHERE pp.product_variant_id = v.id
        AND prom.shop_id          = v_shop_id
        AND NOW() >= prom.start_at::timestamptz
        AND NOW() <  prom.end_at::timestamptz
      LIMIT 1
    ) ap ON true
    WHERE v.product_id = p_product_id
      AND v.is_active  = true
  ) variants ON true

  LEFT JOIN LATERAL (
    SELECT COUNT(DISTINCT oi.order_id)::bigint AS cnt
    FROM mp_order_items  oi
    JOIN mp_product_variant pv ON pv.id       = oi.product_variant_id
    JOIN mp_order_sales     os ON os.order_id  = oi.order_id
    WHERE pv.product_id       = p_product_id
      AND os.payment_status   = 'COMPLETED'
  ) total_sales ON true

  LEFT JOIN LATERAL (
    SELECT
      CASE WHEN COUNT(*) > 0
        THEN TO_CHAR(AVG(r.rating), 'FM999990.00')
        ELSE NULL
      END AS avg_score
    FROM mp_reviews r
    JOIN mp_product_variant pv ON pv.id = r.product_variant_id
    WHERE r.subject_type    = 'product'
      AND pv.product_id     = p_product_id
  ) reviews_agg ON true

  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'review_id',            r.id,
        'user_name',            CONCAT_WS(' ', pr.first_name, pr.last_name), -- ← changed
        'user_img_path',        pr.img_path,
        'detail',               COALESCE(r.detail, ''),
        'rating',               r.rating,
        'variant_id',           pv.id,
        'variant_name',         COALESCE(pv.variant_name, ''),
        'variant_weight_value', COALESCE(pv.variant_weight_value, 0),
        'created_date',         r.created_at,
        'media',                COALESCE(media_agg.items, '[]'::jsonb)
      )
      ORDER BY r.rating DESC
    ) AS items
    FROM mp_reviews r
    JOIN profile            pr  ON pr.id  = r.user_id
    JOIN mp_product_variant pv  ON pv.id  = r.product_variant_id
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(jsonb_build_object(
        'media_type', m.media_type,
        'media_path', COALESCE(m.media_path, ''),
        'metadata',   m.metadata
      )) AS items
      FROM mp_review_media m
      WHERE m.review_id = r.id
    ) media_agg ON true
    WHERE r.subject_type  = 'product'
      AND pv.product_id   = p_product_id
  ) reviews ON true

  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'delivery_method_id', dm.delivery_method_id,
        'method_name',        COALESCE(dm.method_name, ''),
        'transit_days',       COALESCE(dm.transit_days, 0),
        'min_delivery_cost',  FLOOR(rate_agg.min_cost),
        'max_delivery_cost',  FLOOR(rate_agg.max_cost)
      )
    ) AS items
    FROM mp_product_delivery_config pdc
    JOIN mp_delivery_method dm ON dm.delivery_method_id = pdc.delivery_method_id
    JOIN (
      SELECT delivery_method_id,
             MIN(delivery_cost) AS min_cost,
             MAX(delivery_cost) AS max_cost
      FROM   mp_delivery_rate
      GROUP  BY delivery_method_id
    ) rate_agg ON rate_agg.delivery_method_id = dm.delivery_method_id
    WHERE pdc.product_id  = p_product_id
      AND dm.is_active    = true
  ) delivery ON true

  WHERE p.product_id = p_product_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id;
  END IF;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_product_detail"("p_product_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_products"("_search" "text" DEFAULT ''::"text", "_shop_id" "uuid" DEFAULT NULL::"uuid", "_category_ids" bigint[] DEFAULT NULL::bigint[], "_rating" integer[] DEFAULT NULL::integer[], "_region" "text"[] DEFAULT NULL::"text"[], "_availability" "text" DEFAULT NULL::"text") RETURNS TABLE("product_id" "uuid", "product_name" "text", "product_category" "text", "product_availability" "text", "is_boosted" boolean, "product_min_price" numeric, "product_max_price" numeric, "is_product_soldout" boolean, "product_average_review_score" numeric, "product_total_sales" integer, "address" "text", "address_region" "text", "product_img_path" "text", "first_product_variant_img_path" "text", "product_recommended" boolean, "shop_name" "text")
    LANGUAGE "sql" STABLE
    AS $$
  SELECT
    p.product_id,
    p.product_name,
    pc.category_name AS product_category,
    CASE WHEN p.is_pre_order THEN 'พรีออร์เดอร์' ELSE 'พร้อมส่ง' END AS product_availability,
    COALESCE(boost.is_boosted, false) AS is_boosted,

    price_stats.min_price AS product_min_price,
    price_stats.max_price AS product_max_price,
    price_stats.is_product_soldout,

    avg_rating.product_average_review_score,
    sales.product_total_sales,
    sd.province_th  AS address,
    sd.region_name  AS address_region,
    p.img_path      AS product_img_path,
    COALESCE(first_variant.img_path, '') AS first_product_variant_img_path,
    s.subscribe     AS product_recommended,
    COALESCE(s.name, '') AS shop_name

  FROM mp_product p
  JOIN master_product_category pc ON pc.category_id = p.product_category
  JOIN shop                    s  ON s.id = p.shop_id
  JOIN sub_district            sd ON sd.id = s.sub_district_id

  JOIN LATERAL (
    SELECT
      MIN(ROUND(GREATEST(pv.price_per_unit - COALESCE(promo.per_unit_discount, 0), 0), 2)) AS min_price,
      MAX(ROUND(GREATEST(pv.price_per_unit - COALESCE(promo.per_unit_discount, 0), 0), 2)) AS max_price,
      COALESCE(BOOL_AND(NOT pv.is_active), TRUE) AS is_product_soldout
    FROM mp_product_variant pv
    LEFT JOIN LATERAL (
      SELECT LEAST(ROUND((pv.price_per_unit * (pp.discount_amount / 100.0)), 2), pv.price_per_unit) AS per_unit_discount
      FROM mp_promotion pr
      JOIN mp_promotion_products pp
        ON pp.promotion_id = pr.id
       AND pp.product_variant_id = pv.id
      WHERE pr.shop_id = p.shop_id
        AND now() >= pr.start_at
        AND now() <  pr.end_at
      ORDER BY pr.created_at DESC
      LIMIT 1
    ) promo ON TRUE
    WHERE pv.product_id = p.product_id
  ) price_stats ON TRUE

  JOIN LATERAL (
    SELECT pv.img_path
    FROM mp_product_variant pv
    WHERE pv.product_id = p.product_id
    ORDER BY pv.id ASC
    LIMIT 1
  ) first_variant ON TRUE

  JOIN LATERAL (
    SELECT AVG(r.rating)::numeric(10,2) AS product_average_review_score
    FROM mp_reviews r
    JOIN mp_product_variant pv ON pv.id = r.product_variant_id
    WHERE r.subject_type = 'product'
      AND pv.product_id = p.product_id
  ) avg_rating ON TRUE

  JOIN LATERAL (
    SELECT COUNT(DISTINCT os.order_id)::int AS product_total_sales
    FROM mp_order_items oi
    JOIN mp_product_variant pv ON pv.id = oi.product_variant_id
    JOIN mp_order_sales     os ON os.order_id = oi.order_id
    WHERE pv.product_id = p.product_id
      AND os.payment_status = 'COMPLETED'
  ) sales ON TRUE

  LEFT JOIN LATERAL (
    SELECT TRUE AS is_boosted
    FROM tb_m_product_boost pb
    WHERE pb.product_id = p.product_id
      AND pb.boost_slot  = 'homepage'
      AND pb.status      = 'active'
      AND pb.expires_at  > now()
    LIMIT 1
  ) boost ON TRUE

  WHERE p.is_available = TRUE
    AND p.deleted_at IS NULL
    AND COALESCE(s.is_blacklisted, FALSE) = FALSE
    AND p.product_name ILIKE ('%' || COALESCE(_search, '') || '%')
    AND (_shop_id IS NULL OR p.shop_id = _shop_id)
    AND (_category_ids IS NULL OR CARDINALITY(_category_ids) = 0 OR p.product_category = ANY(_category_ids))
    AND (
      _rating IS NULL OR CARDINALITY(_rating) = 0
      OR avg_rating.product_average_review_score >= (SELECT MIN(x)::numeric(10,2) FROM UNNEST(_rating) AS t(x))
    )
    AND (_region IS NULL OR CARDINALITY(_region) = 0 OR sd.region_name = ANY(_region))
    AND (
      _availability IS NULL
      OR (_availability = 'พร้อมส่ง'      AND p.is_pre_order = FALSE)
      OR (_availability = 'พรีออร์เดอร์' AND p.is_pre_order = TRUE)
    )
    ORDER BY COALESCE(boost.is_boosted, FALSE) DESC, s.subscribe DESC, p.product_name;
$$;


ALTER FUNCTION "public"."get_products"("_search" "text", "_shop_id" "uuid", "_category_ids" bigint[], "_rating" integer[], "_region" "text"[], "_availability" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_products_paginated"("_search" "text" DEFAULT ''::"text", "_shop_id" "uuid" DEFAULT NULL::"uuid", "_category_ids" bigint[] DEFAULT NULL::bigint[], "_rating" integer[] DEFAULT NULL::integer[], "_region" "text"[] DEFAULT NULL::"text"[], "_availability" "text" DEFAULT NULL::"text", "_limit" integer DEFAULT 20, "_offset" integer DEFAULT 0) RETURNS "json"
    LANGUAGE "sql" STABLE
    AS $$
  WITH filtered AS (
    SELECT
      p.product_id,
      p.product_name,
      pc.category_name AS product_category,
      CASE WHEN p.is_pre_order THEN 'พรีออร์เดอร์' ELSE 'พร้อมส่ง' END AS product_availability,

      price_stats.min_price   AS product_min_price,
      price_stats.max_price   AS product_max_price,
      price_stats.is_product_soldout,

      avg_rating.product_average_review_score,
      sales.product_total_sales,
      sd.province_th          AS address,
      sd.region_name          AS address_region,
      p.img_path              AS product_img_path,
      COALESCE(first_variant.img_path, '') AS first_product_variant_img_path,
      s.subscribe             AS product_recommended,
      COALESCE(s.name, '')    AS shop_name,
      COALESCE(boost.is_boosted, FALSE) AS is_boosted   -- ← added

    FROM mp_product p
    JOIN master_product_category pc ON pc.category_id = p.product_category
    JOIN shop                    s  ON s.id = p.shop_id
    JOIN sub_district            sd ON sd.id = s.sub_district_id

    JOIN LATERAL (
      SELECT
        MIN(ROUND(GREATEST(pv.price_per_unit - COALESCE(promo.per_unit_discount, 0), 0), 2)) AS min_price,
        MAX(ROUND(GREATEST(pv.price_per_unit - COALESCE(promo.per_unit_discount, 0), 0), 2)) AS max_price,
        COALESCE(BOOL_AND(NOT pv.is_active), TRUE) AS is_product_soldout
      FROM mp_product_variant pv
      LEFT JOIN LATERAL (
        SELECT LEAST(ROUND((pv.price_per_unit * (pp.discount_amount / 100.0)), 2), pv.price_per_unit) AS per_unit_discount
        FROM mp_promotion pr
        JOIN mp_promotion_products pp
          ON pp.promotion_id = pr.id
         AND pp.product_variant_id = pv.id
        WHERE pr.shop_id = p.shop_id
          AND now() >= pr.start_at
          AND now() <  pr.end_at
        ORDER BY pr.created_at DESC
        LIMIT 1
      ) promo ON TRUE
      WHERE pv.product_id = p.product_id
    ) price_stats ON TRUE

    JOIN LATERAL (
      SELECT pv.img_path
      FROM mp_product_variant pv
      WHERE pv.product_id = p.product_id
      ORDER BY pv.id ASC
      LIMIT 1
    ) first_variant ON TRUE

    JOIN LATERAL (
      SELECT AVG(r.rating)::numeric(10,2) AS product_average_review_score
      FROM mp_reviews r
      JOIN mp_product_variant pv ON pv.id = r.product_variant_id
      WHERE r.subject_type = 'product'
        AND pv.product_id = p.product_id
    ) avg_rating ON TRUE

    JOIN LATERAL (
      SELECT COUNT(DISTINCT os.order_id)::int AS product_total_sales
      FROM mp_order_items oi
      JOIN mp_product_variant pv ON pv.id = oi.product_variant_id
      JOIN mp_order_sales     os ON os.order_id = oi.order_id
      WHERE pv.product_id = p.product_id
        AND os.payment_status = 'COMPLETED'
    ) sales ON TRUE

    LEFT JOIN LATERAL (
      SELECT TRUE AS is_boosted
      FROM tb_m_product_boost pb
      WHERE pb.product_id = p.product_id
        AND pb.boost_slot  = 'homepage'
        AND pb.status      = 'active'
        AND pb.expires_at  > now()
      LIMIT 1
    ) boost ON TRUE

    WHERE p.is_available = TRUE
      AND p.deleted_at IS NULL
      AND COALESCE(s.is_blacklisted, FALSE) = FALSE
      AND p.product_name ILIKE ('%' || COALESCE(_search, '') || '%')
      AND (_shop_id IS NULL OR p.shop_id = _shop_id)
      AND (_category_ids IS NULL OR CARDINALITY(_category_ids) = 0 OR p.product_category = ANY(_category_ids))
      AND (
        _rating IS NULL OR CARDINALITY(_rating) = 0
        OR avg_rating.product_average_review_score >= (SELECT MIN(x)::numeric(10,2) FROM UNNEST(_rating) AS t(x))
      )
      AND (_region IS NULL OR CARDINALITY(_region) = 0 OR sd.region_name = ANY(_region))
      AND (
        _availability IS NULL
        OR (_availability = 'พร้อมส่ง'      AND p.is_pre_order = FALSE)
        OR (_availability = 'พรีออร์เดอร์' AND p.is_pre_order = TRUE)
      )
  ),
  totals AS (
    SELECT COUNT(*)::int AS total_items
    FROM filtered
  ),
  ordered AS (
    SELECT *
    FROM filtered
    ORDER BY is_boosted DESC, product_recommended DESC, product_name ASC, product_id ASC
  ),
  page AS (
    SELECT *
    FROM ordered
    LIMIT  GREATEST(COALESCE(_limit, 0), 0)
    OFFSET GREATEST(COALESCE(_offset, 0), 0)
  )
  SELECT jsonb_build_object(
    'items',
      COALESCE(
        (SELECT jsonb_agg(to_jsonb(page) ORDER BY is_boosted DESC, product_recommended DESC, product_name ASC, product_id ASC) FROM page),
        '[]'::jsonb
      ),
    'pagination',
      jsonb_build_object(
        'currentPage',
          CASE
            WHEN COALESCE(_limit, 0) > 0 THEN (GREATEST(COALESCE(_offset, 0), 0) / _limit) + 1
            ELSE 1
          END,
        'totalPages',
          CASE
            WHEN COALESCE(_limit, 0) > 0 THEN CEIL((SELECT total_items FROM totals)::numeric / _limit)::int
            ELSE 1
          END,
        'totalItems',
          (SELECT total_items FROM totals),
        'hasMore',
          CASE
            WHEN COALESCE(_limit, 0) > 0 THEN (GREATEST(COALESCE(_offset, 0), 0) + _limit) < (SELECT total_items FROM totals)
            ELSE FALSE
          END
      )
  );
$$;


ALTER FUNCTION "public"."get_products_paginated"("_search" "text", "_shop_id" "uuid", "_category_ids" bigint[], "_rating" integer[], "_region" "text"[], "_availability" "text", "_limit" integer, "_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_provinces"() RETURNS TABLE("pro_id" bigint, "province_th" "text", "province_en" "text")
    LANGUAGE "sql" STABLE
    AS $$
  SELECT DISTINCT pro_id, province_th, province_en
  FROM sub_district
  ORDER BY province_th;
$$;


ALTER FUNCTION "public"."get_provinces"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_shop_total_orders"() RETURNS TABLE("order_id" "uuid", "order_code" "text", "order_status" "text", "created_at" timestamp with time zone, "payment_img_path" "text", "paid_at" timestamp with time zone, "confirmed_at" timestamp with time zone, "delivery_method_name" "text", "total_cost" integer, "customer_name" "text", "customer_line_id" "text", "customer_phone" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT
    os.order_id,
    os.order_code,
    CASE
      WHEN os.payment_status = 'PAYMENT_PENDING' AND os.created_at < NOW() - INTERVAL '24 hours' THEN 'หมดอายุแล้ว'
      WHEN os.payment_status = 'PAYMENT_PENDING' THEN 'รอการชำระเงิน'
      WHEN os.payment_status = 'EXPIRED' THEN 'หมดอายุแล้ว'
      WHEN os.payment_status = 'CANCELLED' THEN 'ยกเลิกแล้ว'
      WHEN os.payment_status = 'REFUND_PENDING' THEN 'รอการคืนเงิน'
      WHEN os.payment_status = 'REFUNDED' THEN 'คืนเงินแล้ว'
      WHEN os.payment_status = 'PAYMENT_AWAITING_CONFIRMATION'
           AND os.confirmed_at IS NULL
           AND os.paid_at < NOW() - INTERVAL '24 hours' THEN 'ยกเลิกแล้ว'
      WHEN os.payment_status = 'PAYMENT_AWAITING_CONFIRMATION' THEN 'รอการยืนยันออเดอร์'
      WHEN os.payment_status = 'DELIVERY_PENDING'
           AND os.confirmed_at < NOW() - os.transit_days * INTERVAL '1 day' THEN 'ยกเลิกแล้ว'
      WHEN os.payment_status = 'DELIVERY_PENDING' THEN 'อยู่ระหว่างการแพ็คสินค้า'
      WHEN os.payment_status = 'DELIVERING' THEN 'กำลังจัดส่ง'
      WHEN os.payment_status = 'COMPLETED' THEN 'จัดส่งสำเร็จ'
      WHEN os.payment_status = 'DISPUTED' THEN 'กำลังตรวจสอบ'
      ELSE 'ไม่ทราบสถานะ'
    END                                                            AS order_status,
    os.created_at,
    os.payment_img_path,
    os.paid_at,
    os.confirmed_at,
    os.delivery_method_name,
    (SUM(oi.line_total_after_discount) + os.delivery_cost)::int    AS total_cost,
    (os.selected_address_snapshot ->> 'receiver_name')             AS customer_name,
    p.line_user_id                                                 AS customer_line_id,
    (os.selected_address_snapshot ->> 'receiver_phone')            AS customer_phone
  FROM mp_order_sales os
  JOIN shop            s  ON s.id        = os.shop_id
  JOIN mp_order_items  oi ON oi.order_id = os.order_id
  JOIN profile         p  ON p.id        = os.customer_id
  WHERE s.user_id = auth.uid()
  GROUP BY
    os.order_id,
    os.payment_status,
    os.payment_img_path,
    os.paid_at,
    os.confirmed_at,
    os.delivery_method_name,
    os.delivery_cost,
    os.created_at,
    p.line_user_id,
    (os.selected_address_snapshot ->> 'receiver_name'),
    (os.selected_address_snapshot ->> 'receiver_phone')
  ORDER BY os.created_at DESC;
$$;


ALTER FUNCTION "public"."get_shop_total_orders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_tambons"("p_pro_id" bigint, "p_amp_id" bigint) RETURNS TABLE("tam_id" bigint, "tambon_th" "text", "tambon_en" "text", "postcode" bigint)
    LANGUAGE "sql" STABLE
    AS $$
  SELECT DISTINCT tam_id, tambon_th, tambon_en, postcode
  FROM sub_district
  WHERE pro_id = p_pro_id
    AND amp_id = p_amp_id
  ORDER BY tambon_th;
$$;


ALTER FUNCTION "public"."get_tambons"("p_pro_id" bigint, "p_amp_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_traceback_durian"("p_crop_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    v_crop record;
    v_land record;
    v_traceback record;

    v_personal_detail jsonb := null;
    v_farm_detail jsonb := null;
    v_crop_detail jsonb := null;
    v_fertilizing_detail jsonb := '[]'::jsonb;
    v_watering_detail jsonb := '[]'::jsonb;

    v_result jsonb;
begin

    -- 1️⃣ find crop
    select *
    into v_crop
    from public.dn_actions_crop
    where app_crop_id = p_crop_id
    limit 1;

    if not found then
        raise exception 'Crop not found for crop_id %', p_crop_id;
    end if;

    -- 2️⃣ find land
    select *
    into v_land
    from public.dn_tb_m_land
    where land_id = v_crop.app_land_id
    limit 1;

    if not found then
        raise exception 'Land not found for land_id %', v_crop.app_land_id;
    end if;

    -- 3️⃣ traceback config (ใช้ dn_crop_id)
    select *
    into v_traceback
    from public.traceback
    where dn_crop_id = p_crop_id
    limit 1;

    -- 4️⃣ personal detail
    if coalesce(v_traceback.show_personal_detail, true) then
        select jsonb_build_object(
            'id', p.id,
            'first_name', p.first_name,
            'last_name', p.last_name,
            'phone', p.phone
        )
        into v_personal_detail
        from public.profile p
        where p.dn_app_id = v_land.farmer_id
        limit 1;
    end if;

    -- 5️⃣ farm detail
    if coalesce(v_traceback.show_farm_detail, true) then
        v_farm_detail := jsonb_build_object(
            'land_type', v_land.land_type,
            'latitude', v_land.latitude,
            'longitude', v_land.longitude,
            'land_name', v_land.land_name,
            'no_of_rais', v_land.no_of_rais,
            'no_of_ngan', v_land.no_of_ngan,
            'no_of_wah', v_land.no_of_wah
        );
    end if;

    -- 6️⃣ crop detail
    if coalesce(v_traceback.show_crop_detail, true) then
        v_crop_detail := to_jsonb(v_crop);
    end if;

    -- 7️⃣ fertilizing activities
    if coalesce(v_traceback.show_activity_detail, true) then

        select coalesce(
            jsonb_agg(to_jsonb(f)),
            '[]'::jsonb
        )
        into v_fertilizing_detail
        from public.dn_operations_fertilizing f
        where f.app_crop_id = p_crop_id;

        -- watering activities
        select coalesce(
            jsonb_agg(to_jsonb(w)),
            '[]'::jsonb
        )
        into v_watering_detail
        from public.dn_operations_watering w
        where w.app_crop_id = p_crop_id;

    end if;

    -- 8️⃣ final result
    v_result := jsonb_build_object(
        'crop_id', p_crop_id,
        'land_id', v_crop.app_land_id,
        'personal_detail', v_personal_detail,
        'farm_detail', v_farm_detail,
        'crop_detail', v_crop_detail,
        'activity_detail', jsonb_build_object(
            'fertilizing', v_fertilizing_detail,
            'watering', v_watering_detail
        )
    );

    return v_result;

end;
$$;


ALTER FUNCTION "public"."get_traceback_durian"("p_crop_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_orders"("p_user_id" "uuid", "p_order_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_shop_id" "uuid" DEFAULT NULL::"uuid", "p_limit" integer DEFAULT NULL::integer, "p_offset" integer DEFAULT 0) RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  WITH orders_enriched AS (
    SELECT
      o.order_id,
      o.order_code,
      o.created_at,
      o.shop_id,
      s.name AS shop_name,

      o.delivery_method_name,
      o.transit_days::int    AS transit_days,
      o.delivery_cost::int   AS delivery_cost,
      o.payment_status,
      CASE
        WHEN o.payment_status = 'PAYMENT_PENDING' AND o.created_at < NOW() - INTERVAL '24 hours' THEN 'หมดอายุแล้ว'
        WHEN o.payment_status = 'PAYMENT_PENDING' THEN 'รอการชำระเงิน'
        WHEN o.payment_status = 'EXPIRED' THEN 'หมดอายุแล้ว'
        WHEN o.payment_status = 'CANCELLED' THEN 'ยกเลิกแล้ว'
        WHEN o.payment_status = 'REFUND_PENDING' THEN 'รอการคืนเงิน'
        WHEN o.payment_status = 'REFUNDED' THEN 'คืนเงินแล้ว'
        WHEN o.payment_status = 'PAYMENT_AWAITING_CONFIRMATION' AND o.confirmed_at IS NULL AND o.paid_at < NOW() - INTERVAL '24 hours' THEN 'ยกเลิกแล้ว'
        WHEN o.payment_status = 'PAYMENT_AWAITING_CONFIRMATION' THEN 'รอการยืนยันออเดอร์'
        WHEN o.payment_status = 'DELIVERY_PENDING' AND o.confirmed_at < NOW() - o.transit_days * INTERVAL '1 day' THEN 'ยกเลิกแล้ว'
        WHEN o.payment_status = 'DELIVERY_PENDING' THEN 'อยู่ระหว่างการแพ็คสินค้า'
        WHEN o.payment_status = 'DELIVERING' THEN 'กำลังจัดส่ง'
        WHEN o.payment_status = 'COMPLETED' THEN 'จัดส่งสำเร็จ'
        WHEN o.payment_status = 'DISPUTED' THEN 'กำลังตรวจสอบ'
        ELSE 'ไม่ทราบสถานะ'
      END AS order_status,

      json_agg(
        json_build_object(
          'variant_id',                       oi.product_variant_id,
          'quantity',                          oi.quantity,
          'product_name',                      p.product_name,
          'product_img_path',                  pv.img_path,
          'variant_name',                      pv.variant_name,
          'variant_weight_value',              pv.variant_weight_value,
          'price_per_unit',                    oi.unit_price_base::int,
          'is_discounted',                     (oi.per_unit_discount_applied > 0 AND oi.discounted_units > 0),
          'discount',                          oi.per_unit_discount_applied::int,
          'item_limit_qty',                    oi.limit_qty_per_order_applied,
          'discounted_units',                  oi.discounted_units,
          'full_price_units',                  oi.full_price_units,
          'final_unit_price_for_discounted',   GREATEST(oi.unit_price_base - oi.per_unit_discount_applied, 0)::int,
          'line_subtotal_base',                oi.line_subtotal_base::int,
          'line_discount_total',               oi.line_discount_total::int,
          'line_total_after_discount',         oi.line_total_after_discount::int
        )
        ORDER BY oi.product_variant_id
      ) AS products,

      SUM(oi.line_subtotal_base)::int                             AS total_product_price,
      SUM(oi.line_discount_total)::int                            AS discount_total,
      (SUM(oi.line_total_after_discount) + o.delivery_cost)::int AS total_cost

    FROM mp_order_sales o
    JOIN shop               s  ON s.id            = o.shop_id
    JOIN mp_order_items     oi ON oi.order_id      = o.order_id
    JOIN mp_product_variant pv ON pv.id            = oi.product_variant_id
    JOIN mp_product         p  ON p.product_id     = pv.product_id

    WHERE o.customer_id = p_user_id
      AND (p_order_ids IS NULL OR o.order_id = ANY(p_order_ids))
      AND (p_shop_id   IS NULL OR o.shop_id  = p_shop_id)

    GROUP BY
      o.order_id, o.order_code, o.created_at, o.shop_id, s.name,
      o.payment_status, o.delivery_method_name, o.transit_days, o.delivery_cost
  ),
  totals AS (
    SELECT count(*)::int AS total_items FROM orders_enriched
  ),
  page AS (
    SELECT *
    FROM orders_enriched
    ORDER BY created_at DESC
    LIMIT  CASE WHEN p_limit IS NOT NULL THEN GREATEST(p_limit, 0) END
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  )
  SELECT jsonb_build_object(
    'items',
      COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'order_id',             order_id,
              'order_code',           order_code,
              'shop_id',              shop_id,
              'shop_name',            shop_name,
              'created_at',           created_at,
              'order_status',         order_status,
              'total_product_price',  total_product_price,
              'delivery_cost',        delivery_cost,
              'discount_total',       discount_total,
              'total_cost',           total_cost,
              'delivery_method_name', delivery_method_name,
              'transit_days',         transit_days,
              'products',             products
            )
            ORDER BY created_at DESC
          )
          FROM page
        ),
        '[]'::jsonb
      ),
    'pagination',
      jsonb_build_object(
        'currentPage',
          CASE
            WHEN COALESCE(p_limit, 0) > 0
            THEN (GREATEST(COALESCE(p_offset, 0), 0) / p_limit) + 1
            ELSE 1
          END,
        'totalPages',
          CASE
            WHEN COALESCE(p_limit, 0) > 0
            THEN CEIL((SELECT total_items FROM totals)::numeric / p_limit)::int
            ELSE 1
          END,
        'totalItems', (SELECT total_items FROM totals),
        'hasMore',
          CASE
            WHEN COALESCE(p_limit, 0) > 0
            THEN (GREATEST(COALESCE(p_offset, 0), 0) + p_limit) < (SELECT total_items FROM totals)
            ELSE false
          END
      )
  );
$$;


ALTER FUNCTION "public"."get_user_orders"("p_user_id" "uuid", "p_order_ids" "uuid"[], "p_shop_id" "uuid", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_auth_user_created"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$declare
  DEFAULT_FIRSTNAME constant text := '<firstname>';
  DEFAULT_LASTNAME  constant text := '<lastname>';

  _fullname     text;
  _names        text[];
  _license_key  text;
begin
  -- fullname
  select coalesce(
           new.raw_user_meta_data::jsonb->>'name',
           concat(DEFAULT_FIRSTNAME, ' ', DEFAULT_LASTNAME)
         )
    into _fullname;

  select regexp_split_to_array(_fullname, E'\\s+')
    into _names;

  -- create profile
  insert into public.profile (id, first_name, last_name, img_path, phone, email)
  values (
    new.id,
    greatest(_names[1], rpad(_names[1], 3, '_')),
    coalesce(greatest(_names[2], rpad(_names[2], 3, '_')), DEFAULT_LASTNAME),
    new.raw_user_meta_data::jsonb->>'avatar_url',
    new.phone,
    new.email
  );

  -- create permissions
  insert into public.user_permissions (user_id)
  values (new.id);

  -- create license
  _license_key := 'FF'
    || floor(extract(epoch from clock_timestamp()) * 1000)::bigint
    || right(new.id::text, 6);

  insert into public.tb_m_license (user_id, license_type, expiration_date, is_active, license_key)
  values (new.id, 1, null, true, _license_key);

  return new;
end;$$;


ALTER FUNCTION "public"."handle_auth_user_created"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_ha_bridges_inserted"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.ha_command (bridge_id)
  values (new.id);


  return new;
end;
$$;


ALTER FUNCTION "public"."handle_ha_bridges_inserted"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_ha_states_inserted"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.ha_entities
  set current_state=new.state
  where state_ref=new.state_ref;

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_ha_states_inserted"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_profile_insert_or_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$begin
  execute format('select cc_set_claim(%s,%s,%s)', quote_literal(new.id::text), quote_literal('group'), 
				 quote_literal(array_to_json(array[new.group])));
  return new;
end;$$;


ALTER FUNCTION "public"."handle_profile_insert_or_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_user_permissions_insert_or_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$BEGIN
  -- Set the 'user_level' claim
  EXECUTE FORMAT(
    'SELECT cc_set_claim(%s, %s, %s)',
    quote_literal(NEW.user_id::text),
    quote_literal('user_level'),
    quote_literal(NEW.user_level)
  );

  -- Set the 'user_role' claim
  EXECUTE FORMAT(
    'SELECT cc_set_claim(%s, %s, %s)',
    quote_literal(NEW.user_id::text),
    quote_literal('user_role'),
    quote_literal(NEW.user_role)
  );

  -- Set the 'user_subscription' claim
  EXECUTE FORMAT(
    'SELECT cc_set_claim(%s, %s, %s)',
    quote_literal(NEW.user_id::text),
    quote_literal('user_subscription'),
    quote_literal(NEW.user_subscription)
  );

IF NEW.expired_date IS NOT NULL THEN
  EXECUTE FORMAT(
    'SELECT cc_set_claim(%s, %s, %s)',
    quote_literal(NEW.user_id::text),
    quote_literal('expired_date'),
    quote_literal(json_build_object('value', NEW.expired_date)::text)
  );
END IF;

  -- Conditionally set or delete the 'claims_admin' claim based on 'user_level'
  IF NEW.user_level > 1 THEN
    EXECUTE FORMAT(
      'SELECT cc_set_claim(%s, %s, %s)',
      quote_literal(NEW.user_id::text),
      quote_literal('claims_admin'),
      quote_literal('true')
    );
  ELSE
    EXECUTE FORMAT(
      'SELECT cc_delete_claim(%s, %s)',
      quote_literal(NEW.user_id::text),
      quote_literal('claims_admin')
    );
  END IF;

  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."handle_user_permissions_insert_or_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_news_comment_count"("news_id" "text") RETURNS "void"
    LANGUAGE "sql"
    AS $_$
UPDATE dn_tb_m_news SET no_of_comment = COALESCE(no_of_comment,0) + 1 WHERE news_id = $1;
$_$;


ALTER FUNCTION "public"."increment_news_comment_count"("news_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_news_like_count"("news_id" "text") RETURNS "void"
    LANGUAGE "sql"
    AS $_$
UPDATE dn_tb_m_news SET no_of_like = COALESCE(no_of_like,0) + 1 WHERE news_id = $1;
$_$;


ALTER FUNCTION "public"."increment_news_like_count"("news_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."misc_get_jwt_claims"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce((auth.jwt()), '{}'::jsonb);
$$;


ALTER FUNCTION "public"."misc_get_jwt_claims"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mp_order_sales_before_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  seqval bigint;
  today  text := to_char(now(), 'YYYYMMDD');
begin
  if new.order_code is null then
    seqval := nextval('mp_order_sales_code_seq');
    -- removed the "-" between segments
    new.order_code := 'ORD' || today || lpad(to_base36(seqval), 6, '0');
    -- if you prefer decimal only, replace with: lpad(seqval::text, 6, '0')
  end if;
  return new;
end
$$;


ALTER FUNCTION "public"."mp_order_sales_before_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."perform_weekly_strike_decay"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Update shops that haven't had a violation in the last 30 days
    UPDATE shop s
    SET total_strike_points = GREATEST(0, s.total_strike_points - 1),
        -- Automatically un-blacklist if points drop below threshold
        is_blacklisted = CASE 
            WHEN (s.total_strike_points - 1) < 5 THEN FALSE 
            ELSE s.is_blacklisted 
        END,
        blacklist_reason = CASE 
            WHEN (s.total_strike_points - 1) < 5 THEN NULL 
            ELSE s.blacklist_reason 
        END
    WHERE s.total_strike_points > 0
    AND NOT EXISTS (
        SELECT 1 
        FROM mp_seller_violations v 
        WHERE v.shop_id = s.id 
        AND v.created_at > NOW() - INTERVAL '30 days'
    );
END;
$$;


ALTER FUNCTION "public"."perform_weekly_strike_decay"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_activity_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.date > now() + interval '1 hour' THEN
        RAISE EXCEPTION 'ห้ามเพิ่มกิจกรรมในอนาคต';
      END IF;
      IF EXISTS (SELECT 1 FROM activity WHERE farm_id = NEW.farm_id AND type_id = 1 AND NEW.type_id = 1) THEN
        RAISE EXCEPTION 'ห้ามเพิ่มกิจกรรมลงปลูกมากกว่า 1 ครั้ง';
      END IF;
      IF EXISTS (
        SELECT 1 
        FROM activity 
        WHERE farm_id = NEW.farm_id 
          AND type_id = 1 
          AND NEW.date < date
      ) THEN
        RAISE EXCEPTION 'ห้ามเพิ่มกิจกรรมที่มีเวลามาก่อนกิจกรรมลงปลูก';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."prevent_activity_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_activity_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id THEN
        RAISE EXCEPTION 'Updates to the id column are not permitted.';
      END IF;
      IF OLD.type_id = 1 AND NEW.type_id <> OLD.type_id THEN
        RAISE EXCEPTION 'ห้ามแก้ไขประเภทกิจกรรมลงปลูก';
      END IF;
      IF EXISTS (
        SELECT 1 
        FROM activity 
        WHERE farm_id = NEW.farm_id 
          AND type_id != 1 
          AND NEW.date > date
      )
      AND NEW.type_id = 1 
      AND OLD.type_id = 1
      THEN
        RAISE EXCEPTION 'ห้ามแก้ไขวันที่กิจกรรมก่อนปลูกไปก่อนกิจกรรมอื่นๆ';
      END IF;
      IF EXISTS (
        SELECT 1 
        FROM activity 
        WHERE farm_id = NEW.farm_id 
          AND type_id = 1 
          AND NEW.date < date
      )
      AND NEW.type_id != 1 
      AND OLD.type_id != 1
      THEN
        RAISE EXCEPTION 'ห้ามแก้ไขกิจกรรมทุกชนิดมาก่อนเวลากิจกรรมลงปลูก';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."prevent_activity_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_comment_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id 
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."prevent_comment_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_cost_group_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id OR 
      NEW.create_date <> OLD.create_date OR
      NEW.update_date <> OLD.update_date OR
      NEW.user_id <> OLD.user_id or
      NEW.name <> OLD.name 
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."prevent_cost_group_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_cost_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
    IF NOT rls_is_admin() THEN
      IF NOT current_user = 'postgres' THEN
        IF NEW.create_date > now() THEN
          RAISE EXCEPTION 'ห้ามเพิ่มค่าใช้จ่ายล่วงหน้า';
        END IF;
      END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_cost_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_cost_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id OR 
      NEW.create_date <> OLD.create_date
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."prevent_cost_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_farm_group_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
    IF NOT rls_is_admin() THEN
      IF NOT current_user = 'postgres' THEN
        IF NEW.id <> OLD.id OR NEW.user_id <> OLD.user_id  THEN
          RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
        END IF;
      END IF;
    END IF;
    RETURN NEW;
END;$$;


ALTER FUNCTION "public"."prevent_farm_group_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_farm_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
    IF NOT rls_is_admin() THEN
      IF NOT current_user = 'postgres' THEN
        IF NEW.create_date > now() THEN
          RAISE EXCEPTION 'ห้ามเพิ่มฟาร์ม';
        END IF;
      END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_farm_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_farm_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id OR 
         NEW.create_date <> OLD.create_date 
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
      IF OLD.type_id IS NOT NULL AND NEW.type_id <> OLD.type_id THEN
        RAISE EXCEPTION 'Updates to type_id are not permitted unless changing from NULL to a non-NULL value.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."prevent_farm_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_group_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.group_id <> OLD.group_id OR NEW.admin_id <> OLD.admin_id THEN
        RAISE EXCEPTION 'Changing "group_id, admin_id" is not allowed';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_group_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_harvest_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
    IF NOT rls_is_admin() THEN
      IF NOT current_user = 'postgres' THEN
        IF NEW.create_date > now() THEN
          RAISE EXCEPTION 'ห้ามเพิ่มการเก็บเกี่ยวล่วงหน้า';
        END IF;
      END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_harvest_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_harvest_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id OR 
      NEW.create_date <> OLD.create_date 
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."prevent_harvest_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_media_limit"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -------------------------------------------------------------------
  -- CASE 1: a video is being added
  -------------------------------------------------------------------
  IF NEW.media_type = 'video' THEN
     -- any existing media means the limit is already reached
     IF EXISTS (
       SELECT 1
       FROM mp_review_media
       WHERE review_id = NEW.review_id
     ) THEN
       RAISE EXCEPTION
         'A review can contain only **one** video OR up to **four** images (review_id=%)', NEW.review_id;
     END IF;

  -------------------------------------------------------------------
  -- CASE 2: an image is being added
  -------------------------------------------------------------------
  ELSE                                    -- NEW.media_type = 'image'
     -- how many images are already linked?
     IF (
       SELECT count(*)
       FROM mp_review_media
       WHERE review_id = NEW.review_id
     ) >= 4 THEN
       RAISE EXCEPTION
         'Maximum 4 images per review (review_id=%)', NEW.review_id;
     END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_media_limit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_product_option_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id 
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."prevent_product_option_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_product_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id 
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."prevent_product_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_profile_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id OR 
      NEW.create_date <> OLD.create_date OR
      NEW.status <> OLD.status OR
      NEW."group" <> OLD."group" OR
      NEW.phone <> OLD.phone OR
      NEW.email <> OLD.email
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."prevent_profile_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_shop_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
  IF NOT rls_is_superadmin() THEN
    IF NOT current_user = 'postgres' THEN
      IF NEW.id <> OLD.id OR 
      THEN
        RAISE EXCEPTION 'Updates to the restricted columns are not permitted.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."prevent_shop_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_seller_funds"("p_batch_size" integer DEFAULT 200) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- We use a subquery to select a specific amount of IDs first
  -- FOR UPDATE SKIP LOCKED prevents multiple cron jobs from fighting over the same rows
  UPDATE public.mp_order_sales
  SET payout_status = 'transferable',
      commission_status = 'transferable'
  WHERE order_id IN (
    SELECT order_id
    FROM public.mp_order_sales
    WHERE payout_status = 'on_hold'
      AND transferable_at <= NOW()
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  );
END;
$$;


ALTER FUNCTION "public"."release_seller_funds"("p_batch_size" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_get_activity_can_be_modified"() RETURNS bigint
    LANGUAGE "sql"
    AS $$
  select
    a.activity_id
  from
    plot as p
    inner join
    activity as a
    on
      p.plot_id = a.plot_id
  where
    public.rls_is_admin() or
    public.rls_is_owner(p.user_id)
$$;


ALTER FUNCTION "public"."rls_get_activity_can_be_modified"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_get_field_can_be_modified"() RETURNS SETOF bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select field_id
  from field
  where public.rls_is_admin()
  or public.rls_is_owner(user_id)
$$;


ALTER FUNCTION "public"."rls_get_field_can_be_modified"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_get_groups_for_group_user"() RETURNS "uuid"[]
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  _my_groups uuid[];
begin

  if (not public.rls_is_group_user()) or (coalesce(jsonb_array_length(auth.jwt()->'groups'), 0) = 0) then
    return array[]::uuid[];
  end if;

  _my_groups := coalesce(
    (select array_agg(x::uuid) from jsonb_array_elements_text(auth.jwt()->'groups') as x),
    array[]::uuid[]
  );

  return _my_groups;

end
$$;


ALTER FUNCTION "public"."rls_get_groups_for_group_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_get_ha_entities_can_be_modified"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select id
  from ha_bridges
  where public.rls_is_admin()
  or public.rls_is_owner(owner_id)
$$;


ALTER FUNCTION "public"."rls_get_ha_entities_can_be_modified"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_get_ha_states_can_be_modified"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    e.state_ref
  from
    ha_bridges as b
    inner join
    ha_entities as e
    on
      b.id = e.bridge_id
  where
    public.rls_is_admin() or
    public.rls_is_owner(b.owner_id)
$$;


ALTER FUNCTION "public"."rls_get_ha_states_can_be_modified"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$select coalesce((auth.jwt()->'app_metadata'->'user_level')::integer > 1, false);$$;


ALTER FUNCTION "public"."rls_is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_is_farm_group_owner"("_group_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$DECLARE
    jwt_sub UUID;
BEGIN
    -- Check if _group_id is NULL, if so, return TRUE
    IF _group_id IS NULL THEN
        RETURN TRUE;
    END IF;

    -- Get the UUID from the JWT subject
    SELECT (auth.jwt() ->> 'sub')::uuid INTO jwt_sub;

    -- Check if the user represented by the JWT subject is the owner of the farm group
    RETURN EXISTS (
        SELECT 1
        FROM farm_group
        WHERE farm_group.id = _group_id
          AND farm_group.user_id = jwt_sub
    );
END;$$;


ALTER FUNCTION "public"."rls_is_farm_group_owner"("_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_is_farm_owner"("_farm_id" bigint) RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    jwt_sub UUID;
BEGIN
    -- Get the UUID from the JWT subject
    SELECT (auth.jwt()->>'sub')::uuid INTO jwt_sub;

    -- Check if the user represented by the JWT subject is the owner of the shop
    RETURN EXISTS (
        SELECT 1
        FROM farm
        WHERE id = _farm_id
          AND user_id = jwt_sub
    );
END;
$$;


ALTER FUNCTION "public"."rls_is_farm_owner"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_is_group_user"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce((auth.jwt()->'app_metadata'->'user_role')::integer = 2, false);
$$;


ALTER FUNCTION "public"."rls_is_group_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_is_owner"("_uid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce((auth.jwt()->>'sub')::uuid = _uid, false);
$$;


ALTER FUNCTION "public"."rls_is_owner"("_uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_is_product_owner"("_product_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    jwt_sub UUID;
BEGIN
    -- Get the UUID from the JWT subject
    SELECT (auth.jwt()->>'sub')::UUID INTO jwt_sub;

    -- Check if the user represented by the JWT subject is the owner of the product
    RETURN EXISTS (
        SELECT 1
        FROM product
        WHERE id = _product_id
          AND shop_id IN (
            SELECT id
            FROM shop
            WHERE user_id = jwt_sub
          )
          AND farm_id IN (
            SELECT id
            FROM farm
            WHERE user_id = jwt_sub
          )
    );
END;
$$;


ALTER FUNCTION "public"."rls_is_product_owner"("_product_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_is_shop_owner"("_shop_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    jwt_sub UUID;
BEGIN
    -- Get the UUID from the JWT subject
    SELECT (auth.jwt()->>'sub')::uuid INTO jwt_sub;

    -- Check if the user represented by the JWT subject is the owner of the shop
    RETURN EXISTS (
        SELECT 1
        FROM shop
        WHERE id = _shop_id
          AND user_id = jwt_sub
    );
END;
$$;


ALTER FUNCTION "public"."rls_is_shop_owner"("_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_is_superadmin"() RETURNS boolean
    LANGUAGE "sql"
    AS $$select coalesce((auth.jwt()->'app_metadata'->'user_level')::integer > 2, false);$$;


ALTER FUNCTION "public"."rls_is_superadmin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."to_base36"("n" bigint) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  chars text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  q bigint := n;
  r int;
  out text := '';
begin
  if q = 0 then
    return '0';
  end if;

  while q > 0 loop
    r := (q % 36);
    out := substr(chars, r+1, 1) || out;
    q := q / 36;
  end loop;

  return out;
end
$$;


ALTER FUNCTION "public"."to_base36"("n" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_old_pre_activity_status"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE pre_activity
    SET status = false
    WHERE date < (CURRENT_DATE - INTERVAL '2 months');
END;
$$;


ALTER FUNCTION "public"."update_old_pre_activity_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_can_manage_prices"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN (
        auth.jwt() ->> 'role' = 'service_role'
        OR (auth.jwt() -> 'user_metadata' ->> 'role') = 'admin'
        OR (auth.jwt() -> 'user_metadata' ->> 'role') = 'price_manager'
    );
END;
$$;


ALTER FUNCTION "public"."user_can_manage_prices"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_owns_crop"("target_app_land_id" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM dn_tb_m_land land
        JOIN profile p ON p.dn_app_id = land.farmer_id
        WHERE land.land_id = target_app_land_id
        AND p.id = auth.uid()
    );
END;
$$;


ALTER FUNCTION "public"."user_owns_crop"("target_app_land_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_owns_crop_by_id"("target_app_crop_id" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM dn_actions_crop crop
        JOIN dn_tb_m_land land ON land.land_id = crop.app_land_id
        JOIN profile p ON p.dn_app_id = land.farmer_id
        WHERE crop.app_crop_id = target_app_crop_id
        AND p.id = auth.uid()
    );
END;
$$;


ALTER FUNCTION "public"."user_owns_crop_by_id"("target_app_crop_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_owns_farm"("target_farmer_id" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM profile 
        WHERE profile.id = auth.uid() 
        AND profile.dn_app_id = target_farmer_id
    );
END;
$$;


ALTER FUNCTION "public"."user_owns_farm"("target_farmer_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_owns_land"("target_farmer_id" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM profile 
        WHERE profile.id = auth.uid() 
        AND profile.dn_app_id = target_farmer_id
    );
END;
$$;


ALTER FUNCTION "public"."user_owns_land"("target_farmer_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_owns_record"("target_user_id" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM profile 
        WHERE profile.id = auth.uid() 
        AND profile.dn_app_id = target_user_id
    );
END;
$$;


ALTER FUNCTION "public"."user_owns_record"("target_user_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_activity"("p_farm_id" bigint, "p_activity_type_id" bigint, "p_note" "text", "p_date" timestamp without time zone, "p_user_id" "uuid", "p_label_color" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    _activity_id int8;
BEGIN
    INSERT INTO activity (farm_id, type_id, note, create_date, date, user_id, label_color)
    VALUES (p_farm_id, p_activity_type_id, p_note, now(), p_date, p_user_id, p_label_color)
    returning id into _activity_id;

    RETURN json_build_object('activity_id', _activity_id);
END
$$;


ALTER FUNCTION "public"."util_add_activity"("p_farm_id" bigint, "p_activity_type_id" bigint, "p_note" "text", "p_date" timestamp without time zone, "p_user_id" "uuid", "p_label_color" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _activity_id int8;
    _farm_ids int8[];
    _farm_id int8;
BEGIN
    SELECT array_agg(id) INTO _farm_ids
    FROM farm
    WHERE "group" = ANY(_farm_group_arr);

    _farm_ids := array(SELECT DISTINCT unnest(array_cat(_farm_ids, _farm_id_arr)));

    IF _farm_ids IS NULL OR array_length(_farm_ids, 1) IS NULL THEN
      RETURN json_build_object('status', 'error', 'message', 'No valid farm IDs found');
    END IF;

    FOREACH _farm_id IN ARRAY _farm_ids
    LOOP
        INSERT INTO activity (farm_id, type_id, note, create_date, date, user_id, label_color)
        VALUES (_farm_id, _activity_type_id, _note, now(), _date, _user_id, _label_color)
        RETURNING id INTO _activity_id;
    END LOOP;

    RETURN json_build_object('activity_id', _activity_id);
END
$$;


ALTER FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text", "_img_path" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _activity_id int8;
    _farm_ids int8[];
    _farm_id int8;
BEGIN
    SELECT array_agg(id) INTO _farm_ids
    FROM farm
    WHERE "group" = ANY(_farm_group_arr);

    _farm_ids := array(SELECT DISTINCT unnest(array_cat(_farm_ids, _farm_id_arr)));

    IF _farm_ids IS NULL OR array_length(_farm_ids, 1) IS NULL THEN
      RETURN json_build_object('status', 'error', 'message', 'No valid farm IDs found');
    END IF;

    FOREACH _farm_id IN ARRAY _farm_ids
    LOOP
        INSERT INTO activity (farm_id, type_id, note, create_date, date, user_id, label_color, img_path)
        VALUES (_farm_id, _activity_type_id, _note, now(), _date, _user_id, _label_color, _img_path);
    END LOOP;

    RETURN json_build_object('status', 'success', 'message', 'Activities added');
END
$$;


ALTER FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text", "_img_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_cost"("_user_id" "uuid", "_cost_group_id" bigint, "_detail" "text", "_price" double precision, "_category" "text", "_date" timestamp without time zone) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
    DECLARE
      _cost_id int8;
    begin
      INSERT INTO cost (user_id, "group", detail, price, category, date)
      VALUES (_user_id, _cost_group_id, _detail, _price, _category, _date)
      RETURNING id INTO _cost_id;

      RETURN json_build_object('cost_id', _cost_group_id);
    end
  $$;


ALTER FUNCTION "public"."util_add_cost"("_user_id" "uuid", "_cost_group_id" bigint, "_detail" "text", "_price" double precision, "_category" "text", "_date" timestamp without time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_cost_group"("_name" "text", "_user_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
    DECLARE
      _cost_group_id int8;
    begin
      INSERT INTO cost_group (name, user_id)
      VALUES (_name, _user_id)
      RETURNING id INTO _cost_group_id;

      RETURN json_build_object('cost_group_id', _cost_group_id);
    end
  $$;


ALTER FUNCTION "public"."util_add_cost_group"("_name" "text", "_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_farm"("_user_id" "uuid", "_name" "text", "_address" "text", "_area_size" bigint, "_type_id" bigint, "_sub_district_id" bigint, "_geometry" "extensions"."geometry", "_title_deed_no" "text", "_village_name" "text" DEFAULT NULL::"text", "_moo" "text" DEFAULT NULL::"text", "_road" "text" DEFAULT NULL::"text", "_soi" "text" DEFAULT NULL::"text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  _farm_id int8;
BEGIN
  INSERT INTO farm (user_id, name, address, area_size, type_id, sub_district_id, geometry, title_deed_no, village_name, moo, road, soi)
  VALUES (_user_id, _name, _address, _area_size, _type_id, _sub_district_id, _geometry, _title_deed_no, _village_name, _moo, _road, _soi)
  RETURNING id INTO _farm_id;

  RETURN json_build_object('farm_id', _farm_id);
END;
$$;


ALTER FUNCTION "public"."util_add_farm"("_user_id" "uuid", "_name" "text", "_address" "text", "_area_size" bigint, "_type_id" bigint, "_sub_district_id" bigint, "_geometry" "extensions"."geometry", "_title_deed_no" "text", "_village_name" "text", "_moo" "text", "_road" "text", "_soi" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_farm_group"("_name" "text", "_farm_ids" bigint[]) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  _farm_group_id int8;
  f_id int8;
  _user_id uuid;
BEGIN
  -- Get the user_id from the JWT
  _user_id := (auth.jwt()->>'sub')::uuid;


  IF _user_id IS NULL THEN
    RAISE EXCEPTION 'User ID is missing or invalid.';
  END IF;


  INSERT INTO farm_group (name, user_id)
  VALUES (_name, _user_id)
  RETURNING id INTO _farm_group_id;


  FOREACH f_id IN ARRAY _farm_ids
  LOOP
    UPDATE farm
    SET "group" = _farm_group_id
    WHERE id = f_id;
  END LOOP;

  RETURN json_build_object('farm_id', _farm_ids, 'farm_group_id', _farm_group_id);
END;$$;


ALTER FUNCTION "public"."util_add_farm_group"("_name" "text", "_farm_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_group"("_group_name" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
      INSERT INTO "group" (name)
      values (_group_name);
    end$$;


ALTER FUNCTION "public"."util_add_group"("_group_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_harvest"("_user_id" "uuid", "_amount" double precision, "_farm_id" bigint, "_date" timestamp without time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
      INSERT INTO public.harvest (user_id, amount, farm_id, create_date,date)
      values (_user_id, _amount, _farm_id, now(), _date);
    end$$;


ALTER FUNCTION "public"."util_add_harvest"("_user_id" "uuid", "_amount" double precision, "_farm_id" bigint, "_date" timestamp without time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.tb_m_planting_cycles (
    farm_id,
    cycle_name,
    area_usage_rai,
    crop_age,
    crop_age_unit,
    crop_name,
    total_trees,
    growth_month_start,
    growth_month_end,
    harvest_month_start,
    harvest_month_end,
    expected_annual_yield
  ) VALUES (
    _farm_id,
    _cycle_name,
    _area_usage_rai,
    _crop_age,
    _crop_age_unit,
    _crop_name,
    NULLIF(_total_trees, 0),
    _growth_month_start,
    _growth_month_end,
    _harvest_month_start,
    _harvest_month_end,
    _expected_annual_yield
  );

  UPDATE public.farm
  SET type_id     = _type_id,
      update_date = NOW()
  WHERE id = _farm_id;
END;
$$;


ALTER FUNCTION "public"."util_add_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_product"("_name" "text", "_detail" "json", "_categories" "text", "_shop_id" "uuid", "_shipping" "json") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
  pro_id uuid;
begin 
  insert into product (name, detail, categories, shop_id , shipping)
  values (_name, _detail, _categories, _shop_id, _shipping)
  returning id into pro_id;

  return json_build_object('product_id', pro_id);
end;
$$;


ALTER FUNCTION "public"."util_add_product"("_name" "text", "_detail" "json", "_categories" "text", "_shop_id" "uuid", "_shipping" "json") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_product_in_shop"("_shop_id" "uuid", "_product_detail" "json", "_product_option_detail" "json") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _name TEXT;
    _detail JSON;
    _categories TEXT;
    _shipping JSON;

    _price INT4;
    _unit TEXT;
    _stock INT4;
    _product_id UUID;

    option JSON;
    option_count INT;
    product_json JSON;
BEGIN 
    -- Check if product detail is not null
    IF _product_detail IS NOT NULL THEN
        -- Extract fields from product detail JSON
        _name := _product_detail->>'name';
        _detail := _product_detail->'detail';
        _categories := _product_detail->>'categories';
        _shipping := _product_detail->'shipping';

        -- Ensure required fields are present
        IF _name IS NOT NULL AND _detail IS NOT NULL THEN
            -- Call util_add_product function and get the product JSON
            product_json := util_add_product(_name, _detail, _categories, _shop_id, _shipping);
            _product_id := (product_json->>'product_id')::UUID;
        ELSE
            RAISE NOTICE 'Missing required elements in _product_detail JSON';
            RETURN NULL;
        END IF;
    ELSE
        RAISE NOTICE 'Product detail is null';
        RETURN NULL;
    END IF;

    -- Check if product option detail is not null
    IF _product_option_detail IS NOT NULL THEN
        option_count := json_array_length(_product_option_detail);

        -- Ensure the JSON array is not empty
        IF option_count > 0 THEN
            -- Iterate over each option in the product option detail JSON array
            FOR option IN SELECT * FROM json_array_elements(_product_option_detail) LOOP
                -- Extract fields from each option
                _name := option->>'name';
                _detail := option->'detail';
                _price := (option->>'price')::INT4;
                _unit := option->>'unit';
                _stock := (option->>'stock')::INT4;

                -- Ensure required fields are present
                IF _name IS NOT NULL AND _detail IS NOT NULL AND _price IS NOT NULL AND _unit IS NOT NULL AND _stock IS NOT NULL THEN
                    -- Call util_add_product_option function
                    PERFORM util_add_product_option(_product_id, _name, _detail, _price, _unit, _stock);
                ELSE
                    RAISE NOTICE 'Missing required elements in _product_option_detail JSON array element';
                END IF;
            END LOOP;
        ELSE
            RAISE NOTICE '_product_option_detail JSON array is empty';
        END IF;
    END IF;

    -- Return the added product ID
    RETURN _product_id;
END;
$$;


ALTER FUNCTION "public"."util_add_product_in_shop"("_shop_id" "uuid", "_product_detail" "json", "_product_option_detail" "json") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_product_option"("_product_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin 
  insert into product_option (product_id, name, detail, price, unit, stock)
  values (_product_id, _name, _detail, _price, _unit, _stock);

end;
$$;


ALTER FUNCTION "public"."util_add_product_option"("_product_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_shop"("_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_user_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
  shop_id uuid;
begin 
  insert into shop ( name, detail, address, phone, line_id, user_id)
  values ( _name, _detail, _address, _phone, _line_id, _user_id)
  returning id into shop_id;

  RETURN json_build_object('shop_id', shop_id);
end;
$$;


ALTER FUNCTION "public"."util_add_shop"("_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_add_standard"("_user_id" "uuid", "_detail" "json", "_type_id" bigint, "_file_path" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
  declare 
    _standard_id uuid;
  begin
    insert into standard (user_id, type_id, detail, file_path)
    values (_user_id, _type_id, _detail, _file_path)
    returning id into _standard_id;

    RETURN json_build_object('id', _standard_id);
  end
$$;


ALTER FUNCTION "public"."util_add_standard"("_user_id" "uuid", "_detail" "json", "_type_id" bigint, "_file_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_cal_cost_by_group"("_group_id" bigint) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE  
  sum_total int8; 
BEGIN
  SELECT COALESCE(SUM(price),0) INTO sum_total
  FROM cost
  WHERE "group" = _group_id;

  RETURN json_build_object('sum_total', sum_total, 'group_id', _group_id);
END;
$$;


ALTER FUNCTION "public"."util_cal_cost_by_group"("_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_create_farm_group_and_farms"("_user_id" "uuid", "_group_name" "text", "_farms" "json") RETURNS bigint[]
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_group_id BIGINT;
    v_farm JSON;
    v_farm_id BIGINT;
    farm_ids BIGINT[] := ARRAY[]::BIGINT[];  -- Initialize an empty array
BEGIN
    -- Check if the number of farms exceeds 100
    IF json_array_length(_farms) > 100 THEN
        RAISE EXCEPTION 'Number of farms exceeds the maximum limit of 100';
    END IF;

    -- Create a new farm group
    INSERT INTO farm_group (name, user_id)
    VALUES (_group_name, _user_id)
    RETURNING id INTO v_group_id;

    -- Loop through the farms in the JSON array and create each farm
    FOR v_farm IN SELECT * FROM json_array_elements(_farms)
    LOOP
        -- Insert each farm and capture the inserted farm ID
        INSERT INTO farm (
            name,
            type_id,
            address,
            area_size,
            user_id,
            "group",
            sub_district_id,
            snapshot_url,
            title_deed_no,
            geometry
        )
        VALUES (
            v_farm->>'name',
            (v_farm->>'type_id')::bigint,
            v_farm->>'address',
            (v_farm->>'area_size')::bigint,
            _user_id,
            v_group_id,
            (v_farm->>'sub_district_id')::bigint,
            v_farm->>'snapshot_url',
            v_farm->>'title_deed_no',
            v_farm->>'geometry'
        )
        RETURNING id INTO v_farm_id;

        -- Append each farm_id to the farm_ids array
        farm_ids := array_append(farm_ids, v_farm_id);
    END LOOP;

    -- Return the array of newly created farm IDs
    RETURN farm_ids;
END;
$$;


ALTER FUNCTION "public"."util_create_farm_group_and_farms"("_user_id" "uuid", "_group_name" "text", "_farms" "json") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_create_farm_group_and_farms_mobile"("_user_id" "uuid", "_group_name" "text", "_farms" "json") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$DECLARE
    v_group_id BIGINT;
    v_farm JSON;
    v_farm_id BIGINT;
    farm_data JSONB := '[]'::JSONB; -- Initialize an empty JSONB array
BEGIN
    -- Check if the number of farms exceeds 100
    IF json_array_length(_farms) > 100 THEN
        RAISE EXCEPTION 'Number of farms exceeds the maximum limit of 100';
    END IF;

    -- Create a new farm group
    INSERT INTO farm_group (name, user_id)
    VALUES (_group_name, _user_id)
    RETURNING id INTO v_group_id;

    -- Loop through the farms in the JSON array and create each farm
    FOR v_farm IN SELECT * FROM json_array_elements(_farms)
    LOOP
        -- Insert each farm and capture the inserted farm ID
        INSERT INTO farm (
            name,
            type_id,
            address,
            area_size,
            user_id,
            "group",
            sub_district_id,
            snapshot_url,
            title_deed_no,
            geometry
        )
        VALUES (
            v_farm->>'name',
            (v_farm->>'type_id')::bigint,
            v_farm->>'address',
            (v_farm->>'area_size')::bigint,
            _user_id,
            v_group_id,
            (v_farm->>'sub_district_id')::bigint,
            v_farm->>'snapshot_url',
            v_farm->>'title_deed_no',
            v_farm->>'geometry'
        )
        RETURNING id INTO v_farm_id;

        -- Add each farm_id and type_id as a JSON object to the farm_data array
        farm_data := farm_data || jsonb_build_array(
            jsonb_build_object(
                'farm_id', v_farm_id,
                'type_id', (v_farm->>'type_id')::bigint,
                'group_id', v_group_id
            )
        );
    END LOOP;

    -- Return the JSON array of farm IDs paired with type IDs
    RETURN farm_data::JSON;
END;$$;


ALTER FUNCTION "public"."util_create_farm_group_and_farms_mobile"("_user_id" "uuid", "_group_name" "text", "_farms" "json") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_activity"("_activity_id" bigint) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
    declare
      _img_path text;
    begin
      delete from activity
      where activity.id = _activity_id
      returning img_path into _img_path;

      RETURN json_build_object('activity_img_path', _img_path); 
    end
  $$;


ALTER FUNCTION "public"."util_delete_activity"("_activity_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_client"("_client_id" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM client
    WHERE id = _client_id;
END;
$$;


ALTER FUNCTION "public"."util_delete_client"("_client_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_client_order"("_client_order_id" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM client_order
    WHERE id = _client_order_id;
END;
$$;


ALTER FUNCTION "public"."util_delete_client_order"("_client_order_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_cost"("_cost_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
    begin
      delete from cost
      where id = _cost_id;
    end
  $$;


ALTER FUNCTION "public"."util_delete_cost"("_cost_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_cost_group"("_cost_group_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
    begin
      delete from cost_group
      where id = _cost_group_id;
    end
  $$;


ALTER FUNCTION "public"."util_delete_cost_group"("_cost_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_farm"("_farm_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
      delete from farm
      where id = _farm_id;
    end$$;


ALTER FUNCTION "public"."util_delete_farm"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_farm_group"("_farm_group_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
    begin
      delete from farm_group
      where id = _farm_group_id;
    end
  $$;


ALTER FUNCTION "public"."util_delete_farm_group"("_farm_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_group"("_group_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
      delete from "group"
      where "group".id = _group_id;
    end$$;


ALTER FUNCTION "public"."util_delete_group"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_harvest"("_harvest_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM harvest
    WHERE id = _harvest_id;
END;
$$;


ALTER FUNCTION "public"."util_delete_harvest"("_harvest_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_order_history"("_order_history_id" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM order_history_file
    WHERE id = _order_history_id;
END;
$$;


ALTER FUNCTION "public"."util_delete_order_history"("_order_history_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_product"("_product_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
  deleted_product uuid;
begin 
  delete from product
  where id = _product_id
  returning id into deleted_product;

  return json_build_object('product_id', deleted_product);
end;
$$;


ALTER FUNCTION "public"."util_delete_product"("_product_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_product_option"("_product_option_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin 
  delete from product_option 
  where id = _product_option_id;
end;
$$;


ALTER FUNCTION "public"."util_delete_product_option"("_product_option_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_quota"("_quota_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM quota
    WHERE id = _quota_id;
END;
$$;


ALTER FUNCTION "public"."util_delete_quota"("_quota_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_quota_item"("_quota_item_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM quota
    WHERE id = _quota_item_id;
END;
$$;


ALTER FUNCTION "public"."util_delete_quota_item"("_quota_item_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_delete_standard"("_standard_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
    delete from standard
    where id = _standard_id;
  end$$;


ALTER FUNCTION "public"."util_delete_standard"("_standard_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_add_device"("_device_id" "text", "_owner_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    _device_owner_id uuid;
begin
    -- Validate parameters
    if nullif(trim(_device_id), '') is null
       or _owner_id is null then
        return json_build_object(
            'status', 400,
            'error', 'Missing parameters'
        );
    end if;

    -- Check owner exists
    if not exists (
        select 1
        from profile p
        where p.id = _owner_id
    ) then
        return json_build_object(
            'status', 404,
            'error', 'Owner not found'
        );
    end if;

    -- Check device exists
    select d.owner_id
    into _device_owner_id
    from dn_iot_devices d
    where d.id = _device_id;

    if not found then
        return json_build_object(
            'status', 404,
            'error', 'Device not found'
        );
    end if;

    -- Prevent reassignment
    if _device_owner_id is not null then
        return json_build_object(
            'status', 409,
            'error', 'Device already connected'
        );
    end if;

    -- Update owner
    update dn_iot_devices d
    set owner_id = _owner_id
    where d.id = _device_id;

    return json_build_object(
        'status', 200,
        'success', true
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', sqlerrm
        );
end;
$$;


ALTER FUNCTION "public"."util_dn_iot_add_device"("_device_id" "text", "_owner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_all_info"() RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    result json;
begin
    select coalesce(json_agg(all_info), '[]'::json)
    into result
    from (
        select *
        from dn_iot_supply_list
    ) as all_info;

    return json_build_object(
        'status', 200,
        'data', result
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', 'Internal Server Error'
        );
end;
$$;


ALTER FUNCTION "public"."util_dn_iot_all_info"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_check_amount_qc"("_supplier_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    _success_count bigint;
    _failed_count bigint;
begin
    -- Count successful QC
    select count(*)
    into _success_count
    from dn_iot_supply_list l
    where l.supplier_id = _supplier_id
      and l.soil_sensor is true
      and l.air_sensor is true
      and l.relay is true;

    -- Count failed QC
    select count(*)
    into _failed_count
    from dn_iot_supply_list l
    where l.supplier_id = _supplier_id
      and (
            l.soil_sensor is false
         or l.air_sensor is false
         or l.relay is false
      )
      and l.soil_sensor is not null
      and l.air_sensor is not null
      and l.relay is not null;

    return json_build_object(
        'status', 200,
        'success', true,
        'data', json_build_object(
            'success', _success_count,
            'failed', _failed_count
        )
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', sqlerrm
        );
end;
$$;


ALTER FUNCTION "public"."util_dn_iot_check_amount_qc"("_supplier_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_check_device_installed"("_search" "text" DEFAULT NULL::"text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    result json;
    _search_text text;
begin
    _search_text := coalesce(trim(_search), '');

    select coalesce(json_agg(device_installed), '[]'::json)
    into result
    from (
        select
            d.id,
            l.serial_number,
            l.number_device,
            concat_ws(' ', p.first_name, p.last_name) as farmer_name,
            sd.province_th,
            l.address,
            d.status,
            d.last_seen,
            concat_ws(' ', pl.first_name, pl.last_name) as electrician_name,
            l.created_at_install as install_date
        from dn_iot_supply_list l
        left join dn_iot_devices d
            on l.device_id = d.id
        left join profile p
            on p.id = d.owner_id
        left join profile pl
            on pl.id = l.electrician_id
        left join sub_district sd
            on sd.id = l.sub_district_id
        where _search_text = ''
           or d.id::text ilike '%' || _search_text || '%'
           or concat_ws(' ', p.first_name, p.last_name) ilike '%' || _search_text || '%'
           or concat_ws(' ', pl.first_name, pl.last_name) ilike '%' || _search_text || '%'
           or l.serial_number ilike '%' || _search_text || '%'
           or l.number_device ilike '%' || _search_text || '%'
           or sd.province_th ilike '%' || _search_text || '%'
        order by d.id asc
    ) as device_installed;

    return json_build_object(
        'status', 200,
        'success', true,
        'data', result
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', sqlerrm
        );
end;
$$;


ALTER FUNCTION "public"."util_dn_iot_check_device_installed"("_search" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_count_summary"() RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    _total_count int;
    _online_count int;
    _offline_count int;
    _by_province json;
begin
    -- Count all devices
    select count(*)::int
    into _total_count
    from dn_iot_devices d;

    -- Count online devices
    select count(*)::int
    into _online_count
    from dn_iot_devices d
    where d.status = 'online';

    -- Count offline devices
    select count(*)::int
    into _offline_count
    from dn_iot_devices d
    where d.status = 'offline';

    -- Province breakdown
    -- dn_iot_supply_list does not have pro_id/province_id directly.
    -- Province is resolved through sub_district_id -> sub_district.province_th.
    select coalesce(json_agg(province_result order by province_result ->> 'province_th'), '[]'::json)
    into _by_province
    from (
        select json_build_object(
            'province_th', sd.province_th,
            'online', count(d.*) filter (where d.status = 'online')::int,
            'offline', count(d.*) filter (where d.status = 'offline')::int,
            'total', count(d.*) filter (where d.status in ('online', 'offline'))::int
        ) as province_result
        from dn_iot_supply_list l
        join sub_district sd
            on sd.id = l.sub_district_id
        left join dn_iot_devices d
            on d.id = l.device_id
        group by sd.province_th
    ) province_summary;

    return json_build_object(
        'status', 200,
        'data', json_build_object(
            'summary', json_build_object(
                'total', _total_count,
                'online', _online_count,
                'offline', _offline_count
            ),
            'by_province', _by_province
        )
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', sqlerrm
        );
end;
$$;


ALTER FUNCTION "public"."util_dn_iot_count_summary"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_get_device_list"() RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    result json;
    _user_id uuid := auth.uid();
    _is_admin boolean;
begin
    -- Validate authenticated user
    if _user_id is null then
        return json_build_object(
            'status', 401,
            'error', 'Authentication error'
        );
    end if;

    -- Check if user is admin (user_level = 2)
    select exists (
        select 1
        from user_permissions up
        where up.user_id = _user_id
          and up.user_level = 2
    )
    into _is_admin;

    /*
     * NOTE:
     * Original Edge Function uses service role for admin users,
     * which can bypass RLS and list all devices.
     *
     * This SQL function is security invoker, so even if _is_admin = true,
     * RLS policies on dn_iot_devices may still restrict visible rows.
     * To fully match the Edge Function behavior, this function may need
     * security definer with a safe search_path, or matching RLS policies.
     */

    select coalesce(json_agg(device_list), '[]'::json)
    into result
    from (
        select
            d.id,
            d.name,
            d.status,
            d.config::jsonb #>> '{data,desired,cmd,mode}' as mode
        from dn_iot_devices d
        where _is_admin
           or d.owner_id = _user_id
        order by d.id asc
    ) as device_list;

    return json_build_object(
        'status', 200,
        'success', true,
        'data', result
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', sqlerrm
        );
end;
$$;


ALTER FUNCTION "public"."util_dn_iot_get_device_list"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_get_device_log"("_device_id" "text", "_date" "text", "_type_id" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $_$
declare
    result json;
    _type_id_num int;
    _date_start timestamptz;
    _date_end timestamptz;
begin
    -- Validate authenticated user
    if auth.uid() is null then
        return json_build_object(
            'status', 401,
            'error', 'Authentication error'
        );
    end if;

    -- Validate device_id
    if nullif(trim(_device_id), '') is null then
        return json_build_object(
            'status', 400,
            'error', 'device_id is required'
        );
    end if;

    -- Validate type_id
    if nullif(trim(_type_id), '') is null then
        return json_build_object(
            'status', 400,
            'error', 'type_id is required (number)'
        );
    end if;

    begin
        _type_id_num := _type_id::int;
    exception
        when invalid_text_representation then
            return json_build_object(
                'status', 400,
                'error', 'type_id is required (number)'
            );
    end;

    -- Validate date
    if nullif(trim(_date), '') is null then
        return json_build_object(
            'status', 400,
            'error', 'date is required (format: ''YYYY-MM-DD'')'
        );
    end if;

    if trim(_date) !~ '^\d{4}-\d{2}-\d{2}$' then
        return json_build_object(
            'status', 400,
            'error', 'date must be ''YYYY-MM-DD'''
        );
    end if;

    begin
        _date_start := (trim(_date) || ' 00:00:00+00')::timestamptz;
        _date_end := _date_start + interval '1 day';
    exception
        when others then
            return json_build_object(
                'status', 400,
                'error', 'Invalid date'
            );
    end;

    if to_char(_date_start at time zone 'UTC', 'YYYY-MM-DD') <> trim(_date) then
        return json_build_object(
            'status', 400,
            'error', 'Invalid date'
        );
    end if;

    -- Relay log: type_id = 7
    if _type_id_num = 7 then
        select coalesce(json_agg(relay_log), '[]'::json)
        into result
        from (
            select
                s.payload,
                s.created_at,
                s.mode
            from dn_iot_sensor s
            where s.device_id = _device_id
              and s.sensor_type_id = 7
              and s.created_at >= _date_start
              and s.created_at < _date_end
            order by s.created_at desc
            limit 2000
        ) as relay_log;

        return json_build_object(
            'status', 200,
            'success', true,
            'data', result
        );
    end if;

    -- Sensor log: type_id = 1
    if _type_id_num = 1 then
        with rows as (
            select
                s.payload::jsonb as payload,
                s.created_at
            from dn_iot_sensor s
            where s.device_id = _device_id
              and s.sensor_type_id = 1
              and s.created_at >= _date_start
              and s.created_at < _date_end
            order by s.created_at asc
            limit 20000
        ),
        expanded as (
            select
                e.key,
                e.value,
                r.created_at,
                case
                    when jsonb_typeof(e.value) = 'number'
                        then (e.value #>> '{}')::numeric
                    when jsonb_typeof(e.value) = 'string'
                         and (e.value #>> '{}') ~ '^-?\d+(\.\d+)?$'
                        then (e.value #>> '{}')::numeric
                    else null
                end as num_value
            from rows r
            cross join lateral (
                select
                    kv.key,
                    kv.value
                from jsonb_each(r.payload) kv
                where jsonb_typeof(r.payload) = 'object'

                union all

                select
                    'value'::text as key,
                    r.payload as value
                where jsonb_typeof(r.payload) is distinct from 'object'
            ) e
        ),
        keyed as (
            select
                key,
                value,
                created_at,
                num_value,
                first_value(created_at) over (
                    partition by key
                    order by num_value asc nulls last, created_at asc
                ) as min_at,
                first_value(created_at) over (
                    partition by key
                    order by num_value desc nulls last, created_at asc
                ) as max_at
            from expanded
        ),
        stats as (
            select
                key,
                min(num_value) as min,
                max(num_value) as max,
                max(min_at) filter (where num_value is not null) as min_at,
                max(max_at) filter (where num_value is not null) as max_at,
                count(*) filter (where num_value is not null)::int as valid_count,
                count(*) filter (where num_value is null)::int as invalid_count,
                json_agg(
                    jsonb_build_object(
                        key,
                        value,
                        'created_at',
                        created_at
                    )
                    order by created_at asc
                ) as logs
            from keyed
            group by key
        )
        select coalesce(
            json_object_agg(
                key,
                json_build_object(
                    'min', min,
                    'min_at', min_at,
                    'max', max,
                    'max_at', max_at,
                    'valid_count', valid_count,
                    'invalid_count', invalid_count,
                    'logs', logs
                )
            ),
            '{}'::json
        )
        into result
        from stats;

        return json_build_object(
            'status', 200,
            'success', true,
            'data', json_build_object(
                'device_id', _device_id,
                'date', trim(_date),
                'fields', result
            )
        );
    end if;

    return json_build_object(
        'status', 400,
        'error', 'Unsupported type_id: ' || _type_id_num
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', sqlerrm
        );
end;
$_$;


ALTER FUNCTION "public"."util_dn_iot_get_device_log"("_device_id" "text", "_date" "text", "_type_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_get_qc"("_device_id" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
  declare
    result json ;
  begin
    select json_agg(profile_group)
    into result
    from (
      select * 
      from dn_iot_devices
      where _device_id = id
    ) as profile_group;

    return result;
  end; 
$$;


ALTER FUNCTION "public"."util_dn_iot_get_qc"("_device_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_location"() RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    result jsonb;
begin
    select coalesce(json_agg(location_result), '[]'::json)
    into result
    from (
        select
            l.latitude,
            l.longitude,
            l.device_id,
            l.number_device,
            json_build_object(
                'status', d.status
            ) as dn_iot_devices
        from dn_iot_supply_list l
        left join dn_iot_devices d
            on d.id = l.device_id
    ) as location_result;

    if result = '[]'::jsonb then
        return json_build_object(
            'status', 404,
            'error', 'Device not found'
        );
    end if;

    return json_build_object(
        'status', 200,
        'data', result
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', sqlerrm
        );
end;
$$;


ALTER FUNCTION "public"."util_dn_iot_location"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_dn_iot_remove_device"("_device_id" "text", "_owner_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare
    _device_owner_id uuid;
begin
    -- Validate parameters
    if nullif(trim(_device_id), '') is null
       or _owner_id is null then
        return json_build_object(
            'status', 400,
            'error', 'Missing parameters'
        );
    end if;

    -- Check owner exists
    if not exists (
        select 1
        from profile p
        where p.id = _owner_id
    ) then
        return json_build_object(
            'status', 404,
            'error', 'Owner not found'
        );
    end if;

    -- Check device exists
    select d.owner_id
    into _device_owner_id
    from dn_iot_devices d
    where d.id = _device_id;

    if not found then
        return json_build_object(
            'status', 404,
            'error', 'Device not found'
        );
    end if;

    -- Ensure device is currently connected
    if _device_owner_id is null then
        return json_build_object(
            'status', 409,
            'error', 'Device not connected'
        );
    end if;

    -- Ensure this device belongs to the given owner
    if _device_owner_id <> _owner_id then
        return json_build_object(
            'status', 403,
            'error', 'Not this owner''s device'
        );
    end if;

    -- Clear owner
    update dn_iot_devices d
    set owner_id = null
    where d.id = _device_id;

    return json_build_object(
        'status', 200,
        'success', true
    );

exception
    when others then
        return json_build_object(
            'status', 500,
            'error', sqlerrm
        );
end;
$$;


ALTER FUNCTION "public"."util_dn_iot_remove_device"("_device_id" "text", "_owner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_duplicate_farm_group_with_type"("_group_name" "text", "_group_id" bigint, "_is_type_id" boolean) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_group_id BIGINT;
    inserted_rows INT;
BEGIN
    -- Check if _group_id is NULL; if so, exit the function
    IF _group_id IS NULL THEN
        RAISE EXCEPTION 'Input group_id cannot be NULL';
    END IF;

    -- Check if any farms exist with the specified _group_id
    SELECT COUNT(*) INTO inserted_rows 
    FROM farm 
    WHERE "group" = _group_id;
    
    IF inserted_rows = 0 THEN
        RAISE EXCEPTION 'No farms found with the specified group_id: %; farm group creation aborted.', _group_id;
    END IF;

    -- Create the new farm group only if farms exist
    INSERT INTO farm_group (name, user_id)
    VALUES (_group_name, auth.uid())
    RETURNING id INTO new_group_id;

    -- Conditional logic based on _is_type_id
    IF _is_type_id THEN
        -- Insert copies of farms with the same _group_id
        INSERT INTO farm (type_id, address, name, area_size, user_id, "group", sub_district_id, snapshot_url, title_deed_no, geometry)
        SELECT type_id, address, name, area_size, user_id, new_group_id, sub_district_id, snapshot_url, title_deed_no, geometry
        FROM farm
        WHERE "group" = _group_id;
    ELSE
        -- Insert copies of farms with NULL type_id
        INSERT INTO farm (type_id, address, name, area_size, user_id, "group", sub_district_id, snapshot_url, title_deed_no, geometry)
        SELECT NULL, address, name, area_size, user_id, new_group_id, sub_district_id, snapshot_url, title_deed_no, geometry
        FROM farm
        WHERE "group" = _group_id;
    END IF;

    -- Return the new group ID as JSON
    RETURN json_build_object('new_group_id', new_group_id);
END;
$$;


ALTER FUNCTION "public"."util_duplicate_farm_group_with_type"("_group_name" "text", "_group_id" bigint, "_is_type_id" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_activity_by_group"("_group" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(activity_group)
  from (
    select 
      a.id as activity_id, 
      a.farm_id, 
      a.img_path as activity_img_path, 
      a.note as activity_note, 
      a.type_id as activity_type_id, 
      a.user_id, 
      a.status as activity_status,
      a.date as activity_date, 
      a.create_date as activity_create_date, 
      a.label_color, 
      a.update_date as activity_update_date,
      p.first_name,
      p.last_name,
      f.name as farm_name
      from activity a 
      left join profile p on p.id = a.user_id
      left join farm f on f.id = a.farm_id
      where p."group" = _group
  ) as activity_group
$$;


ALTER FUNCTION "public"."util_get_activity_by_group"("_group" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_activity_detail_superadmin"("_user_id" "uuid", "_start_date" timestamp without time zone DEFAULT NULL::timestamp without time zone, "_end_date" timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS "json"
    LANGUAGE "sql"
    AS $$
SELECT json_agg(report)
FROM (
    SELECT
        atvt.name as activity_type,
        count(atv.id) as total
    FROM
        activity atv
    LEFT JOIN
        activity_type atvt ON atv.type_id = atvt.id
    WHERE
        (atv.date::date >= COALESCE(_start_date, atv.date::date))
        AND (atv.date::date <= COALESCE(_end_date, atv.date::date))
        AND user_id = COALESCE(_user_id,user_id::uuid)
    GROUP by atvt.name

) AS report
$$;


ALTER FUNCTION "public"."util_get_activity_detail_superadmin"("_user_id" "uuid", "_start_date" timestamp without time zone, "_end_date" timestamp without time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_activity_farm"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(activity_group)
  from (
    select 
      a.id as activity_id, 
      a.farm_id, 
      a.img_path as activity_img_path, 
      a.note as activity_note, 
      a.type_id as activity_type_id, 
      a.user_id, 
      a.status as activity_status,
      a.date as activity_date, 
      a.create_date as activity_create_date, 
      a.label_color, 
      a.update_date as activity_update_date,
      a_t.id as activity_type_id, 
      a_t.name as activity_type_name, 
      a_t.create_date as activity_type_create_date, 
      a_t.priority 
    from activity a
    left join activity_type a_t on a_t.id = a.type_id
    where a.farm_id = _farm_id
    order by a.create_date asc
  ) as activity_group
$$;


ALTER FUNCTION "public"."util_get_activity_farm"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_activity_id"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(activity_group)
  from (
    select 
      id as activity_id
    from activity
    where activity.farm_id = _farm_id
  ) as activity_group
$$;


ALTER FUNCTION "public"."util_get_activity_id"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_activity_report_modal_superadmin"("_user_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
WITH activity_counts AS (
    SELECT 
        act.farm_id,
        f.name AS farm_name,
        ft.subtype as farm_type,
        actt.name AS activity_type,
        COUNT(distinct h.id) as total_harvest,
        COUNT(1) AS count
    FROM 
        activity act
    LEFT JOIN 
        activity_type actt ON actt.id = act.type_id
    LEFT JOIN 
        farm f ON f.id = act.farm_id
    LEFT JOIN 
        farm_type ft on ft.id = f.type_id
    LEFT JOIN 
        harvest h on h.farm_id = f.id
    where (_user_id IS NULL OR f.user_id = _user_id)
    GROUP BY 
        act.farm_id, f.name, actt.name, ft.subtype
),
farm_activities AS (
    SELECT 
        farm_id,
        farm_name,
        farm_type,
        total_harvest,
        json_agg(
            json_build_object(
                activity_type, count
            )
        ) AS activities
    FROM 
        activity_counts
    GROUP BY 
        farm_id, farm_name, farm_type, total_harvest
)
SELECT 
    json_build_object(
        'result', json_agg(
            json_build_object(
                'farm_id', farm_id,
                'farm_name', farm_name,
                'farm_type', farm_type,
                'total_harvest',total_harvest,
                'activities', activities
            )
        )
    ) AS result
FROM 
    farm_activities;
$$;


ALTER FUNCTION "public"."util_get_activity_report_modal_superadmin"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_activity_report_superadmin"("_start_date" timestamp without time zone DEFAULT NULL::timestamp without time zone, "_end_date" timestamp without time zone DEFAULT NULL::timestamp without time zone, "_user_id" "uuid" DEFAULT NULL::"uuid", "_group_id" "uuid" DEFAULT NULL::"uuid", "_offset" integer DEFAULT 0, "_limit" integer DEFAULT 1000) RETURNS "json"
    LANGUAGE "sql"
    AS $$
WITH aggregated_activity AS (
    SELECT
        f.id as farm_id,
        p.first_name || ' ' || p.last_name AS user_name,
        f.user_id as user_id,
        MAX(atv.update_date)::date AS activity_updated,
        ARRAY_AGG(DISTINCT atv.type_id)::BIGINT[] AS uniq_type_ids,
        COUNT(DISTINCT atv.id) AS total_activity,
        COUNT(DISTINCT h.id) > 0 AS is_harvested
    FROM
        activity atv
    LEFT JOIN
        profile p ON atv.user_id = p.id
    LEFT JOIN
        farm f ON f.id = atv.farm_id
    LEFT JOIN
        harvest h ON h.farm_id = f.id
    WHERE
        (f.create_date::date >= COALESCE(_start_date, f.create_date::date))
        AND (f.create_date::date <= COALESCE(_end_date, f.create_date::date))
        AND (_user_id IS NULL OR p.id = _user_id)
        AND (_group_id IS NULL OR p."group" = _group_id)
    GROUP BY f.id, p.first_name, p.last_name
)
SELECT json_agg(report)
FROM (
    SELECT
        user_id,
        user_name,
        SUM(total_activity) AS total_activity,
        MAX(activity_updated)::date AS activity_updated,
        SUM(CASE WHEN ARRAY[3]::BIGINT[] <@ uniq_type_ids AND
                    ARRAY[1, 7, 10]::BIGINT[] && uniq_type_ids AND
                    is_harvested THEN 1 ELSE 0 END) AS active_farm,
        SUM(CASE WHEN ARRAY[3]::BIGINT[] <@ uniq_type_ids AND
                    ARRAY[1, 7, 10]::BIGINT[] && uniq_type_ids AND
                    is_harvested THEN 0 ELSE 1 END) AS inactive_farm
    FROM
        aggregated_activity
    GROUP BY user_id, user_name
    ORDER BY user_id
    OFFSET _offset
    LIMIT _limit
) AS report;
$$;


ALTER FUNCTION "public"."util_get_activity_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid", "_offset" integer, "_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_activity_type_by_farm_type"("_farm_type_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _type_query TEXT;
BEGIN

    SELECT type INTO _type_query
    FROM farm_type
    WHERE id = _farm_type_id;

    -- Return the results as JSON
    RETURN (
        SELECT jsonb_agg(activity)
        FROM (
            SELECT id AS activity_type_id,name AS activity_type_name
            FROM activity_type
            WHERE (availability ->> _type_query::TEXT)::BOOLEAN = true
            ORDER BY priority ASC
        ) AS activity
    );
END;
$$;


ALTER FUNCTION "public"."util_get_activity_type_by_farm_type"("_farm_type_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_activity_type_ordered_priority"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(activity_group)
  from (
    select 
      *
    from activity_type
    order by priority asc
  ) as activity_group$$;


ALTER FUNCTION "public"."util_get_activity_type_ordered_priority"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_address"("lon" double precision, "lat" double precision) RETURNS "json"
    LANGUAGE "sql"
    AS $$
SELECT json_build_object(
    'id', id,
    'tam_id', tam_id,
    'tambon_en', tambon_en,
    'tambon_th', tambon_th,
    'amphoe_en', amphoe_en,
    'amphoe_th', amphoe_th,
    'province_en', province_en,
    'province_th', province_th,
    'postcode', postcode
) 
FROM sub_district
WHERE ST_Intersects(ST_SetSRID(ST_MakePoint(lon::double precision, lat::double precision),4326),geom);
$$;


ALTER FUNCTION "public"."util_get_address"("lon" double precision, "lat" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_activity"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(activity_group)
  from (
    select 
      a.id as activity_id, 
      a.farm_id,
      f.name as farm_name,
      a.img_path as activity_img_path, 
      a.note as activity_note, 
      a.type_id as activity_type_id, 
      a.user_id, 
      a.status as activity_status,
      a.date as activity_date, 
      a.create_date as activity_create_date, 
      a.label_color, 
      a.update_date as activity_update_date,
      a_t.id as activity_type_id, 
      a_t.name as activity_type_name, 
      a_t.create_date as activity_type_create_date, 
      a_t.priority 
    from activity a
    left join activity_type a_t on a_t.id = a.type_id
    left join farm f on f.id = a.farm_id
    order by a.create_date asc
  ) as activity_group$$;


ALTER FUNCTION "public"."util_get_all_activity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_activity_type"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(activity_type)
  from (
    select id as activity_type_id, name as activity_type_name, create_date as activity_type_create_date, priority from activity_type 
  ) as activity_type
$$;


ALTER FUNCTION "public"."util_get_all_activity_type"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_client"() RETURNS "json"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_agg(
        json_build_object(
            'id', c.id,
            'name', c.name,
            'delivery_round', c.delivery_round,
            'status', c.status,
            'order_list', COALESCE(
                (SELECT json_agg(
                    json_build_object(
                        'id', co.id,
                        'delivery_date', co.delivery_date,
                        'order_date', co.order_date,
                        'products', COALESCE(
                            (SELECT json_agg(
                                json_build_object(
                                    'farm_type', ft.subtype,
                                    'quantity', coi.amount
                                )
                            )
                            FROM client_order_item coi
                            LEFT JOIN farm_type ft ON coi.farm_type_id = ft.id
                            WHERE coi.order_id = co.id),
                            '[]'::json
                        )
                    )
                )
                FROM client_order co
                WHERE co.client_id = c.id),
                '[]'::json
            )
        )
    ) INTO result
    FROM client c;

    RETURN result;
END;
$$;


ALTER FUNCTION "public"."util_get_all_client"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_comment"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(comment_group)
  from (
    select 
    id as comment_id, 
    user_id,
    detail as comment_detail,
    rating as comment_rating,
    product_id as comment_product_id
    from comment
  ) as comment_group;$$;


ALTER FUNCTION "public"."util_get_all_comment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_cost"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(cost)
  from (
    select 
      id as cost_id, 
      user_id, 
      create_date as cost_create_date,
      update_date as cost_update_date,
      detail as cost_detail, 
      price as cost_price, 
      category, 
      date as cost_date 
    from cost 
  ) as cost 
$$;


ALTER FUNCTION "public"."util_get_all_cost"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_cost_group_with_sub_total"() RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  result JSON;
BEGIN
  SELECT json_agg(cost_group)
  INTO result
  FROM (
    SELECT 
      c_g.id AS cost_group_id,
      c_g.name AS cost_group_name,
      c_g.create_date AS cost_group_create_date,
      c_g.update_date AS cost_group_update_date,
      c_g.user_id,
      COALESCE(SUM(c.price), 0) AS sub_total
    FROM cost_group c_g
    LEFT JOIN cost c ON c."group" = c_g.id
    GROUP BY c_g.id
  ) AS cost_group;

  RETURN result;
END;
$$;


ALTER FUNCTION "public"."util_get_all_cost_group_with_sub_total"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_farm"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(farm)
  from (
    select id as farm_id, name as farm_name, status as farm_status, address as farm_address, create_date as farm_create_date, ha_bridge_id, snapshot_url as farm_snapshot, title_deed_no, sub_district_id as farm_sub_district_id, user_id, geometry, type_id as farm_type_id, area_size, "group" as farm_group_id, update_date as farm_update_date from farm 
  ) as farm
$$;


ALTER FUNCTION "public"."util_get_all_farm"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_farm_disabled"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
SELECT json_agg(farm_data)
  from (
    SELECT 
        f.id AS farm_id, 
        f.name AS farm_name, 
        f.status AS farm_status, 
        f.address AS farm_address, 
        f.create_date AS farm_create_date, 
        f.ha_bridge_id, 
        f.snapshot_url AS farm_snapshot, 
        f.title_deed_no, 
        f.sub_district_id AS farm_sub_district_id,
        f.user_id, 
        f.geometry, 
        f.type_id AS farm_type_id, 
        f.area_size,
        f."group" AS farm_group_id, 
        f.update_date AS farm_update_date,
        NULL as farm_amount
    FROM farm f
    WHERE f.status = false
      ) as farm_data

$$;


ALTER FUNCTION "public"."util_get_all_farm_disabled"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_farm_group"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  SELECT JSON_AGG(farm_group_data)
  FROM (
    SELECT 
      fg.id,
      fg.name,
      COALESCE(SUM(f.area_size), 0) AS total_area_size,
      COUNT(f.id) AS total_farm
    FROM 
      farm_group fg
    LEFT JOIN 
      farm f ON f."group" = fg.id
    GROUP BY 
      fg.id, fg.name
    having COUNT(f.id) > 0
  ) AS farm_group_data;
$$;


ALTER FUNCTION "public"."util_get_all_farm_group"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_farm_type"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(farm_type)
  from (
    select 
      id as farm_type_id, 
      category as farm_type_category, 
      type as farm_type_type, 
      subtype as farm_type_subtype, 
      metadata as farm_type_metadata,
      duration as farm_type_duration,
      "group" as farm_type_group
    from farm_type
    order by subtype asc
  ) as farm_type$$;


ALTER FUNCTION "public"."util_get_all_farm_type"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_group"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg("group")
  from (
    select 
    g.id as group_id, 
    g.name as group_name, 
    g.admin_id, 
    g.phone as group_phone, 
    g.email as group_email, 
    g.contact as group_contact, 
    g.address as group_address, 
    g.biography, 
    g.about as group_about, 
    g.group_img_path, 
    g.banner_img_path,
    coalesce(count(p."group"), 0) as group_user_count
    from "group" g
    left join profile p on p."group" = g.id
    group by g.id
  ) as "group"
$$;


ALTER FUNCTION "public"."util_get_all_group"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_harvest"() RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN (
    SELECT json_agg(farm_group)
    FROM (
      SELECT 
        h.farm_id,
        f.name AS farm_name,
        f.status AS farm_status,
        ft.subtype AS farm_subtype,
        json_agg(
          json_build_object(
            'harvest_date', h.date,
            'harvest_amount', h.amount
          )
        ) AS harvests
      FROM harvest h
      JOIN farm f ON f.id = h.farm_id -- Join to get farm name and type
      JOIN farm_type ft ON ft.id = f.type_id -- Join to get subtype from farm_type
      WHERE h.user_id = auth.uid()
      GROUP BY h.farm_id,f.name, ft.subtype,f.status
    ) AS farm_group
  );
END;
$$;


ALTER FUNCTION "public"."util_get_all_harvest"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_harvest_from_farm"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  RETURN (
    SELECT json_agg(farm_group)
    FROM (
      SELECT 
        h.farm_id,
        f.name AS farm_name,
        f.status AS farm_status,
        ft.subtype AS farm_subtype,
        json_agg(
          json_build_object(
            'harvest_date', h.date,
            'harvest_amount', h.amount
          )
        ) AS harvests
      FROM public.harvest h
      JOIN public.farm f ON f.id = h.farm_id -- Join to get farm name and type
      JOIN public.farm_type ft ON ft.id = f.type_id -- Join to get subtype from farm_type
      WHERE f.id = _farm_id
      GROUP BY h.farm_id,f.name, ft.subtype,f.status
    ) AS farm_group
  );
END;$$;


ALTER FUNCTION "public"."util_get_all_harvest_from_farm"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_harvest_from_group"("_farm_group_id" bigint) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN (
    SELECT json_agg(farm_group)
    FROM (
      SELECT 
        h.farm_id,
        f.name AS farm_name,
        f.status AS farm_status,
        ft.subtype AS farm_subtype,
        json_agg(
          json_build_object(
            'harvest_date', h.date,
            'harvest_amount', h.amount
          )
        ) AS harvests
      FROM harvest h
      JOIN farm f ON f.id = h.farm_id -- Join to get farm name and type
      JOIN farm_type ft ON ft.id = f.type_id -- Join to get subtype from farm_type
      WHERE f.group = _farm_group_id
      GROUP BY h.farm_id,f.name, ft.subtype,f.status
    ) AS farm_group
  );
END;
$$;


-- Removed: ALTER FUNCTION "public"."util_get_all_harvest_from_group"("_farm_group_id" bigint) OWNER TO "authenticated";


CREATE OR REPLACE FUNCTION "public"."util_get_all_news"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(news_group)
  from (
    select 
      author,
      id as news_id, 
      news_type,
      published_date,
      title as news_title,
      url as news_url,
      url_image as news_url_image
      from news
  ) as news_group$$;


ALTER FUNCTION "public"."util_get_all_news"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_product"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(product_group)
  from (
    select 
    id as product_id, 
    shop_id, 
    farm_id, 
    img_path as product_img_path, 
    name as product_name, 
    detail as product_detail, 
    status as product_status
    from product
  ) as product_group;
$$;


ALTER FUNCTION "public"."util_get_all_product"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_product_option"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(product_option_group)
  from (
    select 
    id as product_option_id, 
    product_id, 
    name as product_option_name, 
    detail as product_option_detail,
    img_path as product_option_img_path, 
    unit as product_option_unit, 
    stock as product_option_stock,
    total_sale as product_option_total_sale,
    status as product_option_status
    from product_option
  ) as product_option_group;
$$;


ALTER FUNCTION "public"."util_get_all_product_option"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_profile"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(profile)
  from (
    select id as user_id, first_name, last_name, address as user_address, img_path as user_img_path, status as user_status, sub_district_id as user_sub_district_id, "group" as user_group, phone as user_phone, email as user_email, username, id_card, create_date as user_create_date, update_date as user_update_date, prefix as user_prefix,farm_type_category as user_farm_type_category,farmer_id as user_farmer_id,farmer_id_register_date as user_farmer_id_register_date,date_of_birth as user_date_of_birth,house_id as user_house_id,default_lat as user_default_lat, default_lon as user_default_lon from profile
  ) as profile$$;


ALTER FUNCTION "public"."util_get_all_profile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_profile_superadmin"() RETURNS "json"
    LANGUAGE "sql"
    AS $$

SELECT json_agg(profile)

from (
    select * from profile
  ) as profile

;$$;


ALTER FUNCTION "public"."util_get_all_profile_superadmin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_quota"("_meeting_date" "date" DEFAULT NULL::"date", "_user_id" "uuid" DEFAULT NULL::"uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  RETURN (
    SELECT json_agg(quota_data)
    FROM (
      SELECT 
        q.id AS id,
        trim(concat(pf.first_name, ' ', pf.last_name)) AS name,
        q.meeting_date AS meeting_date,
        q.delivery_round AS delivery_round,
        q.user_id AS user_id,
        json_agg(
          json_build_object(
            'farm_type_name', ft.subtype,
            'farm_type_id', ft.id,
            'quantity', qi.amount,
            'start_date', qi.start_date,
            'area_size', qi.area_size,
            'harvest_amount', (
              SELECT SUM(hv.amount)
              FROM harvest hv
              WHERE hv.farm_id = qi.farm_id
              AND hv.date >= qi.start_date
            ),
            'next_harvest_date', NULL,
            'farm_id', qi.farm_id
          )
        ) AS quota_detail
      FROM quota q
      LEFT JOIN profile pf ON pf.id = q.user_id
      LEFT JOIN quota_item qi ON qi.quota_id = q.id
      LEFT JOIN farm_type ft ON ft.id = qi.farm_type_id
      WHERE (_meeting_date is NULL OR q.meeting_date = _meeting_date)
        AND (_user_id IS NULL OR q.user_id = _user_id)
      GROUP BY q.id, pf.first_name, pf.last_name, q.meeting_date, q.delivery_round, q.user_id
      HAVING SUM(qi.amount) > 0
      ORDER BY q.id
    ) AS quota_data
  );
END;$$;


ALTER FUNCTION "public"."util_get_all_quota"("_meeting_date" "date", "_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_quota_farm_null"("_meeting_date" "date" DEFAULT NULL::"date", "_user_id" "uuid" DEFAULT NULL::"uuid", "_null_flag" boolean DEFAULT false) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  RETURN (
    SELECT json_agg(quota_data)
    FROM (
      SELECT 
        q.id AS id,
        trim(concat(pf.first_name, ' ', pf.last_name)) AS name,
        q.meeting_date AS meeting_date,
        q.delivery_round AS delivery_round,
        q.user_id AS user_id,
        json_agg(
          json_build_object(
            'farm_type_name', ft.subtype,
            'farm_type_id', ft.id,
            'quantity', qi.amount,
            'start_date', qi.start_date,
            'area_size', qi.area_size,
            'harvest_amount', (
              SELECT SUM(hv.amount)
              FROM harvest hv
              WHERE hv.farm_id = qi.farm_id
              AND hv.date >= qi.start_date
            ),
            'next_harvest_date', NULL,
            'farm_id', qi.farm_id
          )
        ) AS quota_detail
      FROM quota q
      LEFT JOIN profile pf ON pf.id = q.user_id
      LEFT JOIN quota_item qi ON qi.quota_id = q.id
      LEFT JOIN farm_type ft ON ft.id = qi.farm_type_id
      -- Filtering quota items based on _null_flag
      WHERE (_meeting_date IS NULL OR q.meeting_date = _meeting_date)
        AND (_user_id IS NULL OR q.user_id = _user_id)
        AND EXISTS (
          SELECT 1
          FROM quota_item qi_sub
          WHERE qi_sub.quota_id = q.id
            AND ((_null_flag AND qi_sub.farm_id IS NULL) OR (NOT _null_flag AND qi_sub.farm_id IS NOT NULL))
        )
      GROUP BY q.id, pf.first_name, pf.last_name, q.meeting_date, q.delivery_round, q.user_id
      HAVING SUM(qi.amount) > 0
      ORDER BY q.id
    ) AS quota_data
  );
END;$$;


ALTER FUNCTION "public"."util_get_all_quota_farm_null"("_meeting_date" "date", "_user_id" "uuid", "_null_flag" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_shop"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(shop_group)
  from (
    select 
      id as shop_id,
      user_id,
      name as shop_name,
      detail as shop_detail,
      address as shop_address,
      phone as shop_phone,
      line_id as shop_line_id,
      account_name as shop_account_name,
      payment_img_path as shop_payment_img_path,
      img_path as shop_img_path
    from shop
  ) as shop_group;
$$;


ALTER FUNCTION "public"."util_get_all_shop"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_standard"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(standard)
  from (
    select 
    id as standard_id, 
    user_id, detail as standard_detail, 
    type_id as standard_type_id, 
    file_path as standard_file_path, 
    create_date as standard_create_date, 
    update_date as standard_update_date 
    from standard
  ) as standard;
$$;


ALTER FUNCTION "public"."util_get_all_standard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_standard_type"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(standard_type)
  from (
    select id as standard_type_id, name as standard_type_name, metadata as standard_metadata from standard_type
  ) as standard_type;
$$;


ALTER FUNCTION "public"."util_get_all_standard_type"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_sub_district"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(sub_district)
  from (
    select id as sub_district_id, tam_id, tambon_en, tambon_th, amp_id, amphoe_en, amphoe_th, pro_id, province_en, province_th, postcode, geom as geom_sub_district from sub_district
  ) as sub_district;
$$;


ALTER FUNCTION "public"."util_get_all_sub_district"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_all_transaction"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(transaction_group)
  from (
    select 
    id as transaction_id, 
    product_id, 
    customer_id,
    quantity as transaction_quantity,
    price_per_unit as transaction_price_per_unit, 
    total_cost as transaction_total_cost,
    discount as transaction_discount, 
    shipping_address,
    payment_method,
    status as transaction_status,
    img_path as transaction_img_path
    from transaction
  ) as transaction_group;
$$;


ALTER FUNCTION "public"."util_get_all_transaction"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_comment_review_product"("_product_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(comment_group)
  from (
    select 
      p.username,
      pro.name as product_name,
      p.img_path as profile_img_path,
      c.detail as comment_detail,
      c.rating as comment_rating,
      date(c.create_date) as comment_create_date
    from comment c
    left join profile p on p.id = c.user_id
    left join product pro on pro.id = c.product_id
    where product_id = _product_id
  ) as comment_group
$$;


ALTER FUNCTION "public"."util_get_comment_review_product"("_product_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_cost_by_group"("_cost_group_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(cost_group)
  from (
    select 
      id as cost_id,
      user_id,
      create_date as cost_create_date,
      update_date as cost_update_date,
      detail as cost_detail,
      price as cost_price,
      category as cost_category,
      date as cost_date,
      "group" as cost_group_id 
    from cost 
    where "group" = _cost_group_id
  ) as cost_group
$$;


ALTER FUNCTION "public"."util_get_cost_by_group"("_cost_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_dashboard"("_group_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(dashboard)
  from (
    select
    f_t.subtype as farm_type_subtype,
    f.id as farm_id,
    f.name as farm_name, 
    p.first_name, 
    p.last_name, 
    h.amount as harvest_amount, 
    f.status as farm_status, 
    DATE(h.create_date) as harvest_date, 
    EXTRACT(MONTH FROM h.create_date) as harvest_month, 
    extract(year from h.create_date) as harvest_year, 
    h.create_date as harvest_create_date
    from harvest h 
    left join farm f on h.farm_id = f.id 
    left join farm_type f_t on f_t.id = f.type_id
    left join profile p on p.id = f.user_id
    left join "group" g on g.id = p."group"
    where p."group" = _group_id
  ) as dashboard
$$;


ALTER FUNCTION "public"."util_get_dashboard"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_district"("province_id" integer) RETURNS TABLE("amp_id" integer, "amphoe_en" "text", "amphoe_th" "text")
    LANGUAGE "sql"
    AS $$
   select amp_id,amphoe_en,amphoe_th from sub_district where pro_id = province_id group by amp_id,amphoe_en,amphoe_th order by amp_id
$$;


ALTER FUNCTION "public"."util_get_district"("province_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_activity"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(farm_group)
  from (
SELECT 
    f.id AS farm_id, 
    f.name AS farm_name, 
    f.status AS farm_status, 
    f.address AS farm_address, 
    f.create_date AS farm_create_date, 
    f.ha_bridge_id, 
    f.snapshot_url AS farm_snapshot, 
    f.title_deed_no, 
    f.sub_district_id AS farm_sub_district_id, 
    f.user_id, 
    f.geometry, 
    f.type_id AS farm_type_id, 
    f.area_size,
    f."group" AS farm_group_id, 
    f.update_date AS farm_update_date,
    a.id AS activity_id, 
    a.farm_id, 
    a.img_path AS activity_img_path, 
    a.note AS activity_note, 
    a.type_id AS activity_type_id, 
    a.user_id, 
    a.status AS activity_status,
    a.date AS activity_date, 
    a.create_date AS activity_create_date, 
    a.label_color, 
    a.update_date AS activity_update_date, 
    a_t.id AS activity_type_id, 
    a_t.name AS activity_type_name, 
    a_t.create_date AS activity_type_create_date, 
    a_t.priority 
FROM farm f
LEFT JOIN (
    SELECT 
        a1.*
    FROM activity a1
    INNER JOIN (
        SELECT 
            farm_id, 
            MAX(date) AS latest_activity_date
        FROM activity
        GROUP BY farm_id
    ) a2 ON a1.farm_id = a2.farm_id AND a1.date = a2.latest_activity_date
) a ON f.id = a.farm_id
LEFT JOIN activity_type a_t ON a_t.id = a.type_id
where f.status = true and f.user_id = auth.uid()
ORDER BY f.create_date ASC
  ) as farm_group$$;


ALTER FUNCTION "public"."util_get_farm_activity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_age"("ids" integer[]) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_agg(json_build_object('id', id, 'harvest_age', split_part(metadata->'description'->>'harvest_age', ' ', 1)))
    INTO result
    FROM farm_type
    WHERE id = ANY(ids);

    RETURN result;
END;
$$;


ALTER FUNCTION "public"."util_get_farm_age"("ids" integer[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_by_f_group"("_group_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$SELECT json_agg(farm_group)
FROM (
    SELECT 
        f.id AS farm_id, 
        f.name AS farm_name, 
        f.status AS farm_status, 
        f.address AS farm_address, 
        f.create_date AS farm_create_date, 
        f.ha_bridge_id, 
        f.snapshot_url AS farm_snapshot, 
        f.title_deed_no, 
        f.sub_district_id AS farm_sub_district_id,
        f.user_id, 
        f.geometry, 
        f.type_id AS farm_type_id, 
        f.area_size,
        f."group" AS farm_group_id, 
        f.update_date AS farm_update_date,
        NULL as farm_amount,
        f_t.subtype as farm_type_subtype
    FROM farm f
    LEFT JOIN farm_type f_t ON f.type_id = f_t.id
    WHERE f."group" = _group_id
    ORDER BY 
        substring(f.name, '^[^0-9]+') ASC,
        CASE 
            WHEN substring(f.name, '[0-9]+') <> '' THEN CAST(substring(f.name, '[0-9]+') AS INTEGER)
            ELSE NULL
        END ASC
) AS farm_group;$$;


ALTER FUNCTION "public"."util_get_farm_by_f_group"("_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_by_f_group_disabled"("_group_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$

  select json_agg(farm_group)
  from (
    select 
      id as farm_id, 
      name as farm_name, 
      status as farm_status, 
      address as farm_address, 
      create_date as farm_create_date, 
      ha_bridge_id, 
      snapshot_url as farm_snapshot, 
      title_deed_no, 
      sub_district_id as farm_sub_district_id,
      user_id, 
      geometry, 
      type_id as farm_type_id, 
      area_size,
      "group" as farm_group_id, 
      update_date as farm_update_date 
      from farm
      where "group" = _group_id and farm.status = false
  ) as farm_group
$$;


ALTER FUNCTION "public"."util_get_farm_by_f_group_disabled"("_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_by_f_group_enabled"("_group_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(farm_group)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id,
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id, 
      f.update_date as farm_update_date,
      f_t.subtype as farm_type_subtype
      from farm f 
      left join farm_type f_t on f.type_id = f_t.id 
      where f."group" = _group_id and f.status = true
  ) as farm_group$$;


ALTER FUNCTION "public"."util_get_farm_by_f_group_enabled"("_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_by_id"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(farm_group)
  from (
    select 
      id as farm_id, 
      name as farm_name, 
      status as farm_status, 
      address as farm_address, 
      create_date as farm_create_date, 
      ha_bridge_id, 
      snapshot_url as farm_snapshot, 
      title_deed_no, 
      sub_district_id as farm_sub_district_id,
      user_id, 
      geometry, 
      type_id as farm_type_id, 
      area_size,
      "group" as farm_group_id, 
      update_date as farm_update_date 
      from farm
      where id = _farm_id
  ) as farm_group$$;


ALTER FUNCTION "public"."util_get_farm_by_id"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_from_group"("_group_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(field_from_group)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id, 
      f.update_date as farm_update_date
      from farm f
      left join profile p on p.id = f.user_id
      where p."group" = _group_id
  ) as field_from_group
$$;


ALTER FUNCTION "public"."util_get_farm_from_group"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_from_id_with_ha"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(field_from_id)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id, 
      f.update_date as farm_update_date,
      h_b.id as ha_bridge_id,
      h_b.name as ha_bridge_name,
      h_b.owner_id as ha_bridge_user_id,
      h_b.shared_to,
      h_b.metadata as ha_bridge_metadata,
      json_agg(h_en) AS ha_entities
      from farm f 
      left join ha_bridges h_b on h_b.id = f.ha_bridge_id
      left join (
        select 
        h_a.id AS bridge_id,
        h_e.entity_id,
        h_e.state_ref,
        h_e.current_state,
        h_e.state_attr
        FROM
          ha_bridges h_a
        LEFT JOIN
          ha_entities h_e ON h_a.id = h_e.bridge_id
        ) as h_en ON h_en.bridge_id = f.ha_bridge_id
    where f.id = _farm_id
    GROUP BY 
    f.id, 
    h_b.id
  ) as field_from_id$$;


ALTER FUNCTION "public"."util_get_farm_from_id_with_ha"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_from_name"("_farm_name" "text") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(plot_name)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id,
      f.update_date as farm_update_date
      from farm f 
      where f.name = _farm_name
  ) as plot_name
$$;


ALTER FUNCTION "public"."util_get_farm_from_name"("_farm_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_from_user"("_user_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(plot_user_id)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id,
      f.update_date as farm_update_date
      from farm f 
      where f.user_id = _user_id
  ) as plot_user_id
$$;


ALTER FUNCTION "public"."util_get_farm_from_user"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_group_null"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(farm_group)
  from (
    select 
      farm.id as farm_id, 
      name as farm_name, 
      status as farm_status, 
      address as farm_address,
      snapshot_url as farm_snapshot, 
      user_id, 
      type_id as farm_type_id, 
      area_size,
      ft.subtype as farm_type_subtype,
      farm."group" as farm_group_id
    from farm 
    left join farm_type ft
    on farm.type_id = ft.id
    where farm."group" is null and status = true
  ) as farm_group$$;


ALTER FUNCTION "public"."util_get_farm_group_null"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_list"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(field_list)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id, 
      f.update_date as farm_update_date,
      h_b.id as ha_bridge_id,
      h_b.name as ha_bridge_name,
      h_b.owner_id as ha_bridge_user_id,
      h_b.shared_to,
      h_b.metadata as ha_bridge_metadata,
      h_e.entity_id,
      h_e.state_ref,
      h_e.current_state,
      h_e.state_attr
      from farm f 
      left join ha_bridges h_b on h_b.id = f.ha_bridge_id
      left join ha_entities h_e on h_e.bridge_id = h_b.id
  ) as field_list
$$;


ALTER FUNCTION "public"."util_get_farm_list"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_ordered_group"() RETURNS "json"
    LANGUAGE "sql"
    AS $$SELECT json_agg(farm_group order by farm_create_date DESC)
FROM (
    SELECT 
        f.id AS farm_id, 
        f.name AS farm_name, 
        f.status AS farm_status, 
        f.address AS farm_address, 
        f.create_date AS farm_create_date, 
        f.ha_bridge_id, 
        f.snapshot_url AS farm_snapshot, 
        f.title_deed_no, 
        f.sub_district_id AS farm_sub_district_id,
        f.user_id, 
        f.geometry, 
        f.type_id AS farm_type_id, 
        f.area_size,
        f."group" AS farm_group_id, 
        f.update_date AS farm_update_date,
        NULL as farm_amount,
        f_t.subtype as farm_type_subtype
    FROM farm f
    left join farm_type f_t on f.type_id = f_t.id
    WHERE f."group" IS NULL AND f.status IS TRUE
    UNION 
    SELECT 
        NULL AS farm_id,
        f_g.name AS farm_name,
        NULL AS farm_status,
        NULL AS farm_address,
        max(f.create_date) AS farm_create_date,
        NULL AS ha_bridge_id,
        NULL AS farm_snapshot,
        NULL AS title_deed_no,
        NULL AS farm_sub_district_id,
        NULL AS user_id,
        NULL AS geometry,
        NULL AS farm_type_id,
        SUM(f.area_size) AS area_size,
        f_g.id AS farm_group_id, 
        NULL AS update_date,
        COUNT(f.name) as farm_amount,
        Null as farm_type_subtype
    FROM farm_group f_g
    LEFT JOIN farm f ON f."group" = f_g.id
    where f_g.id = f."group"
    group by f_g.id, f_g.name
) AS farm_group;$$;


ALTER FUNCTION "public"."util_get_farm_ordered_group"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_ordered_group_enabled"() RETURNS "json"
    LANGUAGE "sql"
    AS $$SELECT json_agg(farm_group)
FROM (
    SELECT 
        f.id AS farm_id, 
        f.name AS farm_name, 
        f.status AS farm_status, 
        f.address AS farm_address, 
        f.create_date AS farm_create_date, 
        f.ha_bridge_id, 
        f.snapshot_url AS farm_snapshot, 
        f.title_deed_no, 
        f.sub_district_id AS farm_sub_district_id,
        f.user_id, 
        f.geometry, 
        f.type_id AS farm_type_id, 
        f.area_size,
        f."group" AS farm_group_id, 
        f.update_date AS farm_update_date,
        NULL as farm_amount,
        f_t.subtype as farm_type_subtype
    FROM farm f
    left join farm_type f_t on f.type_id = f_t.id
    WHERE f."group" IS NULL and f.status = true
    UNION 
    SELECT 
        NULL AS farm_id,
        f_g.name AS farm_name,
        NULL AS farm_status,
        NULL AS farm_address,
        NULL AS farm_create_date,
        NULL AS ha_bridge_id,
        NULL AS farm_snapshot,
        NULL AS title_deed_no,
        NULL AS farm_sub_district_id,
        NULL AS user_id,
        NULL AS geometry,
        NULL AS farm_type_id,
        SUM(f.area_size) AS area_size,
        f_g.id AS farm_group_id, 
        NULL AS update_date,
        COUNT(f.name) as farm_amount,
        Null as farm_type_subtype
    FROM farm_group f_g
    LEFT JOIN farm f ON f."group" = f_g.id
    where f_g.id = f."group" and f.status = true
    GROUP BY f_g.id, f_g.name
) AS farm_group;$$;


ALTER FUNCTION "public"."util_get_farm_ordered_group_enabled"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_ordered_name"() RETURNS "json"
    LANGUAGE "sql"
    AS $$SELECT json_agg(farm_group)
  FROM (
    SELECT 
      f.id AS farm_id, 
      f.name AS farm_name, 
      f.status AS farm_status, 
      f.address AS farm_address, 
      f.create_date AS farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url AS farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id AS farm_sub_district_id,
      f.user_id, 
      f.geometry, 
      f.type_id AS farm_type_id, 
      f.area_size,
      f.traceable, 
      f."group" AS farm_group_id, 
      f.update_date AS farm_update_date,
      f_t.subtype AS farm_type_subtype,
      lh.latest_harvest_date
    FROM farm f
    LEFT JOIN farm_type f_t ON f.type_id = f_t.id
    LEFT JOIN (
      SELECT farm_id, MAX(date) AS latest_harvest_date
      FROM harvest
      GROUP BY farm_id
    ) lh ON f.id = lh.farm_id
    ORDER BY f.name ASC
  ) AS farm_group;$$;


ALTER FUNCTION "public"."util_get_farm_ordered_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_ordered_name_disabled"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  SELECT json_agg(farm_group)
  FROM (
    SELECT 
      f.id AS farm_id, 
      f.name AS farm_name, 
      f.status AS farm_status, 
      f.address AS farm_address, 
      f.create_date AS farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url AS farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id AS farm_sub_district_id,
      f.user_id, 
      f.geometry, 
      f.type_id AS farm_type_id, 
      f.area_size,
      f."group" AS farm_group_id, 
      f.update_date AS farm_update_date,
      f_t.subtype AS farm_type_subtype,
      lh.latest_harvest_date
    FROM farm f
    LEFT JOIN farm_type f_t ON f.type_id = f_t.id
    LEFT JOIN (
      SELECT farm_id, MAX(date) AS latest_harvest_date
      FROM harvest
      GROUP BY farm_id
    ) lh ON f.id = lh.farm_id
    WHERE f.status = false
    ORDER BY f.name ASC
  ) AS farm_group;
$$;


ALTER FUNCTION "public"."util_get_farm_ordered_name_disabled"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_owner"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(plot_field)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id,
      f.update_date as farm_update_date,
      p.first_name,
      p.last_name
      from farm f 
      left join profile p on p.id = f.user_id
      where f.id = _farm_id
  ) as plot_field
$$;


ALTER FUNCTION "public"."util_get_farm_owner"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_owner_from_group"("_group_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(plot_group)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id,
      f.update_date as farm_update_date,
      p.first_name,
      p.last_name
      from farm f 
      left join profile p on p.id = f.user_id
      where p."group" = _group_id
  ) as plot_group
$$;


ALTER FUNCTION "public"."util_get_farm_owner_from_group"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_report_superadmin"("_start_date" timestamp without time zone DEFAULT NULL::timestamp without time zone, "_end_date" timestamp without time zone DEFAULT NULL::timestamp without time zone, "_user_id" "uuid" DEFAULT NULL::"uuid", "_group_id" "uuid" DEFAULT NULL::"uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
SELECT json_agg(report)
FROM (
    SELECT
        p.first_name || ' ' || p.last_name AS name,
        p.default_lat || ',' || p.default_lon as latlon,
        COUNT(distinct f."group") as group_count,
        COUNT(f.id) FILTER (WHERE f."group" IS NULL) AS ungroup_count,
        COUNT(distinct f.id) as total_count,
        MIN(f.create_date)::date AS farm_created,
        MAX(f.update_date)::date AS farm_updated
    FROM
        farm f
    LEFT JOIN
        profile p ON f.user_id = p.id
    WHERE
        (f.create_date::date >= COALESCE(_start_date, f.create_date::date)) 
        AND (f.create_date::date <= COALESCE(_end_date, f.create_date::date))
        AND (_user_id IS NULL OR p.id = _user_id)
        AND (_group_id IS NULL OR p."group" = _group_id)
    GROUP BY
        p.first_name, p.last_name, p.default_lat, p.default_lon
) AS report
$$;


ALTER FUNCTION "public"."util_get_farm_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_status_desc"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(farm_group)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id,
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f.village_name as farm_village_name,
      f.moo as farm_moo,
      f.road as farm_road,
      f.soi as farm_soi,
      f."group" as farm_group_id, 
      f.update_date as farm_update_date,
      ft.subtype as farm_type_subtype
    from farm f
    left join farm_type ft on ft.id = f.type_id
    order by f.status desc
  ) as farm_group$$;


ALTER FUNCTION "public"."util_get_farm_status_desc"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_type_group"("_group_id" "uuid" DEFAULT NULL::"uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(farm_type_group)
  from (
    select 
      id as farm_type_id,
      category as farm_type_category,
      type as farm_type_type,
      subtype as farm_type_subtype,
      metadata as farm_type_metadata,
      "group" as farm_type_group
    from farm_type
    WHERE "group" = _group_id
     OR (_group_id IS NULL AND "group" IS NULL)
  ) as farm_type_group
$$;


ALTER FUNCTION "public"."util_get_farm_type_group"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_type_ordered"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(farm_group)
  from (
    select 
      id as farm_type_id, 
      category as farm_type_category, 
      type as farm_type_type, 
      subtype as farm_type_subtype, 
      metadata as farm_type_metadata,
      "group" as farm_type_group
      from farm_type
      order by subtype asc
  ) as farm_group
$$;


ALTER FUNCTION "public"."util_get_farm_type_ordered"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_type_plant"("_farm_type_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(farm_group)
  from (
    select 
      id as farm_type_id, 
      category as farm_type_category, 
      type as farm_type_type, 
      subtype as farm_type_subtype, 
      metadata as farm_type_metadata,
      "group" as farm_type_group
      from farm_type
      where farm_type.id = _farm_type_id
  ) as farm_group
$$;


ALTER FUNCTION "public"."util_get_farm_type_plant"("_farm_type_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_type_type"() RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(farm_group)
  from (
    select 
      distinct f_t.type as farm_type_type
    from farm_type f_t 

  ) as farm_group
$$;


ALTER FUNCTION "public"."util_get_farm_type_type"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_farm_with_plant"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(farm_group)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id,
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id, 
      f.update_date as farm_update_date,
      f_t.id as farm_type_id, 
      f_t.category as farm_type_category, 
      f_t.type as farm_type_type, 
      f_t.subtype as farm_type_subtype, 
      f_t.metadata as farm_type_metadata,
      f_t."group" as farm_type_group
      from farm f
      left join farm_type f_t on f_t.id = f.type_id
      where f.id = _farm_id
  ) as farm_group
$$;


ALTER FUNCTION "public"."util_get_farm_with_plant"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_group_detail"("_group_id" "uuid" DEFAULT NULL::"uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(group_detail)
  from (
    select 
    "group".id as group_id, 
    "group".name as group_name, 
    "group".admin_id, 
    "group".phone as group_phone, 
    "group".email as group_email, 
    "group".contact as group_contact, 
    "group".address as group_address, 
    "group".biography, 
    "group".about as group_about, 
    "group".group_img_path, 
    "group".banner_img_path,
    coalesce(group_count.user_count,0) as group_user_count
    from "group"
    left join
    (select "group" as group_id,count(*) as user_count from profile where "group" is not null group by "group") as group_count
    on group_count.group_id="group".id
    WHERE
      CASE
        WHEN _group_id IS NOT NULL THEN  "group".id = _group_id
        Else true
      END
  ) as group_detail$$;


ALTER FUNCTION "public"."util_get_group_detail"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_harvest_by_farm"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(harvest_group)
  from (
    select 
      id as harvest_id, 
      user_id, 
      create_date as harvest_create_date, 
      date as harvest_date,
      amount as harvest_amount, 
      farm_id 
      from harvest
      where farm_id = _farm_id
  ) as harvest_group$$;


ALTER FUNCTION "public"."util_get_harvest_by_farm"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_harvest_in_shop_by_user"("_username" character varying) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(harvest_group)
  from (
    select 
      h.id as harvest_id, 
      h.user_id, 
      h.create_date as harvest_create_date, 
      h.amount as harvest_amount, 
      h.farm_id,
      f_t.subtype as farm_sub_type
      from harvest h
      left join profile p on p.id = h.user_id
      left join farm f on f.id = h.farm_id
      left join farm_type f_t on f_t.id = f.type_id
      where p.username = _username
  ) as harvest_group
$$;


ALTER FUNCTION "public"."util_get_harvest_in_shop_by_user"("_username" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_maintenance"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
SELECT json_build_object(
    'is_maintenance_active', is_maintenance_active,
    'message', message,
    'version', version,
    'timeframe', timeframe
)
FROM maintenance
WHERE id = 1;
$$;


ALTER FUNCTION "public"."util_get_maintenance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_news_ordered"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(news_group)
  from (
    select 
      author,
      id as news_id, 
      news_type,
      published_date,
      title as news_title,
      url as news_url,
      url_image as news_url_image
      from news
      order by published_date desc
  ) as news_group$$;


ALTER FUNCTION "public"."util_get_news_ordered"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_news_type"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(news_group)
  from (
    select 
      DISTINCT news_type
      from news
  ) as news_group$$;


ALTER FUNCTION "public"."util_get_news_type"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_notification"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  SELECT JSON_AGG(notification_data)
  FROM (
    SELECT 
      id,heading,message,created_at
    FROM
      notification
    ORDER by
      created_at
  ) AS notification_data;
$$;


ALTER FUNCTION "public"."util_get_notification"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_planting_cycles"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN (
    SELECT json_agg(cycle)
    FROM (
      SELECT
        c.cycle_id,
        c.cycle_name,
        c.area_usage_rai,
        c.crop_name,
        c.farm_type_id,
        c.crop_age,
        c.crop_age_unit,
        c.total_trees,
        c.growth_month_start,
        c.growth_month_end,
        c.harvest_month_start,
        c.harvest_month_end,
        c.expected_annual_yield,
        c.created_at
      FROM public.tb_m_planting_cycles c
      WHERE c.farm_id = _farm_id
      ORDER BY c.created_at DESC
    ) AS cycle
  );
END;
$$;


ALTER FUNCTION "public"."util_get_planting_cycles"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_plot_product_detail"("_month" smallint, "_shop_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$    
    select json_agg(transaction_group)
    from  (select 
            pro_op.name as product_option_name,
            pro_op.total_sale as product_option_total_sale
            from transaction t 
            left join product_option pro_op on pro_op.id = t.product_id
            left join product pro on pro.id = pro_op.product_id
            where pro.shop_id = _shop_id and  EXTRACT(MONTH FROM t.create_date) = _month ) as transaction_group
$$;


ALTER FUNCTION "public"."util_get_plot_product_detail"("_month" smallint, "_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_plot_stat"("_group_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(plot_stat)
  from (
    select coalesce(farm_type.subtype, 'Total') as type, count(*) as total_subtype, farm.type_id
    from farm
    left join farm_type on farm.type_id = farm_type.id
    left join profile on profile.id = farm.user_id 
    WHERE
      farm.status = true
    --   CASE
    --     WHEN 'efd84fee-93ec-4d26-861a-0ba313a0fde9' IS NOT NULL THEN farm.status = true AND profile."group" = 'efd84fee-93ec-4d26-861a-0ba313a0fde9'
    --     ELSE farm.status = true
    --   END
    group by (farm_type.subtype, farm.type_id)
    order by total_subtype desc
  ) as plot_stat$$;


ALTER FUNCTION "public"."util_get_plot_stat"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_plot_type_stat"("_group_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(plot_stat)
  from (
      select coalesce(farm_type.type, 'Total') as type, count(*) as total_subtype
      from farm
      left join farm_type on farm.type_id = farm_type.id
      left join profile on profile.id = farm.user_id 
      WHERE
        CASE
          WHEN _group_id IS NOT NULL THEN farm.status = true AND profile."group" = _group_id
          ELSE farm.status = true
        END
      group by rollup (farm_type.type)
      order by total_subtype desc
  ) as plot_stat$$;


ALTER FUNCTION "public"."util_get_plot_type_stat"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_product_detail"("_product_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(product_group)
  from (
    select 
      pro.name as product_name,
      pro.detail as product_detail,
      pro.status as product_status,
      pro.img_path as product_img_path,
      pro.categories as product_categories,
      pro.shipping as product_shipping,
      pro_op.id as product_option_id,
      pro_op.name as product_option_name,
      pro_op.detail as product_option_detail,
      pro_op.price as product_option_price,
      pro_op.stock as product_option_stock,
      pro_op.unit as product_option_unit,
      f_t.type as farm_type_type,
      f.name as farm_name,
      f.address as farm_address
    from product pro
    left join product_option pro_op on pro_op.product_id = pro.id
    left join farm f on f.id = pro.farm_id
    left join farm_type f_t on f_t.id = f.type_id
    where pro.id = _product_id
  ) as product_group
$$;


ALTER FUNCTION "public"."util_get_product_detail"("_product_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_product_in_shop"("_shop_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(product_group)
  from (
    select 
      id as product_id,
      name as product_name,
      detail as product_detail,
      status as product_status,
      categories as product_categories,
      shop_id,
      farm_id,
      img_path as product_img_path
    from product
    where shop_id = _shop_id
  ) as product_group
$$;


ALTER FUNCTION "public"."util_get_product_in_shop"("_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_profile_from_group"("_group_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(profile_group)
  from (
    select 
      id as user_id, 
      first_name, 
      last_name, 
      address as user_address, 
      img_path as user_img_path, 
      status as user_status, 
      sub_district_id as user_sub_district_id,
      "group" as user_group, 
      phone as user_phone, 
      email as user_email, 
      username, 
      id_card, 
      create_date as user_create_date, 
      update_date as user_update_date 
    from profile
    where profile."group" = _group_id
  ) as profile_group$$;


ALTER FUNCTION "public"."util_get_profile_from_group"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_profile_from_id"("_user_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(profile)
  from (
    select 
      id as user_id, 
      first_name, 
      last_name, 
      address as user_address, 
      img_path as user_img_path, 
      status as user_status, 
      sub_district_id as user_sub_district_id,
      "group" as user_group, 
      phone as user_phone, 
      email as user_email, 
      username, 
      id_card, 
      create_date as user_create_date, 
      update_date as user_update_date 
    from profile
    where profile.id = _user_id
  ) as profile$$;


ALTER FUNCTION "public"."util_get_profile_from_id"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_profile_from_line"("_line_id" character varying) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  SELECT 
    CASE 
      WHEN _line_id IS NULL THEN NULL 
      ELSE JSON_AGG(profile_data)
    END
  FROM (
    SELECT 
      profile.id
    FROM
      profile
    WHERE
      line_id = _line_id
  ) AS profile_data;
$$;


ALTER FUNCTION "public"."util_get_profile_from_line"("_line_id" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_profile_sub_district"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(profile_group)
  from (
    select 
      p.id as user_id, 
      p.first_name, 
      p.last_name, 
      p.address as user_address, 
      p.img_path as user_img_path, 
      p.status as user_status,
      p."group" as user_group, 
      p.phone as user_phone, 
      p.email as user_email, 
      p.username, 
      p.id_card,
      p.farm_type_category,
      p.farmer_id,
      p.farmer_id_register_date,
      p.date_of_birth,
      p.house_id,
      p.default_lat,
      p.default_lon,
      p.create_date as user_create_date, 
      p.update_date as user_update_date,
      p.prefix as user_prefix,
      p.license_active,
      sub.id as sub_district_id,
      sub.tam_id,
      sub.tambon_th,
      sub.amp_id,
      sub.amphoe_th,
      sub.pro_id,
      sub.province_th,
      sub.postcode,
      s.id as shop_id
      from profile p
      left join sub_district sub on sub.id = p.sub_district_id
      left join shop s on s.user_id = p.id
      where p.id = auth.uid()
  ) as profile_group$$;


ALTER FUNCTION "public"."util_get_profile_sub_district"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_province"() RETURNS TABLE("pro_id" integer, "province_en" "text", "province_th" "text")
    LANGUAGE "sql"
    AS $$
   select pro_id,province_en,province_th from sub_district group by pro_id,province_en,province_th order by pro_id
$$;


ALTER FUNCTION "public"."util_get_province"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_quota_item"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(quota_group) 
  from (
    select 
      f_t.id as farm_type_id,
      f_t.subtype as farm_type_subtype,
      sum(q.amount) as quota_item_amount,
      hv.sum as harvest_amount_item
    from quota_item q
    left join farm_type f_t on f_t.id = q.farm_type_id
    left join (
              SELECT SUM(hv.amount),
              f_t.subtype
              FROM harvest hv
              LEFT JOIN quota_item q ON q.farm_id = hv.farm_id
              LEFT JOIN farm_type f_t ON f_t.id = q.farm_type_id
              WHERE hv.farm_id = q.farm_id
              AND hv.date >= q.start_date 
              group by  f_t.subtype
              ) AS hv ON hv.subtype = f_t.subtype
    group by f_t.id, f_t.subtype, hv.sum
  ) as quota_group$$;


ALTER FUNCTION "public"."util_get_quota_item"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_report_data_superadmin"() RETURNS "json"
    LANGUAGE "sql"
    AS $$

SELECT json_agg(report)
from
( 
    select
    p.first_name AS user_firstname,
    p.last_name AS user_lastname,
    p.phone AS user_phone,
    TO_CHAR(p.create_date, 'DD Month YYYY') AS user_created, 
    TO_CHAR(f.create_date, 'DD Month YYYY') AS farm_created,
    TO_CHAR(atv.create_date, 'DD Month YYYY') AS activity_created,
    TO_CHAR(p.update_date, 'DD Month YYYY') AS user_updated, 
    TO_CHAR(f.update_date, 'DD Month YYYY') AS farm_updated,
    TO_CHAR(atv.update_date, 'DD Month YYYY') AS activity_updated

    FROM
    farm f
LEFT JOIN 
    profile p ON f.user_id = p.id
LEFT JOIN 
    activity atv ON f.id = atv.farm_id

WHERE 
    p.update_date > '2024-08-06' and f.update_date > '2024-08-06' and atv.update_date > '2024-08-06'

) as report

;$$;


ALTER FUNCTION "public"."util_get_report_data_superadmin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_report_data_superadmin"("_date" timestamp without time zone) RETURNS "json"
    LANGUAGE "sql"
    AS $$
SELECT json_agg(report)
FROM (
    SELECT DISTINCT ON (p.first_name || ' ' || p.last_name)
        p.first_name || ' ' || p.last_name AS user_name,
        p.phone AS user_phone,
        TO_CHAR(p.create_date, 'DD Month YYYY') AS user_created, 
        TO_CHAR(f.create_date, 'DD Month YYYY') AS farm_created,
        TO_CHAR(atv.create_date, 'DD Month YYYY') AS activity_created,
        TO_CHAR(p.update_date, 'DD Month YYYY') AS user_updated, 
        TO_CHAR(f.update_date, 'DD Month YYYY') AS farm_updated,
        TO_CHAR(atv.update_date, 'DD Month YYYY') AS activity_updated
    FROM
        farm f
    LEFT JOIN 
        profile p ON f.user_id = p.id
    LEFT JOIN 
        activity atv ON f.id = atv.farm_id
    WHERE 
         (p.create_date >= _date OR f.create_date >= _date OR atv.create_date >= _date) AND
        (p.update_date >= _date OR f.update_date >= _date OR atv.update_date >= _date)
) AS report
$$;


ALTER FUNCTION "public"."util_get_report_data_superadmin"("_date" timestamp without time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_sensor"("_user_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(sensor)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id, 
      f.update_date as farm_update_date,
      h_b.id as ha_bridge_id,
      h_b.name as ha_bridge_name,
      h_b.owner_id as ha_bridge_user_id,
      h_b.shared_to,
      h_b.metadata as ha_bridge_metadata,
      json_agg(h_en) AS ha_entities
      from farm f 
      left join ha_bridges h_b on h_b.id = f.ha_bridge_id
      left join (
        select 
        h_a.id AS bridge_id,
        h_e.entity_id,
        h_e.state_ref,
        h_e.current_state,
        h_e.state_attr
        FROM
          ha_bridges h_a
        LEFT JOIN
          ha_entities h_e ON h_a.id = h_e.bridge_id
        ) as h_en ON h_en.bridge_id = f.ha_bridge_id
      where f.user_id = _user_id and f.ha_bridge_id is not null
      GROUP BY 
      f.id, 
      h_b.id
  ) as sensor
$$;


ALTER FUNCTION "public"."util_get_sensor"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_shop_by_id"("_shop_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(shop_group)
  from (
    select 
      id as shop_id, 
      user_id as owner_shop_id, 
      name as shop_name, 
      detail as shop_detail, 
      address as shop_address, 
      phone as shop_phone, 
      line_id as shop_line_id, 
      account_name as shop_account_name, 
      payment_img_path as shop_payment_img_path
    from shop
    where id = _shop_id
  ) as shop_group
$$;


ALTER FUNCTION "public"."util_get_shop_by_id"("_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_shop_by_user"("_user_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(shop_group)
  from (
    select 
      id as shop_id, 
      user_id as owner_shop_id, 
      name as shop_name, 
      detail as shop_detail, 
      address as shop_address, 
      phone as shop_phone, 
      line_id as shop_line_id, 
      account_name as shop_account_name, 
      payment_img_path as shop_payment_img_path,
      img_path as shop_img_path
    from shop
    where user_id = _user_id
  ) as shop_group
$$;


ALTER FUNCTION "public"."util_get_shop_by_user"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_shop_detail"("_shop_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(shop_group)
  from (
    select 
      s.id as shop_id, 
      s.user_id as owner_shop_id, 
      s.name as shop_name, 
      s.detail as shop_detail, 
      s.address as shop_address, 
      s.phone as shop_phone, 
      s.line_id as shop_line_id, 
      s.account_name as shop_account_name, 
      s.payment_img_path as shop_payment_img_path,
      s.img_path as shop_img_path,
      s.banner_img_path as shop_banner_img_path,
      coalesce(avg(CAST(c.rating AS FLOAT)),0) as average_rating
    from shop s
    left join product p on p.shop_id = s.id
    left join comment c on c.product_id = p.id
    where s.id = _shop_id
    group by s.id
  ) as shop_group
$$;


ALTER FUNCTION "public"."util_get_shop_detail"("_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_shop_detail_page"("_username" character varying) RETURNS "json"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$ 
  select json_agg(shop_group)
  from (
    select 
      s.id as shop_id, 
      s.user_id as owner_shop_id, 
      s.name as shop_name, 
      s.detail as shop_detail, 
      s.address as shop_address, 
      s.phone as shop_phone, 
      s.line_id as shop_line_id, 
      s.account_name as shop_account_name, 
      s.payment_img_path as shop_payment_img_path,
      s.img_path as shop_img_path,
      s.banner_img_path as shop_banner_img_path,
      coalesce(avg(CAST(c.rating AS FLOAT)),0) as average_rating
    from shop s
    left join product p on p.shop_id = s.id
    left join comment c on c.product_id = p.id
    left join profile pf on pf.id = s.user_id
    where pf.username = _username
    group by s.id
  ) as shop_group
$$;


ALTER FUNCTION "public"."util_get_shop_detail_page"("_username" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_shop_product_chart"("_shop_id" "uuid", "_month" smallint) RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(shop_group)
  from (
    select 
      s.id as shop_id,
      coalesce(sum(p_o.total_sale)) as total_sale,
      p.name as product_name
    from shop s
    left join product p on p.shop_id = s.id
    left join product_option p_o on p_o.product_id = p.id
    left join transaction t on t.product_id = p_o.id
    WHERE s.id = _shop_id AND EXTRACT(MONTH FROM t.create_date) = _month 
    GROUP BY s.id, EXTRACT(MONTH FROM t.create_date),p.name
  ) as shop_group
$$;


ALTER FUNCTION "public"."util_get_shop_product_chart"("_shop_id" "uuid", "_month" smallint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_shop_product_detail"("_shop_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(shop_group)
  from (
    select 
      s.id as shop_id, 
      p.id as product_id,
      p.name as product_name,
      p.detail ->> 'description' AS product_detail,
      p.detail ->> 'recommend' AS product_recommend,
      p.status as product_status,
      p.img_path as product_img_path,
      p.categories as product_categories,
      p.shipping as product_shipping,
      sum(p_o.stock) as total_product,
      sum(p_o.total_sale) as total_sale
    from shop s
    left join product p on p.shop_id = s.id
    left join product_option p_o on p_o.product_id = p.id
    where s.id = _shop_id
    GROUP BY s.id, p.name,  p.detail ->> 'description', p.detail ->> 'recommend' , p.status, p.img_path , p.id
  ) as shop_group
$$;


ALTER FUNCTION "public"."util_get_shop_product_detail"("_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_signurl_activity"("_url" "text", "_expiration_interval" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $_$DECLARE
      v_error TEXT;
      v_result JSONB;
  BEGIN
      -- Determine the function to call based on the URL type
      IF _url ~* '^https?://' THEN
          -- If the URL is a string, call createSignedUrl
          EXECUTE FORMAT(
              'supabase.storage.from(''activity'').createSignedUrl($1, $2)',
              _url, _expiration_interval
          ) INTO v_result;
      ELSE
          -- If the URL is an array, call createSignedUrls
          EXECUTE FORMAT(
              'supabase.storage.from(''activity'').createSignedUrls($1, $2)',
              _url, _expiration_interval
          ) INTO v_result;
      END IF;

      -- Check if there was an error during the operation
      IF v_result IS NULL THEN
          -- If v_result is NULL, there was an error
          v_error := 'Error generating signed URL(s)';
      END IF;

      -- Build the result JSON object
      RETURN JSONB_BUILD_OBJECT('result', v_result, 'error', v_error);
  END;$_$;


ALTER FUNCTION "public"."util_get_signurl_activity"("_url" "text", "_expiration_interval" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_signurl_snapshot"("_url" "text", "_expiration_interval" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $_$DECLARE
    v_error TEXT;
    v_result JSONB;
BEGIN
    -- Determine the function to call based on the URL type
    IF _url ~* '^https?://' THEN
        -- If the URL is a string, call createSignedUrl
        EXECUTE FORMAT(
            'supabase.storage.from(''snapshots'').createSignedUrl($1, $2)',
            _url, _expiration_interval
        ) INTO v_result;
    ELSE
        -- If the URL is an array, call createSignedUrls
        EXECUTE FORMAT(
            'supabase.storage.from(''snapshots'').createSignedUrls($1, $2)',
            _url, _expiration_interval
        ) INTO v_result;
    END IF;

    -- Check if there was an error during the operation
    IF v_result IS NULL THEN
        -- If v_result is NULL, there was an error
        v_error := 'Error generating signed URL(s)';
    END IF;

    -- Build the result JSON object
    RETURN JSONB_BUILD_OBJECT('result', v_result, 'error', v_error);
END;$_$;


ALTER FUNCTION "public"."util_get_signurl_snapshot"("_url" "text", "_expiration_interval" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_standard_by_user_id"("_user_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
   select json_agg(standard_group)
  from (
    select 
      id as standard_id, 
      user_id, detail as standard_detail, 
      type_id as standard_type_id, 
      file_path as standard_file_path, 
      create_date as standard_create_date, 
      update_date as standard_update_date 
      from standard
      where user_id = _user_id
  ) as standard_group
$$;


ALTER FUNCTION "public"."util_get_standard_by_user_id"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_standard_type"() RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(standard_type_group)
  from (
    select 
      id as standard_type_id, 
      name as standard_type_name, 
      metadata as standard_metadata 
      from standard_type
  ) as standard_type_group
$$;


ALTER FUNCTION "public"."util_get_standard_type"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_status_area_farm"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(farm_group)
  from (
    select 
      status as farm_status,
      area_size
      from farm f
      where f.id = _farm_id
      order by status desc
  ) as farm_group
$$;


ALTER FUNCTION "public"."util_get_status_area_farm"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_sub_district"("district" integer) RETURNS TABLE("sub_district_id" integer, "postcode" integer, "tambon_en" "text", "tambon_th" "text")
    LANGUAGE "sql"
    AS $$select id,postcode,tambon_en,tambon_th from sub_district where amp_id = district group by id,postcode,tambon_en,tambon_th order by id$$;


ALTER FUNCTION "public"."util_get_sub_district"("district" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_sub_district_by_id"("_sub_district_id" bigint) RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(sub_district_group)
  from (
    select 
      id as sub_district_id, 
      tam_id, 
      tambon_en, 
      tambon_th, 
      amp_id, 
      amphoe_en, 
      amphoe_th, 
      pro_id, 
      province_en, 
      province_th, 
      postcode, 
      geom as geom_sub_district 
      from sub_district
      where id = _sub_district_id
  ) as sub_district_group
$$;


ALTER FUNCTION "public"."util_get_sub_district_by_id"("_sub_district_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_traceback"("_farm_id" bigint) RETURNS "json"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$DECLARE
    result JSON;
BEGIN
    SELECT json_agg(json_build_object(
        'first_name', profile.first_name,
        'last_name', profile.last_name,
        'farm_name', farm.name,
        'subtype', farm_type.subtype,
        'area_size', farm.area_size,
        'address', farm.address,
        'harvest_amount', t2.amount,
        'harvest_date', t2.date
    )) INTO result
    FROM farm
    JOIN profile ON farm.user_id = profile.id
    JOIN farm_type ON farm.type_id = farm_type.id
    LEFT JOIN (
        SELECT h.farm_id,
               h.amount,
               h.date
        FROM harvest h
        WHERE h.date = (
            SELECT MAX(date) 
            FROM harvest
            WHERE farm_id = h.farm_id
        )
    ) t2 ON t2.farm_id = farm.id
    WHERE farm.id = _farm_id
    AND farm.traceable = true;

    RETURN result;
END;$$;


ALTER FUNCTION "public"."util_get_traceback"("_farm_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_transaction_by_shop"("_shop_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$    
    select json_agg(transaction_group)
    from  (select 
            pro_op.name as product_option_name,
            t.id as transaction_id,
            t.price_per_unit as transaction_price_per_unit,
            t.total_cost as transaction_total_cost,
            t.discount as transaction_discount,
            t.shipping_address,
            t.payment_method,
            t.img_path as transaction_img_path,
            to_char(t.create_date AT TIME ZONE 'UTC+7', 'YYYY-MM-DD HH24:MI:SS') AS transaction_create_date,
            p.phone as customer_phone
            from transaction t 
            left join product_option pro_op on pro_op.id = t.product_id
            left join product pro on pro.id = pro_op.product_id
            left join profile p on p.id = t.customer_id
            where pro.shop_id = _shop_id ) as transaction_group
$$;


ALTER FUNCTION "public"."util_get_transaction_by_shop"("_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_true_farm_owner_from_group"("_group_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
  select json_agg(plot_group)
  from (
    select 
      f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id, 
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id,
      f.update_date as farm_update_date,
      p.first_name,
      p.last_name
      from farm f 
      left join profile p on p.id = f.user_id
      where p."group" = _group_id and f.status = True
  ) as plot_group
$$;


ALTER FUNCTION "public"."util_get_true_farm_owner_from_group"("_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_true_farm_with_plant"() RETURNS "json"
    LANGUAGE "sql"
    AS $$select json_agg(farm_group)
  from (
    select 
     f.id as farm_id, 
      f.name as farm_name, 
      f.status as farm_status, 
      f.address as farm_address, 
      f.create_date as farm_create_date, 
      f.ha_bridge_id, 
      f.snapshot_url as farm_snapshot, 
      f.title_deed_no, 
      f.sub_district_id as farm_sub_district_id,
      f.user_id, 
      f.geometry, 
      f.type_id as farm_type_id, 
      f.area_size,
      f."group" as farm_group_id, 
      f.update_date as farm_update_date,
      f_t.id as farm_type_id, 
      f_t.category as farm_type_category, 
      f_t.type as farm_type_type, 
      f_t.subtype as farm_type_subtype, 
      f_t.metadata as farm_type_metadata,
      f_t."group" as farm_type_group,
      lh.latest_harvest_date,
      f_g.farm_group_name
      from farm f
      left join farm_type f_t on f_t.id = f.type_id
      LEFT JOIN (
      SELECT farm_id, MAX(date) AS latest_harvest_date
      FROM harvest
      GROUP BY farm_id
    ) lh ON f.id = lh.farm_id
    LEFT JOIN (
      SELECT id as farm_group_id, name AS farm_group_name
      FROM farm_group
    ) f_g ON f."group" = f_g.farm_group_id
      where f.status = true
  ) as farm_group$$;


ALTER FUNCTION "public"."util_get_true_farm_with_plant"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_user_ids_in_group"("gid" "uuid") RETURNS TABLE("user_id" "uuid")
    LANGUAGE "sql" STABLE
    AS $$
  select id
  from profile
  where (gid = any(groups))
$$;


ALTER FUNCTION "public"."util_get_user_ids_in_group"("gid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_user_report_superadmin"("_start_date" timestamp without time zone DEFAULT NULL::timestamp without time zone, "_end_date" timestamp without time zone DEFAULT NULL::timestamp without time zone, "_user_id" "uuid" DEFAULT NULL::"uuid", "_group_id" "uuid" DEFAULT NULL::"uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$
SELECT json_agg(report)
FROM (
    SELECT
        p.first_name || ' ' || p.last_name AS user_name,
        p.phone AS user_phone,
        REPLACE(g.name, E'\n', '') as group_name,
        REPLACE(p.address, E'\n', '') AS address,
        p.create_date::date AS user_created,
        p.update_date::date AS user_updated
    FROM
        profile p
    left join "group" g on g.id = p."group"
    WHERE
        (p.create_date::date >= COALESCE(_start_date, p.create_date::date))
        AND (p.create_date::date <= COALESCE(_end_date, p.create_date::date))
        AND (_user_id IS NULL OR p.id = _user_id)
        AND (_group_id IS NULL OR p."group" = _group_id)
) AS report;
$$;


ALTER FUNCTION "public"."util_get_user_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_username"("_user_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(username)
  from (
    select
      username
    from profile
    where id = _user_id
  ) as username
$$;


ALTER FUNCTION "public"."util_get_username"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_get_username_update_time"("_user_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin
 select json_agg(username_group) 
 from (select
        username_update_date
        from profile 
        where id = _user_id
 ) as username_group;
end;
$$;


ALTER FUNCTION "public"."util_get_username_update_time"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_handle_update_username"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  day_left INTEGER;
BEGIN
  IF NEW.username <> OLD.username THEN
    IF NEW.username_update_date - OLD.username_update_date < INTERVAL '30 days' THEN
      day_left := 30 - EXTRACT(DAY FROM NOW() - OLD.username_update_date);
      RAISE EXCEPTION 'Username can change every 30 days. Please wait for % more days.', day_left;
    END IF;
  END IF;
  
  RETURN NEW; -- or RETURN OLD; depending on your use case
END;
$$;


ALTER FUNCTION "public"."util_handle_update_username"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_join_group"("gid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Add group and remove duplicated id into own profile
  return public.util_join_group_to_user(gid, (auth.jwt()->>'sub')::uuid);
end
$$;


ALTER FUNCTION "public"."util_join_group"("gid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_join_group_to_user"("gid" "uuid", "uid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
declare
  _cnt bigint;
begin
  -- Add group and remove duplicated id into specified user profile

  -- check if gid exists
  if not exists (select 1 from groups where id = gid) then
    return false;
  end if;

  update profile
  set groups = (select array_agg(distinct x) from unnest(array_append(groups, gid)) x)
  where id = uid;
  get diagnostics _cnt = row_count;

  return _cnt > 0;

  exception when others then
    return false;
end
$$;


ALTER FUNCTION "public"."util_join_group_to_user"("gid" "uuid", "uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_leave_group"("gid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Remove group from specified user profile
  return (public.util_leave_group_from_user(gid, (auth.jwt()->>'sub')::uuid));
end
$$;


ALTER FUNCTION "public"."util_leave_group"("gid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_leave_group_from_user"("gid" "uuid", "uid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
declare
  _cnt bigint;
begin
  -- Remove group from own profile
  update profile
  set groups = array_remove(groups, gid)
  where id =uid;
  get diagnostics _cnt = row_count;

  return _cnt > 0;

  exception when others then
    return false;
end
$$;


ALTER FUNCTION "public"."util_leave_group_from_user"("gid" "uuid", "uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_predict_all_yield"() RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN (
    SELECT json_agg(farm_group)
    FROM (
      SELECT 
        f.id AS farm_id,
        f.user_id,
        f.name AS farm_name,
        f.status AS farm_status,
        ft.subtype AS farm_subtype,
        f.area_size * ft.yield_per_sqm AS predicted_yield,
        (act.last_planted::date + INTERVAL '1 day' * ft.duration)::date AS predicted_harvest
      FROM farm f
      LEFT JOIN farm_type ft ON ft.id = f.type_id
      LEFT JOIN (
        SELECT farm_id, MAX(date) AS last_planted
        FROM activity
        WHERE type_id = 1
        GROUP BY farm_id
      ) act ON act.farm_id = f.id
      WHERE ft.subtype IS NOT NULL 
      AND act.last_planted IS NOT NULL
      AND ft.duration IS NOT NULL
      AND f.status = true
      GROUP BY f.id, f.user_id, f.name, f.status, ft.subtype, ft.duration, ft.yield_per_sqm, act.last_planted
    ) AS farm_group
  );
END;
$$;


ALTER FUNCTION "public"."util_predict_all_yield"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_product_on_sell_in_shop"("_shop_id" "uuid") RETURNS "json"
    LANGUAGE "sql"
    AS $$ 
  select json_agg(shop_group)
  from (
    select 
      pro.name as product_name,
      pro.img_path as product_img_path,
      avg(c.rating) as product_rating,
      min(pro_op.price) as product_option_min_price,
      max(pro_op.price) as product_option_max_price
    from product pro 
    left join product_option pro_op on pro_op.product_id = pro.id
    left join comment c on c.product_id = pro.id
    where pro.shop_id = _shop_id and pro.status = true
    group by pro.name, pro.img_path
  ) as shop_group
$$;


ALTER FUNCTION "public"."util_product_on_sell_in_shop"("_shop_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_purge_group"("gid" "uuid") RETURNS "void"
    LANGUAGE "sql"
    AS $$
  -- Remove 'gid' from each profile then remove row in 'groups' table
  select util_leave_group_from_user(gid, user_id)
  from public.util_get_user_ids_in_group(gid);

  delete from groups where id = gid;
$$;


ALTER FUNCTION "public"."util_purge_group"("gid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_remove_img_snapshot"("_url" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $_$DECLARE
    v_error TEXT;
BEGIN
    -- Execute the Supabase storage command to remove the image
    EXECUTE FORMAT(
        'supabase.storage.from(''snapshots'').remove($1)',
        _url
    ) INTO v_error;

    -- Check if there was an error during removal
    IF v_error IS NOT NULL THEN
        RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', v_error);
    ELSE
        RETURN JSONB_BUILD_OBJECT('success', TRUE, 'error', NULL);
    END IF;
END;$_$;


ALTER FUNCTION "public"."util_remove_img_snapshot"("_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_activity_img_path"("_activity_id" bigint, "_img_path" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
    update activity
    set img_path = _img_path
    where id = _activity_id;
  end$$;


ALTER FUNCTION "public"."util_update_activity_img_path"("_activity_id" bigint, "_img_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_cost_group"("_cost_group_id" bigint, "_name" "text") RETURNS "void"
    LANGUAGE "sql"
    AS $$update public.cost_group
    set name = _name
    where id = _cost_group_id;$$;


ALTER FUNCTION "public"."util_update_cost_group"("_cost_group_id" bigint, "_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_farm_area_name"("_farm_id" bigint, "_name" "text", "_area_size" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
    UPDATE farm
    SET 
    name = coalesce(_name, name),
    area_size = coalesce(_area_size, area_size)
    where id = _farm_id;
  end$$;


ALTER FUNCTION "public"."util_update_farm_area_name"("_farm_id" bigint, "_name" "text", "_area_size" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_farm_area_name_status"("_farm_id" bigint, "_name" "text" DEFAULT NULL::"text", "_area_size" bigint DEFAULT NULL::bigint, "_status" boolean DEFAULT NULL::boolean, "_village_name" character varying DEFAULT NULL::character varying, "_moo" character varying DEFAULT NULL::character varying, "_road" character varying DEFAULT NULL::character varying, "_soi" character varying DEFAULT NULL::character varying) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE farm
  SET
    name        = COALESCE(_name, name),
    area_size   = COALESCE(_area_size, area_size),
    status      = COALESCE(_status, status),
    village_name = COALESCE(_village_name, village_name),
    moo         = COALESCE(_moo, moo),
    road        = COALESCE(_road, road),
    soi         = COALESCE(_soi, soi),
    update_date = now()
  WHERE id = _farm_id;
END;
$$;


ALTER FUNCTION "public"."util_update_farm_area_name_status"("_farm_id" bigint, "_name" "text", "_area_size" bigint, "_status" boolean, "_village_name" character varying, "_moo" character varying, "_road" character varying, "_soi" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_farm_name"("p_farm_id" bigint, "p_farm_name" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$BEGIN
    UPDATE farm
    SET name = p_farm_name
    WHERE id = p_farm_id;
END;$$;


ALTER FUNCTION "public"."util_update_farm_name"("p_farm_id" bigint, "p_farm_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_farm_status"("p_farm_status" boolean, "p_farm_id" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$BEGIN
    UPDATE farm
    SET status = coalesce(p_farm_status, status)
    WHERE id = p_farm_id;
END;$$;


ALTER FUNCTION "public"."util_update_farm_status"("p_farm_status" boolean, "p_farm_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_group"("p_group_id" "uuid", "_name" "text", "_address" "text", "_biography" "text", "_about" "text", "_email" "text", "_phone" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$begin
      UPDATE "group"
      SET
        name = COALESCE(_name, name),
        address = COALESCE(_address, address),
        biography = COALESCE(_biography, biography),
        about = COALESCE(_about, about),
        email = COALESCE(_email, email),
        phone = COALESCE(_phone, phone)
        where id = p_group_id;
    end$$;


ALTER FUNCTION "public"."util_update_group"("p_group_id" "uuid", "_name" "text", "_address" "text", "_biography" "text", "_about" "text", "_email" "text", "_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_group_banner"("_group_id" "uuid", "_img_path" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE "group"
    SET banner_img_path = _img_path
    WHERE id = _group_id;
END;
$$;


ALTER FUNCTION "public"."util_update_group_banner"("_group_id" "uuid", "_img_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_group_farm"("_farm_id" bigint[], "_group_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$DECLARE
    f_id int8;
BEGIN
    FOREACH f_id IN ARRAY _farm_id 
    LOOP
        UPDATE farm
        SET
            "group" = _group_id
        WHERE id = f_id;
    END LOOP;
END;$$;


ALTER FUNCTION "public"."util_update_group_farm"("_farm_id" bigint[], "_group_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_group_img_path"("_group_id" "uuid", "_img_path" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE "group"
    SET group_img_path = _img_path
    WHERE id = _group_id;
END;
$$;


ALTER FUNCTION "public"."util_update_group_img_path"("_group_id" "uuid", "_img_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_img_path_profile"("_user_id" "uuid", "_img_path" "text") RETURNS "void"
    LANGUAGE "sql"
    AS $$UPDATE profile
  SET img_path = _img_path
  WHERE id = _user_id;$$;


ALTER FUNCTION "public"."util_update_img_path_profile"("_user_id" "uuid", "_img_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_product"("_product_id" "uuid", "_name" "text", "_detail" "json", "_shipping" "json", "_categories" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update product set
  name = coalesce(_name, name),
  detail = coalesce(_detail, detail),
  shipping = coalesce(_shipping, shipping),
  categories = coalesce(_categories, categories)
  where id = _product_id;

  return json_build_object('product_id', _product_id);
end;
$$;


ALTER FUNCTION "public"."util_update_product"("_product_id" "uuid", "_name" "text", "_detail" "json", "_shipping" "json", "_categories" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_product_img"("_image_path" "text"[], "_product_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update product set
  img_path = coalesce(_image_path, img_path)
  where id = _product_id;

  return json_build_object('product_id', _product_id);
end;
$$;


ALTER FUNCTION "public"."util_update_product_img"("_image_path" "text"[], "_product_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_product_option"("_product_option_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update product_option set
  name = coalesce(_name, name),
  detail = coalesce(_detail, detail),
  price = coalesce(_price, price),
  unit = coalesce(_unit, unit),
  stock = coalesce(_stock, stock)
  where id = _product_option_id;

  return json_build_object('product_option_id', _product_option_id);
end;
$$;


ALTER FUNCTION "public"."util_update_product_option"("_product_option_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_product_option_img"("_image_path" "text", "_product_option_id" "uuid") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update product_option set
  img_path = coalesce(_image_path, img_path)
  where id = _product_option_id;

  return json_build_object('product_option_id', _product_option_id);
end;
$$;


ALTER FUNCTION "public"."util_update_product_option_img"("_image_path" "text", "_product_option_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_product_option_status"("_product_option_id" "uuid", "_status" boolean) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update product_option set
  status = coalesce(_status, status)
  where id = _product_option_id;

  return json_build_object('product_id', _product_option_id);
end;
$$;


ALTER FUNCTION "public"."util_update_product_option_status"("_product_option_id" "uuid", "_status" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_product_status"("_product_id" "uuid", "_status" boolean) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update product set
  status = coalesce(_status, status)
  where id = _product_id;

  return json_build_object('product_id', _product_id);
end;
$$;


ALTER FUNCTION "public"."util_update_product_status"("_product_id" "uuid", "_status" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_profile"("_user_id" "uuid", "_first_name" character varying DEFAULT NULL::character varying, "_last_name" character varying DEFAULT NULL::character varying, "_address" character varying DEFAULT NULL::character varying, "_sub_district_id" integer DEFAULT NULL::integer, "_id_card" character varying DEFAULT NULL::character varying, "_farm_type_category" "public"."profile_farm_type_category" DEFAULT NULL::"public"."profile_farm_type_category", "_farmer_id" character varying DEFAULT NULL::character varying, "_farmer_id_register_date" "date" DEFAULT NULL::"date", "_date_of_birth" "date" DEFAULT NULL::"date", "_house_id" character varying DEFAULT NULL::character varying, "_default_lat" double precision DEFAULT NULL::double precision, "_default_lon" double precision DEFAULT NULL::double precision, "_prefix" "public"."profile_name_prefix" DEFAULT NULL::"public"."profile_name_prefix") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Replace empty strings with NULL
    IF _first_name = '' THEN
        _first_name := NULL;
    END IF;
    IF _last_name = '' THEN
        _last_name := NULL;
    END IF;
    IF _address = '' THEN
        _address := NULL;
    END IF;
    IF _id_card = '' THEN
        _id_card := NULL;
    END IF;
    IF _farmer_id = '' THEN
        _farmer_id := NULL;
    END IF;
    IF _house_id = '' THEN
        _house_id := NULL;
    END IF;

    -- Update the profile with COALESCE to retain old values if NULL
    UPDATE profile
    SET 
      first_name = COALESCE(_first_name, first_name),
      last_name = COALESCE(_last_name, last_name),
      address = COALESCE(_address, address),
      sub_district_id = COALESCE(_sub_district_id, sub_district_id),
      id_card = COALESCE(_id_card, id_card),
      farm_type_category = COALESCE(_farm_type_category, farm_type_category),
      farmer_id = COALESCE(_farmer_id, farmer_id),
      farmer_id_register_date = COALESCE(_farmer_id_register_date, farmer_id_register_date),
      date_of_birth = COALESCE(_date_of_birth, date_of_birth),
      house_id = COALESCE(_house_id, house_id),
      default_lat = COALESCE(_default_lat, default_lat),
      default_lon = COALESCE(_default_lon, default_lon),
      prefix = COALESCE(_prefix,prefix)
    WHERE id = _user_id;
END;
$$;


ALTER FUNCTION "public"."util_update_profile"("_user_id" "uuid", "_first_name" character varying, "_last_name" character varying, "_address" character varying, "_sub_district_id" integer, "_id_card" character varying, "_farm_type_category" "public"."profile_farm_type_category", "_farmer_id" character varying, "_farmer_id_register_date" "date", "_date_of_birth" "date", "_house_id" character varying, "_default_lat" double precision, "_default_lon" double precision, "_prefix" "public"."profile_name_prefix") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_shop"("_shop_id" "uuid" DEFAULT NULL::"uuid", "_name" "text" DEFAULT NULL::"text", "_detail" "json" DEFAULT NULL::"json", "_address" "text" DEFAULT NULL::"text", "_phone" "text" DEFAULT NULL::"text", "_line_id" "text" DEFAULT NULL::"text", "_account_name" "text" DEFAULT NULL::"text", "_img_path" "text" DEFAULT NULL::"text", "_banner_img_path" "text" DEFAULT NULL::"text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update shop set
  name = coalesce(_name, name),
  detail = coalesce(_detail, detail),
  address = coalesce(_address, address),
  phone = coalesce(_phone, phone),
  line_id = coalesce(_line_id, line_id),
  account_name = coalesce(_account_name, account_name),
  img_path = coalesce(_img_path, img_path),
  banner_img_path = coalesce(_banner_img_path, banner_img_path)
  where id = _shop_id;

  return json_build_object('shop_id', _shop_id);
end;
$$;


ALTER FUNCTION "public"."util_update_shop"("_shop_id" "uuid", "_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_account_name" "text", "_img_path" "text", "_banner_img_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_shop_img_path"("_shop_id" "uuid", "_img_path" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update shop set
  img_path = coalesce(_img_path, img_path)
  where id = _shop_id;

  return json_build_object('shop_id', _shop_id);
end;
$$;


ALTER FUNCTION "public"."util_update_shop_img_path"("_shop_id" "uuid", "_img_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_shop_payment_img_path"("_shop_id" "uuid", "_payment_img_path" "text") RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
begin 
  update shop set
  payment_img_path = coalesce(_payment_img_path, payment_img_path)
  where id = _shop_id;

  return json_build_object('shop_id', _shop_id);
end;
$$;


ALTER FUNCTION "public"."util_update_shop_payment_img_path"("_shop_id" "uuid", "_payment_img_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_snapshot_farm"("_farm_id" bigint, "_path_snapshot_url" "text") RETURNS "void"
    LANGUAGE "sql"
    AS $$update farm
    set snapshot_url = _path_snapshot_url
    where id = _farm_id;$$;


ALTER FUNCTION "public"."util_update_snapshot_farm"("_farm_id" bigint, "_path_snapshot_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_standard"("_standard_id" "uuid", "_detail" "json", "_file_path" "text", "_type_id" bigint) RETURNS "void"
    LANGUAGE "sql"
    AS $$
  update standard 
  set 
    detail = coalesce(_detail, detail),
    file_path = coalesce(_file_path, file_path),
    type_id = coalesce(_type_id, type_id),
    update_date = now()
    where id = _standard_id 
$$;


ALTER FUNCTION "public"."util_update_standard"("_standard_id" "uuid", "_detail" "json", "_file_path" "text", "_type_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_update_username"("_user_id" "uuid", "_username" character varying) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
  begin
  update profile 
  set username = coalesce(_username, username),
  username_update_date = case WHEN _username IS DISTINCT FROM username THEN NOW() ELSE username_update_date end
  where id = _user_id;
  end;
$$;


ALTER FUNCTION "public"."util_update_username"("_user_id" "uuid", "_username" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_updateretry"("input_id" integer) RETURNS "void"
    LANGUAGE "sql"
    AS $$
  update notification 
  set retry = retry + 1
  where id = input_id
$$;


ALTER FUNCTION "public"."util_updateretry"("input_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_upsert_client"("_client_id" bigint, "_name" character varying, "_delivery_round" character varying[], "_status" boolean, "_group" "uuid") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_client_id BIGINT;
BEGIN
    IF _client_id IS NULL THEN
        INSERT INTO client (name, delivery_round, status, "group")
        VALUES (_name, _delivery_round, _status, _group)
        RETURNING id INTO new_client_id;
    ELSE
        UPDATE client
        SET 
            name = COALESCE(_name, client.name),
            delivery_round = COALESCE(_delivery_round, client.delivery_round),
            status = COALESCE(_status, client.status),
            "group" = COALESCE(_group, client."group")
        WHERE id = _client_id;
        new_client_id := _client_id;
    END IF;
    RETURN new_client_id;
END;
$$;


ALTER FUNCTION "public"."util_upsert_client"("_client_id" bigint, "_name" character varying, "_delivery_round" character varying[], "_status" boolean, "_group" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_upsert_client_order"("_order_id" bigint, "_client_id" bigint, "_delivery_date" "date", "_order_date" "date", "_farm_type_id" bigint, "_amount" double precision) RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    _updated_order_id BIGINT; 
BEGIN
    IF _order_id IS NULL THEN
        INSERT INTO client_order (client_id, delivery_date, order_date)
        VALUES (_client_id, _delivery_date, _order_date)
        RETURNING id INTO _updated_order_id; 
    ELSE
        UPDATE client_order
        SET 
            client_id = COALESCE(_client_id, client_order.client_id),
            delivery_date = COALESCE(_delivery_date, client_order.delivery_date),
            order_date = COALESCE(_order_date, client_order.order_date)
        WHERE id = _order_id
        RETURNING id INTO _updated_order_id;
    END IF;

    IF _updated_order_id IS NOT NULL THEN
        INSERT INTO client_order_item (order_id, farm_type_id, amount)
        VALUES (_updated_order_id, _farm_type_id, _amount)
        ON CONFLICT (order_id, farm_type_id)
        DO UPDATE SET 
            amount = COALESCE(EXCLUDED.amount, client_order_item.amount);
    ELSE
        RAISE EXCEPTION 'Unable to insert/update client_order_item due to invalid order ID';
    END IF;

    RETURN _updated_order_id;
END;
$$;


ALTER FUNCTION "public"."util_upsert_client_order"("_order_id" bigint, "_client_id" bigint, "_delivery_date" "date", "_order_date" "date", "_farm_type_id" bigint, "_amount" double precision) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_upsert_farm"("_farm_id" bigint, "_status" boolean, "_user_id" "uuid", "_name" "text", "_type_id" bigint, "_create_date" timestamp without time zone, "_title_deed_no" "text", "_area_size" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN

    UPDATE farm
    SET
        status = COALESCE(_status, farm.status),
        user_id = COALESCE(_user_id, farm.user_id),
        name = COALESCE(_name, farm.name),
        type_id = COALESCE(_type_id, farm.type_id),
        create_date = COALESCE(_create_date, farm.create_date),
        title_deed_no = COALESCE(_title_deed_no, farm.title_deed_no),
        area_size = COALESCE(_area_size, farm.area_size)
    WHERE id = _farm_id;

    IF NOT FOUND THEN
        INSERT INTO farm (id, status, user_id, name, type_id, create_date, title_deed_no, area_size)
        VALUES (_farm_id, _status, _user_id, _name, _type_id, _create_date, _title_deed_no, _area_size);
    END IF;
END
$$;


ALTER FUNCTION "public"."util_upsert_farm"("_farm_id" bigint, "_status" boolean, "_user_id" "uuid", "_name" "text", "_type_id" bigint, "_create_date" timestamp without time zone, "_title_deed_no" "text", "_area_size" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_upsert_farm_traceable"("_farm_id" bigint, "_traceable" boolean) RETURNS "json"
    LANGUAGE "plpgsql"
    AS $$
declare 
  result json;
BEGIN
    UPDATE farm
    SET
        traceable = _traceable
    WHERE id = _farm_id
    returning id into result;

    return result;
END
$$;


ALTER FUNCTION "public"."util_upsert_farm_traceable"("_farm_id" bigint, "_traceable" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_upsert_order_history"("_order_history_id" bigint, "_file_path" character varying, "_group" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF _order_history_id IS NULL THEN
        INSERT INTO order_history_file (file_path, "group")
        VALUES (_file_path, _group);
    ELSE
        UPDATE order_history_file
        SET 
            file_path = COALESCE(_file_path, order_history_file.file_path),
            "group" = COALESCE(_group, order_history_file."group")
        WHERE id = _order_history_id;
    END IF;
END;
$$;


ALTER FUNCTION "public"."util_upsert_order_history"("_order_history_id" bigint, "_file_path" character varying, "_group" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_upsert_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint, "_cycle_id" bigint DEFAULT NULL::bigint) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF _cycle_id IS NULL THEN
    INSERT INTO public.tb_m_planting_cycles (
      farm_id, cycle_name, area_usage_rai, crop_age, crop_age_unit, crop_name,
      farm_type_id, total_trees, growth_month_start, growth_month_end,
      harvest_month_start, harvest_month_end, expected_annual_yield
    ) VALUES (
      _farm_id, _cycle_name, _area_usage_rai, _crop_age, _crop_age_unit, _crop_name,
      _type_id, NULLIF(_total_trees, 0), _growth_month_start, _growth_month_end,
      _harvest_month_start, _harvest_month_end, _expected_annual_yield
    );
  ELSE
    UPDATE public.tb_m_planting_cycles SET
      cycle_name            = _cycle_name,
      area_usage_rai        = _area_usage_rai,
      crop_age              = _crop_age,
      crop_age_unit         = _crop_age_unit,
      crop_name             = _crop_name,
      farm_type_id          = _type_id,
      total_trees           = NULLIF(_total_trees, 0),
      growth_month_start    = _growth_month_start,
      growth_month_end      = _growth_month_end,
      harvest_month_start   = _harvest_month_start,
      harvest_month_end     = _harvest_month_end,
      expected_annual_yield = _expected_annual_yield
    WHERE cycle_id = _cycle_id AND farm_id = _farm_id;
  END IF;

  UPDATE public.farm
  SET type_id     = _type_id,
      update_date = NOW()
  WHERE id = _farm_id;
END;
$$;


ALTER FUNCTION "public"."util_upsert_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint, "_cycle_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."util_upsert_quota_order"("_id" bigint, "_user_id" "uuid", "_meeting_date" "date", "_delivery_round" character varying[], "_farm_data" "jsonb", "_group" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    order_id BIGINT;
BEGIN
    IF _id IS NULL THEN
        INSERT INTO quota (user_id, meeting_date, delivery_round, "group")
        VALUES (_user_id, _meeting_date, _delivery_round, _group)
        RETURNING id INTO order_id; 
    ELSE
        UPDATE quota
        SET 
            user_id = COALESCE(_user_id, quota.user_id),
            meeting_date = COALESCE(_meeting_date, quota.meeting_date),
            delivery_round = COALESCE(_delivery_round, quota.delivery_round),
            "group" = COALESCE(_group, quota."group")
        WHERE id = _id;
        order_id := _id;
    END IF;

    IF order_id IS NOT NULL THEN
        INSERT INTO quota_item (quota_id, farm_type_id,farm_id, amount, start_date, area_size)
        SELECT 
            order_id,
            (farm_data ->> 'farm_type_id')::BIGINT,
            (farm_data ->> 'farm_id')::BIGINT,
            (farm_data ->> 'amount')::FLOAT8,
            (farm_data ->> 'start_date')::DATE,
            (farm_data ->> 'area_size')::FLOAT8
        FROM jsonb_array_elements(_farm_data) AS farm_data
        ON CONFLICT (quota_id, farm_type_id) 
        DO UPDATE SET 
            amount = COALESCE(EXCLUDED.amount, quota_item.amount),
            start_date = COALESCE(EXCLUDED.start_date, quota_item.start_date),
            farm_id = COALESCE(EXCLUDED.farm_id, quota_item.farm_id),
            area_size = COALESCE(EXCLUDED.area_size, quota_item.area_size);
    ELSE
        RAISE EXCEPTION 'Unable to insert/update quota_item due to invalid order ID';
    END IF;
END;
$$;


ALTER FUNCTION "public"."util_upsert_quota_order"("_id" bigint, "_user_id" "uuid", "_meeting_date" "date", "_delivery_round" character varying[], "_farm_data" "jsonb", "_group" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "develop"."profile" (
    "id" "uuid",
    "first_name" character varying,
    "last_name" character varying,
    "address" "text",
    "create_date" timestamp with time zone,
    "update_date" timestamp with time zone,
    "img_path" "text",
    "status" boolean,
    "sub_district_id" bigint,
    "is_first_login" boolean,
    "group" "uuid",
    "phone" "text",
    "email" character varying,
    "id_card" "text",
    "username" "text",
    "username_update_date" timestamp with time zone
);


ALTER TABLE "develop"."profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client" (
    "id" bigint NOT NULL,
    "name" character varying,
    "delivery_round" character varying[],
    "status" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "group" "uuid" NOT NULL
);


ALTER TABLE "public"."client" OWNER TO "postgres";


ALTER TABLE "public"."client" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."Client_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."activity" (
    "id" bigint NOT NULL,
    "farm_id" bigint NOT NULL,
    "img_path" "text",
    "type_id" bigint DEFAULT '5'::bigint NOT NULL,
    "note" "text",
    "date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "status" boolean DEFAULT true NOT NULL,
    "create_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "label_color" "text",
    "update_date" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."activity" OWNER TO "postgres";


COMMENT ON COLUMN "public"."activity"."label_color" IS 'for customization by user';



ALTER TABLE "public"."activity" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."activities_activity_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."activity_type" (
    "id" bigint NOT NULL,
    "name" character varying,
    "create_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "priority" bigint,
    "availability" "json" DEFAULT '{   "ผักสวนครัว": true,   "ผักสลัด": true,   "ผลไม้": true,   "ข้าว": true,   "พืชหัว": true,   "ธัญพืช": true }'::"json",
    "pre_activity" boolean DEFAULT false
);


ALTER TABLE "public"."activity_type" OWNER TO "postgres";


ALTER TABLE "public"."activity_type" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."activity_type_activity_type_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."client_order" (
    "id" bigint NOT NULL,
    "client_id" bigint,
    "delivery_date" "date",
    "order_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."client_order" OWNER TO "postgres";


ALTER TABLE "public"."client_order" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."client_order_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."client_order_item" (
    "id" bigint NOT NULL,
    "order_id" bigint,
    "farm_type_id" bigint,
    "amount" double precision
);


ALTER TABLE "public"."client_order_item" OWNER TO "postgres";


ALTER TABLE "public"."client_order_item" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."client_order_item_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."comment_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."comment_id_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comment" (
    "id" bigint DEFAULT "nextval"('"public"."comment_id_seq"'::"regclass") NOT NULL,
    "user_id" "uuid",
    "detail" "text",
    "rating" real,
    "create_date" timestamp with time zone DEFAULT "now"(),
    "update_date" timestamp with time zone DEFAULT "now"(),
    "product_id" "uuid",
    "product_variant_id" bigint
);


ALTER TABLE "public"."comment" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."cost_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."cost_id_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cost" (
    "id" bigint DEFAULT "nextval"('"public"."cost_id_seq"'::"regclass") NOT NULL,
    "user_id" "uuid" NOT NULL,
    "date" timestamp without time zone DEFAULT "now"(),
    "create_date" timestamp without time zone DEFAULT "now"() NOT NULL,
    "update_date" timestamp without time zone DEFAULT "now"() NOT NULL,
    "detail" "text",
    "price" double precision NOT NULL,
    "category" "text" NOT NULL,
    "group" bigint
);


ALTER TABLE "public"."cost" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."cost_calculation_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."cost_calculation_id_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cost_group" (
    "id" bigint NOT NULL,
    "name" "text",
    "create_date" timestamp with time zone DEFAULT "now"(),
    "update_date" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid"
);


ALTER TABLE "public"."cost_group" OWNER TO "postgres";


ALTER TABLE "public"."cost_group" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."cost_group_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."debug_log" (
    "id" bigint NOT NULL,
    "log" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."debug_log" OWNER TO "postgres";


ALTER TABLE "public"."debug_log" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."debug_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."dn_actions_crop" (
    "app_land_id" character varying(50) NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "crop_year" integer NOT NULL,
    "crop_name" character varying(100),
    "breed_name" character varying(100) NOT NULL,
    "is_specify_cert" boolean,
    "gap_cert_number" character varying(50),
    "gap_cert_type" character varying(50),
    "cert_issued_date" "date",
    "cert_expiry_date" "date",
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "pct_plant_area" numeric(5,2) NOT NULL,
    "total_trees" integer NOT NULL,
    "forecast_kg" numeric(10,2) NOT NULL,
    "forecast_baht" numeric(12,2) NOT NULL,
    "forecast_baht_per_kg" numeric(8,2) NOT NULL,
    "forecast_worker_cost" numeric(12,2) NOT NULL,
    "forecast_petrol_cost" numeric(12,2) NOT NULL,
    "forecast_fertilizer_cost" numeric(12,2) NOT NULL,
    "forecast_chemical_cost" numeric(12,2) NOT NULL,
    "forecast_equipment_cost" numeric(12,2) NOT NULL,
    "durian_stage" character varying(50),
    "avg_tree_age" integer,
    "harvest_rounds" integer,
    "is_deleted" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "cert_date_check" CHECK (("cert_expiry_date" >= "cert_issued_date")),
    CONSTRAINT "date_check" CHECK (("end_date" > "start_date")),
    CONSTRAINT "pct_plant_area_check" CHECK ((("pct_plant_area" >= (0)::numeric) AND ("pct_plant_area" <= (100)::numeric)))
);


ALTER TABLE "public"."dn_actions_crop" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_actions_crop_cost" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "from_date" "date" NOT NULL,
    "to_date" "date" NOT NULL,
    "worker_cost" numeric(12,2),
    "fertilizer_cost" numeric(12,2),
    "equipment_cost" numeric(12,2),
    "petrol_cost" numeric(12,2),
    "chemical_cost" numeric(12,2),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "date_range_check" CHECK (("to_date" >= "from_date"))
);


ALTER TABLE "public"."dn_actions_crop_cost" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_actions_crop_cost_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_actions_crop_cost_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_actions_crop_cost_id_seq" OWNED BY "public"."dn_actions_crop_cost"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_actions_crop_fruit_bloom" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "fruit_blooms" "jsonb" NOT NULL,
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_actions_crop_fruit_bloom" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_actions_crop_fruit_bloom_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_actions_crop_fruit_bloom_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_actions_crop_fruit_bloom_id_seq" OWNED BY "public"."dn_actions_crop_fruit_bloom"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_actions_crop_stages" (
    "app_crop_id" character varying(50) NOT NULL,
    "stg1_date" "date",
    "stg2_date" "date",
    "stg3_date" "date",
    "stg4_date" "date",
    "stg5_date" "date",
    "stg6_date" "date",
    "stg7_date" "date",
    "stg8_date" "date",
    "stg9_date" "date",
    "stg10_date" "date",
    "stg11_date" "date",
    "stg12_date" "date",
    "stg13_date" "date",
    "stg14_date" "date",
    "stg15_date" "date",
    "stg16_date" "date",
    "stg17_date" "date",
    "stg18_date" "date",
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_actions_crop_stages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_actions_crop_yield" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "yield_kg" numeric(12,2),
    "yield_baht" numeric(12,2),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_actions_crop_yield" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_actions_crop_yield_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_actions_crop_yield_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_actions_crop_yield_id_seq" OWNED BY "public"."dn_actions_crop_yield"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_iot_commands" (
    "id" bigint NOT NULL,
    "device_id" "text",
    "command_type" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "response_payload" "jsonb",
    "ack_payload" "jsonb",
    "sent_at" timestamp with time zone,
    "acked_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "retry_count" smallint,
    "max_retry" smallint DEFAULT '3'::smallint,
    "last_error text" "text",
    "processing_at" timestamp with time zone,
    CONSTRAINT "chk_status" CHECK (("status" = ANY (ARRAY['PENDING'::"text", 'PROCESSING'::"text", 'SENT'::"text", 'ACK'::"text", 'FAILED'::"text", 'TIMEOUT'::"text"])))
);


ALTER TABLE "public"."dn_iot_commands" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_iot_commands_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_iot_commands_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_iot_commands_id_seq" OWNED BY "public"."dn_iot_commands"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_iot_devices" (
    "client_id" "text",
    "name" "text",
    "config" "jsonb",
    "firmware_version" character varying(50),
    "status" "text" DEFAULT 'offline'::"text",
    "last_seen" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "token" "text",
    "owner_id" "uuid",
    "id" "text" NOT NULL,
    "first_seen" timestamp with time zone,
    "online_duration_ms" "text",
    "again_seen" timestamp with time zone,
    CONSTRAINT "dn_iot_devices_status_check" CHECK (("status" = ANY (ARRAY['online'::"text", 'offline'::"text"])))
);

ALTER TABLE ONLY "public"."dn_iot_devices" REPLICA IDENTITY FULL;


ALTER TABLE "public"."dn_iot_devices" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_iot_devices_device_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_iot_devices_device_id_seq" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_iot_electrician_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_iot_electrician_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_iot_sensor" (
    "id" bigint NOT NULL,
    "device_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sensor_type_id" integer,
    "payload" "jsonb",
    "mode" "text",
    CONSTRAINT "chk_mode" CHECK (("mode" = ANY (ARRAY['MANUAL'::"text", 'MINMAX'::"text", 'TIMER'::"text", 'TIMER_MINMAX'::"text", 'SENSOR'::"text"])))
);


ALTER TABLE "public"."dn_iot_sensor" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_iot_sensor_log_daily" (
    "id" integer NOT NULL,
    "device_id" "text",
    "created_date" timestamp without time zone DEFAULT "now"(),
    "amtemperatureavg" double precision,
    "amtemperaturemin" double precision,
    "amtemperaturemax" double precision,
    "pmtemperatureavg" double precision,
    "pmtemperaturemin" double precision,
    "pmtemperaturemax" double precision,
    "amsoilhumidity" double precision,
    "pmsoilhumidity" double precision,
    "amairhumidityavg" double precision,
    "amairhumiditymin" double precision,
    "amairhumiditymax" double precision,
    "pmairhumidityavg" double precision,
    "pmairhumiditymin" double precision,
    "pmairhumiditymax" double precision,
    "amwaterqty" double precision,
    "pmwaterqty" double precision,
    "tempmiddaymax" double precision,
    "tempmiddayavg" double precision,
    "rhmiddaymin" double precision,
    "rhmiddayavg" double precision
);


ALTER TABLE "public"."dn_iot_sensor_log_daily" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_iot_sensor_log_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_iot_sensor_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_iot_sensor_log_id_seq" OWNED BY "public"."dn_iot_sensor_log_daily"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."dn_iot_sensor_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_iot_sensor_logs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_iot_sensor_logs_id_seq" OWNED BY "public"."dn_iot_sensor"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_iot_sensor_types" (
    "id" integer NOT NULL,
    "name" "text",
    "unit" "text",
    "prefix" "text"
);


ALTER TABLE "public"."dn_iot_sensor_types" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_iot_supplier_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_iot_supplier_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_iot_supply_list" (
    "id" "text" DEFAULT ('FFI'::"text" || "lpad"(("nextval"('"public"."dn_iot_supplier_seq"'::"regclass"))::"text", 4, '0'::"text")) NOT NULL,
    "device_id" "text",
    "soil_sensor" boolean DEFAULT false,
    "air_sensor" boolean DEFAULT false,
    "relay" boolean DEFAULT false,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "address" "text",
    "number_device" "text",
    "serial_number" "text",
    "installed_device" boolean DEFAULT false,
    "created_at_install" timestamp with time zone,
    "latitude" double precision,
    "longitude" double precision,
    "supplier_id" "uuid",
    "electrician_id" "uuid",
    "sub_district_id" bigint,
    "installed_for" "text",
    "assemble_date" timestamp with time zone,
    "begin_assembly" boolean DEFAULT false,
    "status_assembly" boolean,
    "relay_detail" "jsonb" DEFAULT '{"0": false, "1": false, "2": false, "3": false}'::"jsonb"
);


ALTER TABLE "public"."dn_iot_supply_list" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_iot_supply_list_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_iot_supply_list_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_operations_chemical" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "app_oper_id" character varying(50) NOT NULL,
    "oper_date" "date" NOT NULL,
    "no_of_workers" integer NOT NULL,
    "worker_cost" numeric(12,2) NOT NULL,
    "petrol_cost" numeric(12,2) NOT NULL,
    "equipment_cost" numeric(12,2) NOT NULL,
    "fertilizer_cost" numeric(12,2) NOT NULL,
    "chemical_cost" numeric(12,2) NOT NULL,
    "chemicals" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "equipments" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_operations_chemical" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_operations_chemical_harvest" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "app_oper_id" character varying(50) NOT NULL,
    "oper_date" "date" NOT NULL,
    "harvest_lot_number" character varying(100) NOT NULL,
    "no_of_workers" integer NOT NULL,
    "worker_cost" numeric(12,2) NOT NULL,
    "petrol_cost" numeric(12,2) NOT NULL,
    "equipment_cost" numeric(12,2) NOT NULL,
    "fertilizer_cost" numeric(12,2) NOT NULL,
    "chemical_cost" numeric(12,2) NOT NULL,
    "chemicals" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "equipments" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_operations_chemical_harvest" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_operations_chemical_harvest_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_operations_chemical_harvest_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_operations_chemical_harvest_id_seq" OWNED BY "public"."dn_operations_chemical_harvest"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."dn_operations_chemical_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_operations_chemical_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_operations_chemical_id_seq" OWNED BY "public"."dn_operations_chemical"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_operations_fertilizing" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "app_oper_id" character varying(50) NOT NULL,
    "oper_date" "date" NOT NULL,
    "no_of_workers" integer NOT NULL,
    "worker_cost" numeric(12,2) NOT NULL,
    "petrol_cost" numeric(12,2) NOT NULL,
    "equipment_cost" numeric(12,2) NOT NULL,
    "fertilizer_cost" numeric(12,2) NOT NULL,
    "chemical_cost" numeric(12,2) NOT NULL,
    "fertilizers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "equipments" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_operations_fertilizing" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_operations_fertilizing_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_operations_fertilizing_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_operations_fertilizing_id_seq" OWNED BY "public"."dn_operations_fertilizing"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_operations_harvest" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "app_oper_id" character varying(50) NOT NULL,
    "oper_date" "date" NOT NULL,
    "lot_number" character varying(100) NOT NULL,
    "no_of_workers" integer,
    "worker_cost" numeric(12,2),
    "petrol_cost" numeric(12,2),
    "equipment_cost" numeric(12,2),
    "fertilizer_cost" numeric(12,2),
    "chemical_cost" numeric(12,2),
    "pct_harvest" numeric(5,2),
    "yield_kg" numeric(12,2) NOT NULL,
    "yield_baht" numeric(12,2) NOT NULL,
    "yield_baht_kg" numeric(12,2),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_operations_harvest" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_operations_harvest_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_operations_harvest_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_operations_harvest_id_seq" OWNED BY "public"."dn_operations_harvest"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_operations_pest_control" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "app_oper_id" character varying(50) NOT NULL,
    "oper_date" "date" NOT NULL,
    "no_of_workers" integer,
    "worker_cost" numeric(12,2),
    "petrol_cost" numeric(12,2),
    "equipment_cost" numeric(12,2),
    "fertilizer_cost" numeric(12,2),
    "carrier_type" character varying(100),
    "eliminate_method" character varying(100),
    "chemicals" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "equipments" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_operations_pest_control" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_operations_pest_control_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_operations_pest_control_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_operations_pest_control_id_seq" OWNED BY "public"."dn_operations_pest_control"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_operations_survey" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "app_oper_id" character varying(50) NOT NULL,
    "oper_date" "date" NOT NULL,
    "no_of_workers" integer,
    "worker_cost" numeric(12,2),
    "petrol_cost" numeric(12,2),
    "equipment_cost" numeric(12,2),
    "fertilizer_cost" numeric(12,2),
    "chemical_cost" numeric(12,2),
    "problem_type" character varying(100),
    "solution" "text",
    "chemicals" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "equipments" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."dn_operations_survey" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_operations_survey_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_operations_survey_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_operations_survey_id_seq" OWNED BY "public"."dn_operations_survey"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_operations_watering" (
    "id" integer NOT NULL,
    "app_crop_id" character varying(50) NOT NULL,
    "app_oper_id" character varying(50) NOT NULL,
    "oper_date" "date" NOT NULL,
    "no_of_workers" integer,
    "worker_cost" numeric(12,2),
    "petrol_cost" numeric(12,2),
    "equipment_cost" numeric(12,2),
    "fertilizer_cost" numeric(12,2),
    "chemical_cost" numeric(12,2),
    "start_time" timestamp with time zone,
    "end_time" timestamp with time zone,
    "watering_system" character varying(100),
    "water_amount" numeric(12,2) NOT NULL,
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "time_check" CHECK (("end_time" > "start_time"))
);


ALTER TABLE "public"."dn_operations_watering" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_operations_watering_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_operations_watering_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_operations_watering_id_seq" OWNED BY "public"."dn_operations_watering"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_cbf" (
    "cbf_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "app_crop_id" character varying,
    "user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."dn_tb_m_cbf" OWNER TO "postgres";


COMMENT ON TABLE "public"."dn_tb_m_cbf" IS 'Master table for carbon footprint records per crop';



CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_cbf_energy_ef" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ef_type" character varying NOT NULL,
    "fuel_type" character varying,
    "fuel_name_th" character varying,
    "ef_value" numeric NOT NULL,
    "ef_unit" character varying NOT NULL,
    "note" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "dn_tb_m_cbf_energy_ef_ef_type_check" CHECK ((("ef_type")::"text" = ANY ((ARRAY['electricity'::character varying, 'fuel'::character varying])::"text"[])))
);


ALTER TABLE "public"."dn_tb_m_cbf_energy_ef" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_cbf_transport_ef" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "vehicle_code" character varying NOT NULL,
    "vehicle_name_th" character varying,
    "fuel_type" character varying NOT NULL,
    "fuel_name_th" character varying,
    "loading_pct" numeric NOT NULL,
    "ef_value" numeric NOT NULL,
    "ef_unit" character varying NOT NULL,
    "note" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "dn_tb_m_cbf_transport_ef_loading_pct_check" CHECK (("loading_pct" = ANY (ARRAY[(0)::numeric, (50)::numeric, (75)::numeric, (100)::numeric])))
);


ALTER TABLE "public"."dn_tb_m_cbf_transport_ef" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_certify" (
    "certify_id" character varying(20) NOT NULL,
    "user_id" character varying(20) NOT NULL,
    "app_crop_id" character varying(20) NOT NULL,
    "app_land_id" character varying(20) NOT NULL,
    "cert_name" character varying(200) NOT NULL,
    "cert_type" character varying(50) DEFAULT 'GAP'::character varying,
    "cert_number" character varying(100),
    "cert_status" character varying(20) DEFAULT 'draft'::character varying,
    "application_date" "date",
    "issued_date" "date",
    "expiry_date" "date",
    "farm_name" character varying(100),
    "land_name" character varying(100),
    "crop_name" character varying(100),
    "breed_name" character varying(100),
    "total_area" numeric(10,2),
    "total_trees" integer,
    "total_worker_cost" numeric(12,2),
    "total_fertilizer_cost" numeric(12,2),
    "total_chemical_cost" numeric(12,2),
    "total_equipment_cost" numeric(12,2),
    "total_petrol_cost" numeric(12,2),
    "activities_summary" "jsonb",
    "document_url" "text",
    "document_filename" character varying(255),
    "document_size" integer,
    "document_type" character varying(50),
    "certification_data" "jsonb",
    "is_deleted" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "deleted_at" timestamp with time zone,
    CONSTRAINT "cert_dates_check" CHECK (((("issued_date" IS NULL) OR ("application_date" IS NULL) OR ("issued_date" >= "application_date")) AND (("expiry_date" IS NULL) OR ("issued_date" IS NULL) OR ("expiry_date" > "issued_date")))),
    CONSTRAINT "cert_status_check" CHECK ((("cert_status")::"text" = ANY ((ARRAY['draft'::character varying, 'submitted'::character varying, 'approved'::character varying, 'rejected'::character varying, 'expired'::character varying])::"text"[])))
);


ALTER TABLE "public"."dn_tb_m_certify" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_community" (
    "comm_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "comm_name" "text",
    "province" "text",
    "amphur" "text",
    "tambon" "text",
    "post_code" "text",
    "total_members" integer,
    "no_of_rais" numeric,
    "no_of_trees" numeric,
    "forecast_yield_kg" numeric,
    "crop_year" integer,
    "total_incentive" integer,
    "updated_at" timestamp with time zone,
    "user_id" "text" NOT NULL
);


ALTER TABLE "public"."dn_tb_m_community" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_community_memberships" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "farmer_id" "text",
    "comm_id" "text",
    "role" "text"
);


ALTER TABLE "public"."dn_tb_m_community_memberships" OWNER TO "postgres";


ALTER TABLE "public"."dn_tb_m_community_memberships" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."dn_tb_m_community_memberships_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_crop_stage" (
    "id" bigint NOT NULL,
    "stage_id" "text",
    "stage_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dn_tb_m_crop_stage" OWNER TO "postgres";


ALTER TABLE "public"."dn_tb_m_crop_stage" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."dn_tb_m_crop_stage_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_device_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "platform" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "dn_tb_m_device_tokens_platform_check" CHECK (("platform" = ANY (ARRAY['ios'::"text", 'android'::"text"])))
);


ALTER TABLE "public"."dn_tb_m_device_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_external_log" (
    "id" bigint NOT NULL,
    "function_name" character varying(255) NOT NULL,
    "operation_type" character varying(100) NOT NULL,
    "external_api_url" "text" NOT NULL,
    "request_payload" "jsonb",
    "response_payload" "jsonb",
    "error_message" "text",
    "status_code" integer,
    "success" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."dn_tb_m_external_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."dn_tb_m_external_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."dn_tb_m_external_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."dn_tb_m_external_log_id_seq" OWNED BY "public"."dn_tb_m_external_log"."id";



CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_farm" (
    "farm_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "farmer_id" "text",
    "address" "text",
    "tambon" "text",
    "amphur" "text",
    "province" "text",
    "latitude" double precision,
    "longitude" double precision
);


ALTER TABLE "public"."dn_tb_m_farm" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_iot_hubs" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dn_tb_m_iot_hubs" OWNER TO "postgres";


ALTER TABLE "public"."dn_tb_m_iot_hubs" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."dn_tb_m_iot_hubs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_land" (
    "land_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "land_type" "text",
    "farmer_id" "text",
    "latitude" double precision,
    "longitude" double precision,
    "latitude_degree" integer,
    "longitude_degree" integer,
    "longitude_minutes" integer,
    "latitude_minutes" integer,
    "latitude_seconds" double precision,
    "longitude_seconds" double precision,
    "latitude_direction" "text",
    "longitude_direction" "text",
    "kml" "text",
    "no_of_rais" integer,
    "no_of_ngan" integer,
    "no_of_wah" integer,
    "snapshot_path" "text",
    "land_name" "text",
    "geometry" "extensions"."geometry",
    "land_area" numeric(10,2) DEFAULT 0
);


ALTER TABLE "public"."dn_tb_m_land" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_land_type" (
    "id" bigint NOT NULL,
    "type_id" "text",
    "type_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dn_tb_m_land_type" OWNER TO "postgres";


ALTER TABLE "public"."dn_tb_m_land_type" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."dn_tb_m_land_type_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_news" (
    "news_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "province" "text" NOT NULL,
    "news_group" "text" NOT NULL,
    "news_topic" "text" NOT NULL,
    "news_detail" "text",
    "no_of_like" integer,
    "no_of_comment" integer,
    "user_id" "text",
    "news_url_pic" "text"
);


ALTER TABLE "public"."dn_tb_m_news" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_news_comment" (
    "comment_id" "text" NOT NULL,
    "news_id" "text" NOT NULL,
    "user_id" "text",
    "comment_text" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."dn_tb_m_news_comment" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_news_like" (
    "like_id" "text" NOT NULL,
    "news_id" "text" NOT NULL,
    "user_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."dn_tb_m_news_like" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "type" "text" DEFAULT 'system'::"text" NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "read_at" timestamp with time zone,
    CONSTRAINT "dn_tb_m_notifications_type_check" CHECK (("type" = ANY (ARRAY['activity'::"text", 'weather'::"text", 'price'::"text", 'system'::"text", 'news'::"text"])))
);


ALTER TABLE "public"."dn_tb_m_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_price" (
    "price_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "province" "text",
    "breed_name" "text",
    "price_date" "date",
    "price_per_kg" real,
    "data_source" "text"
);


ALTER TABLE "public"."dn_tb_m_price" OWNER TO "postgres";


COMMENT ON COLUMN "public"."dn_tb_m_price"."data_source" IS 'Source of the price data (e.g., manual entry, API, etc.)';



CREATE TABLE IF NOT EXISTS "public"."dn_tb_m_user" (
    "user_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "registration_number" "text",
    "registration_type" "text",
    "email" "text",
    "user_profile_name" "text"
);


ALTER TABLE "public"."dn_tb_m_user" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dn_tb_r_cbf_chemical" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cbf_id" "uuid",
    "app_crop_id" character varying,
    "app_chem_cbf_id" character varying NOT NULL,
    "chemical_code" character varying,
    "commercial_name" character varying,
    "unit_code" character varying,
    "stock_amount" numeric,
    "vehicle_code" character varying,
    "loading_pct" numeric,
    "distance" numeric,
    "fuel_type" character varying,
    "stock_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."dn_tb_r_cbf_chemical" OWNER TO "postgres";


COMMENT ON TABLE "public"."dn_tb_r_cbf_chemical" IS 'Relation table for chemical carbon footprint records';



CREATE TABLE IF NOT EXISTS "public"."dn_tb_r_cbf_electric" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cbf_id" "uuid",
    "app_crop_id" character varying,
    "app_elec_cbf_id" character varying NOT NULL,
    "kwh" numeric,
    "bill_date" "date",
    "pct_oper1" numeric DEFAULT 0,
    "pct_oper2" numeric DEFAULT 0,
    "pct_oper3" numeric DEFAULT 0,
    "pct_oper4" numeric DEFAULT 0,
    "pct_oper5" numeric DEFAULT 0,
    "pct_oper6" numeric DEFAULT 0,
    "pct_oper7" numeric DEFAULT 0,
    "pct_oper8" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."dn_tb_r_cbf_electric" OWNER TO "postgres";


COMMENT ON TABLE "public"."dn_tb_r_cbf_electric" IS 'Relation table for electric carbon footprint records';



CREATE TABLE IF NOT EXISTS "public"."dn_tb_r_cbf_fertilizer" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cbf_id" "uuid",
    "app_crop_id" character varying,
    "app_fert_cbf_id" character varying NOT NULL,
    "fert_type" character varying,
    "commercial_name" character varying,
    "formula_n" numeric,
    "formula_p" numeric,
    "formula_k" numeric,
    "unit_code" character varying,
    "stock_amount" numeric,
    "vehicle_code" character varying,
    "loading_pct" numeric,
    "distance" numeric,
    "fuel_type" character varying,
    "stock_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."dn_tb_r_cbf_fertilizer" OWNER TO "postgres";


COMMENT ON TABLE "public"."dn_tb_r_cbf_fertilizer" IS 'Relation table for fertilizer carbon footprint records';



CREATE TABLE IF NOT EXISTS "public"."dn_tb_r_cbf_fuel" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cbf_id" "uuid",
    "app_crop_id" character varying,
    "app_fuel_cbf_id" character varying NOT NULL,
    "litres" numeric,
    "distance" numeric,
    "fuel_type" character varying,
    "bill_date" "date",
    "pct_oper1" numeric DEFAULT 0,
    "pct_oper2" numeric DEFAULT 0,
    "pct_oper3" numeric DEFAULT 0,
    "pct_oper4" numeric DEFAULT 0,
    "pct_oper5" numeric DEFAULT 0,
    "pct_oper6" numeric DEFAULT 0,
    "pct_oper7" numeric DEFAULT 0,
    "pct_oper8" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."dn_tb_r_cbf_fuel" OWNER TO "postgres";


COMMENT ON TABLE "public"."dn_tb_r_cbf_fuel" IS 'Relation table for fuel carbon footprint records';



CREATE TABLE IF NOT EXISTS "public"."dn_tb_r_cbf_material" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cbf_id" "uuid",
    "app_crop_id" character varying,
    "app_mate_cbf_id" character varying NOT NULL,
    "material_code" character varying,
    "unit_code" character varying,
    "stock_amount" numeric,
    "vehicle_code" character varying,
    "loading_pct" numeric,
    "distance" numeric,
    "fuel_type" character varying,
    "stock_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."dn_tb_r_cbf_material" OWNER TO "postgres";


COMMENT ON TABLE "public"."dn_tb_r_cbf_material" IS 'Relation table for material carbon footprint records';



CREATE TABLE IF NOT EXISTS "public"."factor_detail" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "stock_id" "uuid",
    "factor_name" "text",
    "factor_commercial_name" "text",
    "factor_amount" numeric,
    "factor_unit" "text",
    "date" timestamp with time zone,
    "total_cost" numeric,
    "fertilizer_detail" "jsonb"
);


ALTER TABLE "public"."factor_detail" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."factor_stock" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cycle_id" "uuid",
    "factor_type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "app_crop_id" character varying
);


ALTER TABLE "public"."factor_stock" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."farm" (
    "id" bigint NOT NULL,
    "type_id" bigint,
    "address" "text",
    "name" "text" NOT NULL,
    "area_size" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "group" bigint,
    "sub_district_id" bigint,
    "status" boolean DEFAULT true,
    "snapshot_url" "text",
    "title_deed_no" "text",
    "create_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "update_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ha_bridge_id" "uuid",
    "geometry" "extensions"."geometry",
    "quota" boolean DEFAULT false,
    "traceable" boolean DEFAULT true,
    "village_name" "text",
    "moo" "text",
    "road" "text",
    "soi" "text"
);


ALTER TABLE "public"."farm" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."farm_group" (
    "id" bigint NOT NULL,
    "name" "text",
    "user_id" "uuid"
);


ALTER TABLE "public"."farm_group" OWNER TO "postgres";


ALTER TABLE "public"."farm_group" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."farm_group_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."farm" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."farm_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."farm_type" (
    "id" bigint NOT NULL,
    "category" character varying NOT NULL,
    "type" character varying NOT NULL,
    "subtype" character varying,
    "metadata" "json",
    "group" "uuid",
    "duration" bigint,
    "yield_per_sqm" double precision
);


ALTER TABLE "public"."farm_type" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."group" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "admin_id" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "phone" "text",
    "email" "text",
    "contact" "text",
    "address" "text",
    "biography" "text",
    "about" "text",
    "group_img_path" "text",
    "banner_img_path" "text"
);


ALTER TABLE "public"."group" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ha_bridges" (
    "id" "uuid" NOT NULL,
    "name" "text",
    "owner_id" "uuid" NOT NULL,
    "shared_to" "uuid"[] DEFAULT ARRAY[]::"uuid"[],
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."ha_bridges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ha_command" (
    "bridge_id" "uuid" NOT NULL,
    "command" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ha_command" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ha_entities" (
    "bridge_id" "uuid" NOT NULL,
    "entity_id" "text" NOT NULL,
    "state_ref" "uuid" NOT NULL,
    "current_state" "text",
    "state_attr" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."ha_entities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ha_states" (
    "id" bigint NOT NULL,
    "state_ref" "uuid" NOT NULL,
    "state" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ha_states" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ha_states_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."ha_states_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ha_states_id_seq" OWNED BY "public"."ha_states"."id";



CREATE TABLE IF NOT EXISTS "public"."harvest" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "create_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "amount" double precision NOT NULL,
    "farm_id" bigint NOT NULL,
    "date" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."harvest" OWNER TO "postgres";


ALTER TABLE "public"."harvest" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."harvest_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."maintenance" (
    "id" bigint NOT NULL,
    "is_maintenance_active" boolean NOT NULL,
    "message" "text",
    "version" "text",
    "timeframe" "text"
);


ALTER TABLE "public"."maintenance" OWNER TO "postgres";


COMMENT ON TABLE "public"."maintenance" IS 'mobile application maintenance';



ALTER TABLE "public"."maintenance" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."maintenance_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."master_bank_list" (
    "bank_name" "text" NOT NULL,
    "bank_acronyms" character varying NOT NULL,
    "img_path" "text"
);


ALTER TABLE "public"."master_bank_list" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_delivery_type" (
    "id" bigint NOT NULL,
    "name" "text",
    "description" "text"
);


ALTER TABLE "public"."master_delivery_type" OWNER TO "postgres";


ALTER TABLE "public"."master_delivery_type" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."master_delivery_type_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."master_product_category" (
    "category_id" bigint NOT NULL,
    "category_name" "text" NOT NULL,
    "img_path" "text"
);


ALTER TABLE "public"."master_product_category" OWNER TO "postgres";


ALTER TABLE "public"."master_product_category" ALTER COLUMN "category_id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."master_product_category_category_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."master_product_type" (
    "product_id" bigint NOT NULL,
    "product_name" "text" NOT NULL,
    "category_id" bigint
);


ALTER TABLE "public"."master_product_type" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_basket" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "selected_address" "uuid"
);


ALTER TABLE "public"."mp_basket" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_basket_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "basket_id" "uuid" DEFAULT "gen_random_uuid"(),
    "product_variant_id" bigint,
    "quantity" bigint DEFAULT '1'::bigint,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mp_basket_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_chat_members" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "member_id" "uuid" NOT NULL,
    "chat_room_id" "uuid" NOT NULL
);


ALTER TABLE "public"."mp_chat_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_chat_message_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "message_id" "uuid" NOT NULL,
    "attachment_type" "public"."mp_attachment_type" NOT NULL,
    "storage_path" "text",
    "mime_type" "text",
    "order_id" "uuid",
    "product_id" "uuid",
    CONSTRAINT "mp_chat_attach_image_mime_check" CHECK ((("attachment_type" <> 'image'::"public"."mp_attachment_type") OR (("mime_type" IS NOT NULL) AND ("mime_type" ~~ 'image/%'::"text"))))
);


ALTER TABLE "public"."mp_chat_message_attachments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_chat_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "text" "text",
    "chat_room_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "message_type" "public"."mp_message_type" DEFAULT 'text'::"public"."mp_message_type" NOT NULL,
    CONSTRAINT "mp_chat_message_text_required_when_text" CHECK ((("message_type" <> 'text'::"public"."mp_message_type") OR (("text" IS NOT NULL) AND ("length"(TRIM(BOTH FROM "text")) > 0))))
);


ALTER TABLE "public"."mp_chat_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_chat_room_reads" (
    "chat_room_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "last_read_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mp_chat_room_reads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_chat_rooms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL,
    "buyer_id" "uuid" NOT NULL,
    "seller_id" "uuid" NOT NULL,
    "last_message_at" timestamp with time zone
);


ALTER TABLE "public"."mp_chat_rooms" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_delivery_method" (
    "delivery_method_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shop_id" "uuid" NOT NULL,
    "method_name" "text" NOT NULL,
    "transit_days" integer NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "mp_delivery_method_transit_days_check" CHECK (("transit_days" > 0))
);


ALTER TABLE "public"."mp_delivery_method" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_delivery_rate" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "delivery_method_id" "uuid" NOT NULL,
    "from_kg" numeric(10,3) NOT NULL,
    "to_kg" numeric(10,3),
    "delivery_cost" numeric(12,2) NOT NULL,
    "weight_range" "numrange" GENERATED ALWAYS AS ("numrange"("from_kg", "to_kg", '[)'::"text")) STORED,
    CONSTRAINT "mp_delivery_rate_check" CHECK ((("to_kg" IS NULL) OR ("to_kg" > "from_kg"))),
    CONSTRAINT "mp_delivery_rate_delivery_cost_check" CHECK (("delivery_cost" >= (0)::numeric)),
    CONSTRAINT "mp_delivery_rate_from_kg_check" CHECK (("from_kg" >= (0)::numeric))
);


ALTER TABLE "public"."mp_delivery_rate" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_order_disputes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid",
    "shop_id" "uuid",
    "customer_id" "uuid",
    "reason_type" "text",
    "description" "text",
    "evidence_img_paths" "text"[],
    "status" "text" DEFAULT 'OPEN'::"text",
    "admin_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "resolved_at" timestamp with time zone,
    "internal_notes" "text",
    "public_resolution" "text",
    "final_decision_by" "uuid"
);


ALTER TABLE "public"."mp_order_disputes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_order_items" (
    "id" bigint NOT NULL,
    "order_id" "uuid",
    "product_variant_id" bigint,
    "quantity" bigint,
    "unit_price_base" numeric DEFAULT 0 NOT NULL,
    "per_unit_discount_applied" numeric DEFAULT 0 NOT NULL,
    "limit_qty_per_order_applied" bigint,
    "discounted_units" bigint DEFAULT 0 NOT NULL,
    "full_price_units" bigint DEFAULT 0 NOT NULL,
    "line_subtotal_base" numeric DEFAULT 0 NOT NULL,
    "line_discount_total" numeric DEFAULT 0 NOT NULL,
    "line_total_after_discount" numeric DEFAULT 0 NOT NULL,
    "product_name_snapshot" "text",
    "variant_name_snapshot" "text",
    "product_img_path_snapshot" "text"
);


ALTER TABLE "public"."mp_order_items" OWNER TO "postgres";


ALTER TABLE "public"."mp_order_items" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."mp_order_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."mp_order_notification_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "reminder_level" smallint NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "mp_order_notification_log_reminder_level_check" CHECK (("reminder_level" = ANY (ARRAY[1, 2, 3])))
);


ALTER TABLE "public"."mp_order_notification_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."mp_order_notification_log" IS 'Tracks which LINE shipping reminder (level 1/2/3) has been sent per order. Used by notify-seller-ship edge function to prevent duplicate notifications.';



COMMENT ON COLUMN "public"."mp_order_notification_log"."reminder_level" IS '1 = gentle reminder (50% of transit_days elapsed), 2 = urgent nudge (75%), 3 = final warning with cancellation threat (90%).';



CREATE TABLE IF NOT EXISTS "public"."mp_order_sales" (
    "order_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "customer_id" "uuid",
    "shop_id" "uuid",
    "payment_status" "text" DEFAULT 'pending'::"text",
    "paid_at" timestamp with time zone,
    "payment_img_path" "text",
    "delivery_method_name" "text",
    "transit_days" bigint,
    "delivery_cost" numeric(12,2) DEFAULT 0 NOT NULL,
    "order_code" "text" NOT NULL,
    "selected_address_snapshot" "jsonb" DEFAULT '{}'::"jsonb",
    "shipping_proof_img_path" "text",
    "qrcode_url" "text",
    "confirmed_at" timestamp with time zone,
    "cancelled_at" timestamp with time zone,
    "refund_requested_at" timestamp with time zone,
    "refunded_at" timestamp with time zone,
    "total_cost" numeric,
    "shipped_at" timestamp with time zone,
    "transferable_at" timestamp with time zone,
    "payout_amount" numeric(12,2),
    "commission_amount" numeric(12,2),
    "omise_fee" numeric(12,2),
    "payout_status" "text" DEFAULT 'on_hold'::"text",
    "payout_log_id" "uuid",
    "commission_status" "text" DEFAULT 'pending'::"text",
    "platform_payout_log_id" "uuid",
    "completed_at" timestamp with time zone,
    "disputed_at" timestamp with time zone
);


ALTER TABLE "public"."mp_order_sales" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."mp_order_sales_code_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."mp_order_sales_code_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_payment_method" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shop_id" "uuid" NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_primary" boolean DEFAULT false NOT NULL,
    "verified" boolean
);


ALTER TABLE "public"."mp_payment_method" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_payout_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shop_id" "uuid",
    "omise_transfer_id" "text",
    "gross_amount" numeric(12,2),
    "transfer_fee" numeric(10,2),
    "net_amount" numeric(12,2),
    "status" "text" DEFAULT 'pending'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."mp_payout_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_platform_payout_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "omise_transfer_id" "text",
    "amount" numeric(12,2),
    "transfer_fee" numeric(10,2),
    "net_received" numeric(12,2),
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."mp_platform_payout_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_product" (
    "product_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "product_name" "text" NOT NULL,
    "product_category" bigint,
    "shop_id" "uuid",
    "img_path" "text",
    "product_detail" "text",
    "is_available" boolean NOT NULL,
    "gallery_paths" "text"[] DEFAULT '{}'::"text"[],
    "is_pre_order" boolean DEFAULT false NOT NULL,
    "deleted_at" timestamp with time zone
);


ALTER TABLE "public"."mp_product" OWNER TO "postgres";


COMMENT ON COLUMN "public"."mp_product"."product_name" IS 'ชื่อสินค้า';



CREATE TABLE IF NOT EXISTS "public"."mp_product_delivery_config" (
    "product_id" "uuid" NOT NULL,
    "delivery_method_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."mp_product_delivery_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_product_variant" (
    "id" bigint NOT NULL,
    "product_id" "uuid",
    "variant_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "variant_weight_value" numeric,
    "price_per_unit" numeric,
    "stock_quantity" bigint,
    "is_active" boolean DEFAULT true NOT NULL,
    "deleted_at" timestamp with time zone,
    "img_path" "text"
);


ALTER TABLE "public"."mp_product_variant" OWNER TO "postgres";


ALTER TABLE "public"."mp_product_variant" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."mp_product_variant_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."mp_promotion" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shop_id" "uuid" NOT NULL,
    "promotion_name" "text" NOT NULL,
    "start_at" timestamp with time zone NOT NULL,
    "end_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mp_promotion" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_promotion_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "promotion_id" "uuid" NOT NULL,
    "product_variant_id" integer NOT NULL,
    "discount_amount" numeric(12,2) NOT NULL,
    "limit_qty_per_order" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "mp_promotion_products_discount_amount_check" CHECK (("discount_amount" >= (0)::numeric)),
    CONSTRAINT "mp_promotion_products_limit_qty_per_order_check" CHECK (("limit_qty_per_order" >= 0))
);


ALTER TABLE "public"."mp_promotion_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_review_media" (
    "id" bigint NOT NULL,
    "review_id" bigint NOT NULL,
    "media_path" "text" NOT NULL,
    "media_type" "public"."review_media_type" NOT NULL,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mp_review_media" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."mp_review_media_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."mp_review_media_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."mp_review_media_id_seq" OWNED BY "public"."mp_review_media"."id";



CREATE TABLE IF NOT EXISTS "public"."mp_reviews" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "subject_type" "public"."review_subject" NOT NULL,
    "product_variant_id" bigint,
    "shop_id" "uuid",
    "rating" real NOT NULL,
    "detail" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone,
    CONSTRAINT "chk_subject_rules" CHECK (((("subject_type" = 'product'::"public"."review_subject") AND ("product_variant_id" IS NOT NULL)) OR (("subject_type" = 'shop'::"public"."review_subject") AND ("shop_id" IS NOT NULL) AND ("product_variant_id" IS NULL)))),
    CONSTRAINT "mp_reviews_rating_check" CHECK ((("rating" >= ((1)::numeric)::double precision) AND ("rating" <= ((5)::numeric)::double precision)))
);


ALTER TABLE "public"."mp_reviews" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."mp_reviews_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."mp_reviews_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."mp_reviews_id_seq" OWNED BY "public"."mp_reviews"."id";



CREATE TABLE IF NOT EXISTS "public"."mp_seller_violations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shop_id" "uuid",
    "order_id" "uuid",
    "violation_type" "text",
    "strike_points" integer DEFAULT 1,
    "details" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."mp_seller_violations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_shop_address" (
    "shop_id" "uuid" NOT NULL,
    "province" "text",
    "district" "text",
    "sub_district" "text",
    "postcode" "text",
    "address_detail" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sub_district_id" bigint
);


ALTER TABLE "public"."mp_shop_address" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_shop_payment" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_name" "text" NOT NULL,
    "account_no" character varying NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "bank_code" "text" NOT NULL,
    "qr_img_path" "text",
    "bank_account_page_img_path" "text",
    "national_id_img_path" "text"
);


ALTER TABLE "public"."mp_shop_payment" OWNER TO "postgres";


COMMENT ON COLUMN "public"."mp_shop_payment"."bank_account_page_img_path" IS 'หน้าสมุดบัญชีธนาคาร';



CREATE TABLE IF NOT EXISTS "public"."mp_shop_province" (
    "shop_id" "uuid" NOT NULL,
    "province_id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mp_shop_province" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_tb_m_dispute_reason" (
    "id" bigint NOT NULL,
    "value" "text",
    "label_en" "text",
    "label_th" "text"
);


ALTER TABLE "public"."mp_tb_m_dispute_reason" OWNER TO "postgres";


ALTER TABLE "public"."mp_tb_m_dispute_reason" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."mp_tb_m_dispute_reason_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."mp_tb_m_order_status" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "value" "text",
    "label_en" "text",
    "label_th" "text"
);


ALTER TABLE "public"."mp_tb_m_order_status" OWNER TO "postgres";


ALTER TABLE "public"."mp_tb_m_order_status" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."mp_tb_m_order_status_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."mp_tb_user_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "login_at" timestamp with time zone DEFAULT "now"(),
    "logout_at" timestamp with time zone,
    "user_id" "uuid" NOT NULL
);


ALTER TABLE "public"."mp_tb_user_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mp_user_address" (
    "address_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "address" "text" NOT NULL,
    "is_primary" boolean NOT NULL,
    "receiver_name" "text" NOT NULL,
    "receiver_phone" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "sub_district_id" bigint
);


ALTER TABLE "public"."mp_user_address" OWNER TO "postgres";


COMMENT ON TABLE "public"."mp_user_address" IS 'address for users used for marketplace module';



CREATE TABLE IF NOT EXISTS "public"."mp_user_daily_summary" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "marketplace_depa_register_id" "text" NOT NULL,
    "summary_date" "date" NOT NULL,
    "login_count" integer DEFAULT 0,
    "total_minutes" numeric DEFAULT 0,
    "sent_to_external" boolean DEFAULT false,
    "sent_at" timestamp with time zone
);


ALTER TABLE "public"."mp_user_daily_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."news" (
    "id" bigint NOT NULL,
    "news_type" "text" DEFAULT ''::"text",
    "author" "text",
    "title" "text",
    "url" "text",
    "url_image" "text",
    "published_date" timestamp with time zone
);


ALTER TABLE "public"."news" OWNER TO "postgres";


COMMENT ON TABLE "public"."news" IS 'news from https://doaenews.doae.go.th/';



ALTER TABLE "public"."news" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."news_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."notification" (
    "id" bigint NOT NULL,
    "user_id" "uuid"[],
    "heading" character varying,
    "message" character varying,
    "status" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notification" OWNER TO "postgres";


ALTER TABLE "public"."notification" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."notification_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."order_history_file" (
    "id" bigint NOT NULL,
    "file_path" character varying,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "group" "uuid" DEFAULT "gen_random_uuid"()
);


ALTER TABLE "public"."order_history_file" OWNER TO "postgres";


ALTER TABLE "public"."order_history_file" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."order_history_file_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "bank_name" "text"
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plant_cycle" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "land_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "active" boolean DEFAULT true
);


ALTER TABLE "public"."plant_cycle" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tb_m_planting_cycles" (
    "cycle_id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "area_usage_rai" bigint NOT NULL,
    "crop_age" bigint,
    "crop_age_unit" "text",
    "crop_name" "text",
    "total_trees" bigint,
    "growth_month_start" smallint,
    "growth_month_end" smallint,
    "harvest_month_start" smallint,
    "harvest_month_end" smallint,
    "expected_annual_yield" bigint,
    "farm_id" bigint,
    "cycle_name" "text" NOT NULL,
    "farm_type_id" bigint
);


ALTER TABLE "public"."tb_m_planting_cycles" OWNER TO "postgres";


COMMENT ON TABLE "public"."tb_m_planting_cycles" IS 'รอบการเพาะปลูกของ farmfeed เขียว';



ALTER TABLE "public"."tb_m_planting_cycles" ALTER COLUMN "cycle_id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."planting_cycles_cycle_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."farm_type" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."plot_type_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."pre_activity" (
    "id" bigint NOT NULL,
    "type" bigint,
    "user_id" "uuid" DEFAULT "gen_random_uuid"(),
    "amount" bigint DEFAULT '0'::bigint,
    "farm_type" bigint,
    "date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "create_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "note" character varying,
    "status" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."pre_activity" OWNER TO "postgres";


ALTER TABLE "public"."pre_activity" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."pre_activity_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."product" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "shop_id" "uuid",
    "farm_id" bigint,
    "name" "text",
    "detail" "json",
    "status" boolean DEFAULT true,
    "categories" "text",
    "img_path" "text"[],
    "shipping" "json"
);


ALTER TABLE "public"."product" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_option" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "product_id" "uuid",
    "name" "text",
    "detail" "json",
    "price" integer,
    "img_path" "text",
    "unit" "text",
    "stock" integer,
    "total_sale" integer,
    "status" boolean DEFAULT true
);


ALTER TABLE "public"."product_option" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profile" (
    "id" "uuid" NOT NULL,
    "first_name" character varying DEFAULT ''::character varying NOT NULL,
    "last_name" character varying DEFAULT ''::character varying NOT NULL,
    "address" "text",
    "create_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "update_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "img_path" "text",
    "status" boolean DEFAULT true NOT NULL,
    "sub_district_id" bigint,
    "group" "uuid",
    "phone" "text",
    "email" character varying,
    "id_card" "text",
    "username" character varying(20),
    "username_update_date" timestamp with time zone,
    "farm_type_category" "public"."profile_farm_type_category" DEFAULT 'พืช'::"public"."profile_farm_type_category" NOT NULL,
    "farmer_id" character varying,
    "farmer_id_register_date" "date",
    "date_of_birth" "date",
    "house_id" character varying,
    "default_lat" double precision,
    "default_lon" double precision,
    "prefix" "public"."profile_name_prefix",
    "line_id" character varying,
    "gender" "text",
    "id_card_expiry_dt" "date",
    "dn_app_id" "text",
    "license_active" boolean DEFAULT false NOT NULL,
    "line_user_id" "text",
    "user_level" bigint,
    "is_mp_buyer_profile_complete" boolean,
    "is_mp_refund_terms_accepted" boolean,
    "mp_refund_terms_accepted_at" timestamp with time zone,
    "refresh_token" "text",
    "pin_hash" "text",
    "is_iot_installation_profile_completed" boolean DEFAULT false NOT NULL,
    "marketplace_depa_register_id" "text",
    "is_mp_seller_profile_complete" boolean DEFAULT false NOT NULL,
    CONSTRAINT "check_username" CHECK ((("username")::"text" ~ '^[a-z0-9_.]*$'::"text"))
);


ALTER TABLE "public"."profile" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profile"."license_active" IS 'Use for manage user license account';



COMMENT ON COLUMN "public"."profile"."pin_hash" IS 'Hashed 6-digit PIN for login without OTP';



COMMENT ON COLUMN "public"."profile"."marketplace_depa_register_id" IS 'This Column store  register id created by Depa Supposed to be inserted By Depa Users';



CREATE TABLE IF NOT EXISTS "public"."province" (
    "id" bigint NOT NULL,
    "province_th" "text" NOT NULL,
    "province_en" "text",
    "region_name" "text"
);


ALTER TABLE "public"."province" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quota" (
    "id" bigint NOT NULL,
    "user_id" "uuid" DEFAULT "gen_random_uuid"(),
    "meeting_date" "date",
    "delivery_round" character varying[],
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "group" "uuid" DEFAULT "gen_random_uuid"()
);


ALTER TABLE "public"."quota" OWNER TO "postgres";


ALTER TABLE "public"."quota" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."quota_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."quota_item" (
    "id" bigint NOT NULL,
    "quota_id" bigint,
    "farm_type_id" bigint,
    "amount" double precision,
    "start_date" "date",
    "area_size" double precision,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "farm_id" bigint
);


ALTER TABLE "public"."quota_item" OWNER TO "postgres";


ALTER TABLE "public"."quota_item" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."quota_item_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."result" (
    "json_agg" "json"
);


ALTER TABLE "public"."result" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shop" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid",
    "name" "text",
    "detail" "text",
    "address" "text",
    "phone" "text",
    "line_id" "text",
    "account_name" "text",
    "img_path" "text",
    "banner_img_path" "text",
    "subscribe" boolean DEFAULT false NOT NULL,
    "sub_district_id" bigint,
    "omise_recipient_id" "text",
    "total_strike_points" integer DEFAULT 0,
    "is_blacklisted" boolean DEFAULT false,
    "blacklist_reason" "text",
    "blacklisted_at" timestamp with time zone
);


ALTER TABLE "public"."shop" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."shop_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."shop_id_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."standard" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type_id" bigint NOT NULL,
    "detail" "json" NOT NULL,
    "file_path" "text" NOT NULL,
    "create_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "update_date" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."standard" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."standard_type" (
    "id" bigint NOT NULL,
    "name" "text",
    "metadata" "json"
);


ALTER TABLE "public"."standard_type" OWNER TO "postgres";


ALTER TABLE "public"."standard_type" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."standard_type_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."sub_district" (
    "id" bigint NOT NULL,
    "tam_id" bigint,
    "tambon_en" "text",
    "tambon_th" "text",
    "amphoe_en" "text",
    "amphoe_th" "text",
    "province_en" "text",
    "province_th" "text",
    "amp_id" bigint,
    "pro_id" bigint,
    "postcode" bigint,
    "geom" "extensions"."geometry",
    "region_name" "text"
);


ALTER TABLE "public"."sub_district" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tb_h_wallet" (
    "amount" bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reward_id" bigint,
    "paid_at" timestamp with time zone,
    "is_increment" boolean DEFAULT true,
    "transaction_id" "uuid",
    "note" "text",
    "wallet_id" bigint NOT NULL
);


ALTER TABLE "public"."tb_h_wallet" OWNER TO "postgres";


ALTER TABLE "public"."tb_h_wallet" ALTER COLUMN "wallet_id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tb_h_wallet_wallet_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tb_m_license" (
    "id" bigint NOT NULL,
    "license_key" character varying,
    "license_type" bigint,
    "user_id" "uuid",
    "expiration_date" "date",
    "is_active" boolean,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."tb_m_license" OWNER TO "postgres";


ALTER TABLE "public"."tb_m_license" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tb_m_license_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tb_m_mp_boost_plan" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "duration_hours" integer NOT NULL,
    "points_cost" bigint NOT NULL,
    "max_products_per_slot" integer DEFAULT 1,
    "priority_weight" integer DEFAULT 1,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."tb_m_mp_boost_plan" OWNER TO "postgres";


ALTER TABLE "public"."tb_m_mp_boost_plan" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tb_m_mp_boost_plan_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tb_m_partners" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."tb_m_partners" OWNER TO "postgres";


ALTER TABLE "public"."tb_m_partners" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tb_m_partners_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tb_m_product_boost" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "shop_id" "uuid" NOT NULL,
    "wallet_id" bigint NOT NULL,
    "boost_plan_id" bigint NOT NULL,
    "points_spent" bigint NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "boost_slot" "text" DEFAULT 'homepage'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "cancelled_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."tb_m_product_boost" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tb_m_reward" (
    "id" bigint NOT NULL,
    "title" "text",
    "distributed_amount" bigint,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expired_at" timestamp with time zone
);


ALTER TABLE "public"."tb_m_reward" OWNER TO "postgres";


ALTER TABLE "public"."tb_m_reward" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tb_m_reward_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tb_m_wallet" (
    "id" bigint NOT NULL,
    "user_id" "uuid",
    "wallet_type" character varying,
    "balance" bigint DEFAULT '0'::bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "partners" "text"[],
    "partner_balance" bigint DEFAULT '0'::bigint
);


ALTER TABLE "public"."tb_m_wallet" OWNER TO "postgres";


ALTER TABLE "public"."tb_m_wallet" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tb_m_wallet_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tb_r_wallet_type" (
    "id" bigint NOT NULL,
    "type" character varying,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."tb_r_wallet_type" OWNER TO "postgres";


ALTER TABLE "public"."tb_r_wallet_type" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tb_m_wallet_type_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tb_r_license_type" (
    "id" bigint NOT NULL,
    "name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "description" "text",
    "tier_level" integer DEFAULT 1,
    "tier_name" character varying(50) DEFAULT 'FREE'::character varying
);


ALTER TABLE "public"."tb_r_license_type" OWNER TO "postgres";


ALTER TABLE "public"."tb_r_license_type" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tb_r_license_type_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."traceback" (
    "id" bigint NOT NULL,
    "farm_id" bigint,
    "dn_crop_id" "text",
    "show_personal_detail" boolean DEFAULT false,
    "show_farm_detail" boolean DEFAULT false,
    "show_crop_detail" boolean DEFAULT false,
    "show_activity_detail" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "traceback_farm_or_crop_check" CHECK (((("farm_id" IS NOT NULL) AND ("dn_crop_id" IS NULL)) OR (("farm_id" IS NULL) AND ("dn_crop_id" IS NOT NULL))))
);


ALTER TABLE "public"."traceback" OWNER TO "postgres";


ALTER TABLE "public"."traceback" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."traceback_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."transaction_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."transaction_id_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ty_commands" (
    "id" bigint NOT NULL,
    "time" timestamp with time zone DEFAULT "now"() NOT NULL,
    "device_id" "text" NOT NULL,
    "command" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."ty_commands" OWNER TO "postgres";


COMMENT ON COLUMN "public"."ty_commands"."command" IS 'example: {"name": "valve", "action": "on"}';



CREATE SEQUENCE IF NOT EXISTS "public"."ty_commands_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."ty_commands_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ty_commands_id_seq" OWNED BY "public"."ty_commands"."id";



CREATE TABLE IF NOT EXISTS "public"."ty_devices" (
    "id" "text" NOT NULL,
    "owner_id" "uuid",
    "metadata" "jsonb" DEFAULT '{"valve": ["วาล์ว"]}'::"jsonb",
    "notes" integer,
    "related_id" "text"[]
);


ALTER TABLE "public"."ty_devices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ty_sensor_detail" (
    "id" bigint NOT NULL,
    "sensor_id" "text",
    "sensor_title" "text" DEFAULT ''::"text",
    "device_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone
);


ALTER TABLE "public"."ty_sensor_detail" OWNER TO "postgres";


ALTER TABLE "public"."ty_sensor_detail" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."ty_sensor_detail_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."ty_sensor_types" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "unit" "text",
    "prefix" "text"
);


ALTER TABLE "public"."ty_sensor_types" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ty_sensor_types_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."ty_sensor_types_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ty_sensor_types_id_seq" OWNED BY "public"."ty_sensor_types"."id";



CREATE TABLE IF NOT EXISTS "public"."ty_sensors" (
    "id" bigint NOT NULL,
    "time" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sensor_name" "text" NOT NULL,
    "sensor_type_id" integer,
    "device_id" "text" NOT NULL,
    "value" real
);


ALTER TABLE "public"."ty_sensors" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ty_sensors_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."ty_sensors_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ty_sensors_id_seq" OWNED BY "public"."ty_sensors"."id";



CREATE TABLE IF NOT EXISTS "public"."user_levels" (
    "user_level" bigint NOT NULL,
    "name" character varying
);


ALTER TABLE "public"."user_levels" OWNER TO "postgres";


ALTER TABLE "public"."user_levels" ALTER COLUMN "user_level" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."user_levels_level_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."user_log" (
    "id" bigint NOT NULL,
    "action_table" character varying,
    "action" character varying,
    "created_date" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid"
);


ALTER TABLE "public"."user_log" OWNER TO "postgres";


ALTER TABLE "public"."user_log" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."user_log_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."user_permissions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "user_level" integer DEFAULT 1 NOT NULL,
    "user_role" integer DEFAULT 1 NOT NULL,
    "user_subscription" integer DEFAULT 1,
    "expired_date" "date"
);


ALTER TABLE "public"."user_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_subscription" (
    "id" integer NOT NULL,
    "name" "text",
    "access_right" "jsonb"
);


ALTER TABLE "public"."user_subscription" OWNER TO "postgres";


ALTER TABLE "public"."user_subscription" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."user_subscription_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."v_user_license" AS
 SELECT "p"."id" AS "user_id",
    "p"."user_level",
    COALESCE("lt"."tier_name", 'FREE'::character varying) AS "license_tier",
    COALESCE("lt"."tier_level", 1) AS "tier_level",
    "l"."is_active" AS "license_active",
    "l"."expiration_date" AS "license_expires_at"
   FROM (("public"."profile" "p"
     LEFT JOIN "public"."tb_m_license" "l" ON ((("p"."id" = "l"."user_id") AND ("l"."is_active" = true) AND (("l"."expiration_date" IS NULL) OR ("l"."expiration_date" > "now"())))))
     LEFT JOIN "public"."tb_r_license_type" "lt" ON (("l"."license_type" = "lt"."id")))
  ORDER BY "p"."id", "lt"."tier_level" DESC;


ALTER TABLE "public"."v_user_license" OWNER TO "postgres";


ALTER TABLE ONLY "public"."dn_actions_crop_cost" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_actions_crop_cost_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_actions_crop_fruit_bloom" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_actions_crop_fruit_bloom_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_actions_crop_yield" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_actions_crop_yield_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_iot_commands" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_iot_commands_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_iot_sensor" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_iot_sensor_logs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_iot_sensor_log_daily" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_iot_sensor_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_operations_chemical" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_operations_chemical_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_operations_chemical_harvest" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_operations_chemical_harvest_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_operations_fertilizing" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_operations_fertilizing_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_operations_harvest" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_operations_harvest_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_operations_pest_control" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_operations_pest_control_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_operations_survey" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_operations_survey_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_operations_watering" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_operations_watering_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."dn_tb_m_external_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."dn_tb_m_external_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."ha_states" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ha_states_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."mp_review_media" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."mp_review_media_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."mp_reviews" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."mp_reviews_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."ty_commands" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ty_commands_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."ty_sensor_types" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ty_sensor_types_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."ty_sensors" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ty_sensors_id_seq"'::"regclass");



ALTER TABLE "public"."harvest"
    ADD CONSTRAINT "Amount must be positive" CHECK (("amount" >= (0)::double precision)) NOT VALID;



ALTER TABLE ONLY "public"."client"
    ADD CONSTRAINT "Client_pkey" PRIMARY KEY ("id");



ALTER TABLE "public"."profile"
    ADD CONSTRAINT "First name must not be empty" CHECK (("char_length"(("first_name")::"text") >= 1)) NOT VALID;



ALTER TABLE "public"."profile"
    ADD CONSTRAINT "Last namee must not be empty" CHECK (("char_length"(("last_name")::"text") >= 1)) NOT VALID;



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."activity_type"
    ADD CONSTRAINT "activity_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_basket_items"
    ADD CONSTRAINT "basket_items_unique_per_variant" UNIQUE ("basket_id", "product_variant_id");



ALTER TABLE ONLY "public"."client_order_item"
    ADD CONSTRAINT "client_order_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_order"
    ADD CONSTRAINT "client_order_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comment"
    ADD CONSTRAINT "comment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cost_group"
    ADD CONSTRAINT "cost_group_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cost"
    ADD CONSTRAINT "cost_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."debug_log"
    ADD CONSTRAINT "debug_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_actions_crop_cost"
    ADD CONSTRAINT "dn_actions_crop_cost_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_actions_crop_fruit_bloom"
    ADD CONSTRAINT "dn_actions_crop_fruit_bloom_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_actions_crop"
    ADD CONSTRAINT "dn_actions_crop_pkey" PRIMARY KEY ("app_land_id", "app_crop_id");



ALTER TABLE ONLY "public"."dn_actions_crop_stages"
    ADD CONSTRAINT "dn_actions_crop_stages_pkey" PRIMARY KEY ("app_crop_id");



ALTER TABLE ONLY "public"."dn_actions_crop_yield"
    ADD CONSTRAINT "dn_actions_crop_yield_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_iot_commands"
    ADD CONSTRAINT "dn_iot_commands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_iot_devices"
    ADD CONSTRAINT "dn_iot_devices_client_id_key" UNIQUE ("client_id");



ALTER TABLE ONLY "public"."dn_iot_devices"
    ADD CONSTRAINT "dn_iot_devices_id_unique" UNIQUE ("id");



ALTER TABLE ONLY "public"."dn_iot_devices"
    ADD CONSTRAINT "dn_iot_devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_iot_sensor_log_daily"
    ADD CONSTRAINT "dn_iot_sensor_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_iot_sensor"
    ADD CONSTRAINT "dn_iot_sensor_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_iot_sensor_types"
    ADD CONSTRAINT "dn_iot_sensor_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_iot_supply_list"
    ADD CONSTRAINT "dn_iot_supply_list_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_operations_chemical"
    ADD CONSTRAINT "dn_operations_chemical_app_oper_id_key" UNIQUE ("app_oper_id");



ALTER TABLE ONLY "public"."dn_operations_chemical_harvest"
    ADD CONSTRAINT "dn_operations_chemical_harvest_app_oper_id_key" UNIQUE ("app_oper_id");



ALTER TABLE ONLY "public"."dn_operations_chemical_harvest"
    ADD CONSTRAINT "dn_operations_chemical_harvest_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_operations_chemical"
    ADD CONSTRAINT "dn_operations_chemical_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_operations_fertilizing"
    ADD CONSTRAINT "dn_operations_fertilizing_app_oper_id_key" UNIQUE ("app_oper_id");



ALTER TABLE ONLY "public"."dn_operations_fertilizing"
    ADD CONSTRAINT "dn_operations_fertilizing_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_operations_harvest"
    ADD CONSTRAINT "dn_operations_harvest_app_oper_id_key" UNIQUE ("app_oper_id");



ALTER TABLE ONLY "public"."dn_operations_harvest"
    ADD CONSTRAINT "dn_operations_harvest_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_operations_pest_control"
    ADD CONSTRAINT "dn_operations_pest_control_app_oper_id_key" UNIQUE ("app_oper_id");



ALTER TABLE ONLY "public"."dn_operations_pest_control"
    ADD CONSTRAINT "dn_operations_pest_control_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_operations_survey"
    ADD CONSTRAINT "dn_operations_survey_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_operations_watering"
    ADD CONSTRAINT "dn_operations_watering_app_oper_id_key" UNIQUE ("app_oper_id");



ALTER TABLE ONLY "public"."dn_operations_watering"
    ADD CONSTRAINT "dn_operations_watering_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_cbf_energy_ef"
    ADD CONSTRAINT "dn_tb_m_cbf_energy_ef_ef_type_fuel_type_key" UNIQUE ("ef_type", "fuel_type");



ALTER TABLE ONLY "public"."dn_tb_m_cbf_energy_ef"
    ADD CONSTRAINT "dn_tb_m_cbf_energy_ef_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_cbf"
    ADD CONSTRAINT "dn_tb_m_cbf_pkey" PRIMARY KEY ("cbf_id");



ALTER TABLE ONLY "public"."dn_tb_m_cbf_transport_ef"
    ADD CONSTRAINT "dn_tb_m_cbf_transport_ef_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_cbf_transport_ef"
    ADD CONSTRAINT "dn_tb_m_cbf_transport_ef_vehicle_code_fuel_type_loading_pct_key" UNIQUE ("vehicle_code", "fuel_type", "loading_pct");



ALTER TABLE ONLY "public"."dn_tb_m_certify"
    ADD CONSTRAINT "dn_tb_m_certify_pkey" PRIMARY KEY ("certify_id");



ALTER TABLE ONLY "public"."dn_tb_m_community_memberships"
    ADD CONSTRAINT "dn_tb_m_community_memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_community"
    ADD CONSTRAINT "dn_tb_m_community_pkey" PRIMARY KEY ("comm_id");



ALTER TABLE ONLY "public"."dn_tb_m_crop_stage"
    ADD CONSTRAINT "dn_tb_m_crop_stage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_device_tokens"
    ADD CONSTRAINT "dn_tb_m_device_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_device_tokens"
    ADD CONSTRAINT "dn_tb_m_device_tokens_user_id_platform_key" UNIQUE ("user_id", "platform");



ALTER TABLE ONLY "public"."dn_tb_m_external_log"
    ADD CONSTRAINT "dn_tb_m_external_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_farm"
    ADD CONSTRAINT "dn_tb_m_farm_pkey" PRIMARY KEY ("farm_id");



ALTER TABLE ONLY "public"."dn_tb_m_iot_hubs"
    ADD CONSTRAINT "dn_tb_m_iot_hubs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_land"
    ADD CONSTRAINT "dn_tb_m_land_pkey" PRIMARY KEY ("land_id");



ALTER TABLE ONLY "public"."dn_tb_m_land_type"
    ADD CONSTRAINT "dn_tb_m_land_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_land_type"
    ADD CONSTRAINT "dn_tb_m_land_type_type_id_key" UNIQUE ("type_id");



ALTER TABLE ONLY "public"."dn_tb_m_news_comment"
    ADD CONSTRAINT "dn_tb_m_news_comment_pkey" PRIMARY KEY ("comment_id");



ALTER TABLE ONLY "public"."dn_tb_m_news_like"
    ADD CONSTRAINT "dn_tb_m_news_like_news_id_user_id_key" UNIQUE ("news_id", "user_id");



ALTER TABLE ONLY "public"."dn_tb_m_news_like"
    ADD CONSTRAINT "dn_tb_m_news_like_pkey" PRIMARY KEY ("like_id");



ALTER TABLE ONLY "public"."dn_tb_m_news"
    ADD CONSTRAINT "dn_tb_m_news_pkey" PRIMARY KEY ("news_id");



ALTER TABLE ONLY "public"."dn_tb_m_notifications"
    ADD CONSTRAINT "dn_tb_m_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_m_price"
    ADD CONSTRAINT "dn_tb_m_price_pkey" PRIMARY KEY ("price_id");



ALTER TABLE ONLY "public"."dn_tb_m_user"
    ADD CONSTRAINT "dn_tb_m_user_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_chemical"
    ADD CONSTRAINT "dn_tb_r_cbf_chemical_app_chem_cbf_id_key" UNIQUE ("app_chem_cbf_id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_chemical"
    ADD CONSTRAINT "dn_tb_r_cbf_chemical_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_electric"
    ADD CONSTRAINT "dn_tb_r_cbf_electric_app_elec_cbf_id_key" UNIQUE ("app_elec_cbf_id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_electric"
    ADD CONSTRAINT "dn_tb_r_cbf_electric_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_fertilizer"
    ADD CONSTRAINT "dn_tb_r_cbf_fertilizer_app_fert_cbf_id_key" UNIQUE ("app_fert_cbf_id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_fertilizer"
    ADD CONSTRAINT "dn_tb_r_cbf_fertilizer_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_fuel"
    ADD CONSTRAINT "dn_tb_r_cbf_fuel_app_fuel_cbf_id_key" UNIQUE ("app_fuel_cbf_id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_fuel"
    ADD CONSTRAINT "dn_tb_r_cbf_fuel_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_material"
    ADD CONSTRAINT "dn_tb_r_cbf_material_app_mate_cbf_id_key" UNIQUE ("app_mate_cbf_id");



ALTER TABLE ONLY "public"."dn_tb_r_cbf_material"
    ADD CONSTRAINT "dn_tb_r_cbf_material_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."factor_detail"
    ADD CONSTRAINT "factor_detail_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."factor_stock"
    ADD CONSTRAINT "factor_stock_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."farm_group"
    ADD CONSTRAINT "farm_group_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."farm"
    ADD CONSTRAINT "farm_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."farm_type"
    ADD CONSTRAINT "farm_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."group"
    ADD CONSTRAINT "groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ha_bridges"
    ADD CONSTRAINT "ha_bridges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ha_command"
    ADD CONSTRAINT "ha_command_pkey" PRIMARY KEY ("bridge_id");



ALTER TABLE ONLY "public"."ha_entities"
    ADD CONSTRAINT "ha_entities_pkey" PRIMARY KEY ("bridge_id", "entity_id");



ALTER TABLE ONLY "public"."ha_entities"
    ADD CONSTRAINT "ha_entities_state_ref_key" UNIQUE ("state_ref");



ALTER TABLE ONLY "public"."ha_states"
    ADD CONSTRAINT "ha_states_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."harvest"
    ADD CONSTRAINT "harvest_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."maintenance"
    ADD CONSTRAINT "maintenance_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_bank_list"
    ADD CONSTRAINT "master_bank_list_pkey" PRIMARY KEY ("bank_acronyms");



ALTER TABLE ONLY "public"."master_delivery_type"
    ADD CONSTRAINT "master_delivery_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_product_category"
    ADD CONSTRAINT "master_product_category_category_id_key" UNIQUE ("category_id");



ALTER TABLE ONLY "public"."master_product_category"
    ADD CONSTRAINT "master_product_category_pkey" PRIMARY KEY ("category_id");



ALTER TABLE ONLY "public"."master_product_type"
    ADD CONSTRAINT "master_products_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."master_product_type"
    ADD CONSTRAINT "master_products_product_id_key" UNIQUE ("product_id");



ALTER TABLE ONLY "public"."mp_basket_items"
    ADD CONSTRAINT "mp_basket_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_basket"
    ADD CONSTRAINT "mp_basket_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_chat_members"
    ADD CONSTRAINT "mp_chat_members_pkey" PRIMARY KEY ("member_id", "chat_room_id");



ALTER TABLE ONLY "public"."mp_chat_message_attachments"
    ADD CONSTRAINT "mp_chat_message_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_chat_messages"
    ADD CONSTRAINT "mp_chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_chat_room_reads"
    ADD CONSTRAINT "mp_chat_room_reads_pkey" PRIMARY KEY ("chat_room_id", "user_id");



ALTER TABLE ONLY "public"."mp_chat_rooms"
    ADD CONSTRAINT "mp_chat_rooms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_delivery_method"
    ADD CONSTRAINT "mp_delivery_method_pkey" PRIMARY KEY ("delivery_method_id");



ALTER TABLE ONLY "public"."mp_delivery_rate"
    ADD CONSTRAINT "mp_delivery_rate_no_overlap" EXCLUDE USING "gist" ("delivery_method_id" WITH =, "weight_range" WITH &&);



ALTER TABLE ONLY "public"."mp_delivery_rate"
    ADD CONSTRAINT "mp_delivery_rate_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_order_disputes"
    ADD CONSTRAINT "mp_order_disputes_order_id_key" UNIQUE ("order_id");



ALTER TABLE ONLY "public"."mp_order_disputes"
    ADD CONSTRAINT "mp_order_disputes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_order_items"
    ADD CONSTRAINT "mp_order_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_order_notification_log"
    ADD CONSTRAINT "mp_order_notification_log_order_level_key" UNIQUE ("order_id", "reminder_level");



ALTER TABLE ONLY "public"."mp_order_notification_log"
    ADD CONSTRAINT "mp_order_notification_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_order_sales"
    ADD CONSTRAINT "mp_order_sales_order_code_key" UNIQUE ("order_code");



ALTER TABLE ONLY "public"."mp_payment_method"
    ADD CONSTRAINT "mp_payment_method_payment_id_key" UNIQUE ("payment_id");



ALTER TABLE ONLY "public"."mp_payment_method"
    ADD CONSTRAINT "mp_payment_method_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_platform_payout_log"
    ADD CONSTRAINT "mp_platform_payout_log_omise_transfer_id_key" UNIQUE ("omise_transfer_id");



ALTER TABLE ONLY "public"."mp_platform_payout_log"
    ADD CONSTRAINT "mp_platform_payout_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_product_delivery_config"
    ADD CONSTRAINT "mp_product_delivery_config_pkey" PRIMARY KEY ("product_id", "delivery_method_id");



ALTER TABLE ONLY "public"."mp_product"
    ADD CONSTRAINT "mp_product_pkey" PRIMARY KEY ("product_id");



ALTER TABLE ONLY "public"."mp_product_variant"
    ADD CONSTRAINT "mp_product_variant_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_promotion"
    ADD CONSTRAINT "mp_promotion_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_promotion_products"
    ADD CONSTRAINT "mp_promotion_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_promotion_products"
    ADD CONSTRAINT "mp_promotion_products_promotion_id_product_variant_id_key" UNIQUE ("promotion_id", "product_variant_id");



ALTER TABLE ONLY "public"."mp_review_media"
    ADD CONSTRAINT "mp_review_media_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_reviews"
    ADD CONSTRAINT "mp_reviews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_order_sales"
    ADD CONSTRAINT "mp_sales_pkey" PRIMARY KEY ("order_id");



ALTER TABLE ONLY "public"."mp_seller_violations"
    ADD CONSTRAINT "mp_seller_violations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_shop_address"
    ADD CONSTRAINT "mp_shop_address_pkey" PRIMARY KEY ("shop_id");



ALTER TABLE ONLY "public"."mp_shop_payment"
    ADD CONSTRAINT "mp_shop_payment_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_tb_m_dispute_reason"
    ADD CONSTRAINT "mp_tb_m_dispute_reason_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_tb_m_order_status"
    ADD CONSTRAINT "mp_tb_m_order_status_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_tb_user_sessions"
    ADD CONSTRAINT "mp_tb_user_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_user_address"
    ADD CONSTRAINT "mp_user_address_pkey" PRIMARY KEY ("address_id");



ALTER TABLE ONLY "public"."mp_user_daily_summary"
    ADD CONSTRAINT "mp_user_daily_summary_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_user_daily_summary"
    ADD CONSTRAINT "mp_user_daily_summary_user_id_summary_date_key" UNIQUE ("user_id", "summary_date");



ALTER TABLE ONLY "public"."news"
    ADD CONSTRAINT "news_pkey" PRIMARY KEY ("id");



ALTER TABLE "public"."activity"
    ADD CONSTRAINT "note length must not exceed 100 characters" CHECK (("char_length"("note") <= 100)) NOT VALID;



ALTER TABLE ONLY "public"."notification"
    ADD CONSTRAINT "notification_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_history_file"
    ADD CONSTRAINT "order_history_file_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_payout_log"
    ADD CONSTRAINT "payout_log_omise_transfer_id_key" UNIQUE ("omise_transfer_id");



ALTER TABLE ONLY "public"."mp_payout_log"
    ADD CONSTRAINT "payout_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plant_cycle"
    ADD CONSTRAINT "plant_cycle_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_m_planting_cycles"
    ADD CONSTRAINT "planting_cycles_pkey" PRIMARY KEY ("cycle_id");



ALTER TABLE ONLY "public"."pre_activity"
    ADD CONSTRAINT "pre_activity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_option"
    ADD CONSTRAINT "product_option_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product"
    ADD CONSTRAINT "product_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profile"
    ADD CONSTRAINT "profile_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."profile"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."province"
    ADD CONSTRAINT "province_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quota_item"
    ADD CONSTRAINT "quota_item_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quota"
    ADD CONSTRAINT "quota_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shop"
    ADD CONSTRAINT "shop_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mp_shop_province"
    ADD CONSTRAINT "shop_province_pkey" PRIMARY KEY ("shop_id", "province_id");



ALTER TABLE ONLY "public"."standard"
    ADD CONSTRAINT "standard_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."standard_type"
    ADD CONSTRAINT "standard_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sub_district"
    ADD CONSTRAINT "sub_district_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_h_wallet"
    ADD CONSTRAINT "tb_h_wallet_pkey" PRIMARY KEY ("wallet_id");



ALTER TABLE ONLY "public"."tb_m_license"
    ADD CONSTRAINT "tb_m_license_license_key_key" UNIQUE ("license_key");



ALTER TABLE ONLY "public"."tb_m_license"
    ADD CONSTRAINT "tb_m_license_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_m_mp_boost_plan"
    ADD CONSTRAINT "tb_m_mp_boost_plan_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_m_partners"
    ADD CONSTRAINT "tb_m_partners_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."tb_m_partners"
    ADD CONSTRAINT "tb_m_partners_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_m_product_boost"
    ADD CONSTRAINT "tb_m_product_boost_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_m_reward"
    ADD CONSTRAINT "tb_m_reward_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_m_wallet"
    ADD CONSTRAINT "tb_m_wallet_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_r_wallet_type"
    ADD CONSTRAINT "tb_m_wallet_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_r_license_type"
    ADD CONSTRAINT "tb_r_license_type_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tb_r_wallet_type"
    ADD CONSTRAINT "tb_r_wallet_type_type_key" UNIQUE ("type");



ALTER TABLE ONLY "public"."traceback"
    ADD CONSTRAINT "traceback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ty_commands"
    ADD CONSTRAINT "ty_commands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ty_devices"
    ADD CONSTRAINT "ty_devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ty_sensor_detail"
    ADD CONSTRAINT "ty_sensor_detail_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ty_sensor_detail"
    ADD CONSTRAINT "ty_sensor_detail_sensor_id_key" UNIQUE ("sensor_id");



ALTER TABLE ONLY "public"."ty_sensor_types"
    ADD CONSTRAINT "ty_sensor_types_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."ty_sensor_types"
    ADD CONSTRAINT "ty_sensor_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ty_sensors"
    ADD CONSTRAINT "ty_sensors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dn_actions_crop"
    ADD CONSTRAINT "unique_app_crop_id" UNIQUE ("app_crop_id");



ALTER TABLE ONLY "public"."dn_actions_crop_fruit_bloom"
    ADD CONSTRAINT "unique_app_crop_id_fruit_bloom" UNIQUE ("app_crop_id");



ALTER TABLE ONLY "public"."client_order_item"
    ADD CONSTRAINT "unique_order_farm_type" UNIQUE ("order_id", "farm_type_id");



ALTER TABLE ONLY "public"."quota_item"
    ADD CONSTRAINT "unique_quota_farm_type" UNIQUE ("quota_id", "farm_type_id");



ALTER TABLE ONLY "public"."user_levels"
    ADD CONSTRAINT "user_levels_pkey" PRIMARY KEY ("user_level");



ALTER TABLE ONLY "public"."user_log"
    ADD CONSTRAINT "user_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_pkey" PRIMARY KEY ("id");



CREATE INDEX "dn_iot_supply_list_electrician_id_idx" ON "public"."dn_iot_supply_list" USING "btree" ("electrician_id");



CREATE INDEX "dn_iot_supply_list_serial_number_idx" ON "public"."dn_iot_supply_list" USING "gin" ("serial_number" "public"."gin_trgm_ops");



CREATE INDEX "fki_activity_user_id_fkey" ON "public"."activity" USING "btree" ("user_id");



CREATE INDEX "ha_bridges_owner_id_index" ON "public"."ha_bridges" USING "btree" ("owner_id");



CREATE INDEX "ha_bridges_shared_to_index" ON "public"."ha_bridges" USING "gin" ("shared_to");



CREATE INDEX "ha_entities_bridge_id_idx" ON "public"."ha_entities" USING "btree" ("bridge_id");



CREATE INDEX "ha_entities_state_ref_idx" ON "public"."ha_entities" USING "btree" ("state_ref");



CREATE INDEX "ha_states_state_ref_idx" ON "public"."ha_states" USING "btree" ("state_ref");



CREATE INDEX "idx_cbf_app_crop_id" ON "public"."dn_tb_m_cbf" USING "btree" ("app_crop_id");



CREATE INDEX "idx_cbf_chemical_cbf_id" ON "public"."dn_tb_r_cbf_chemical" USING "btree" ("cbf_id");



CREATE INDEX "idx_cbf_electric_cbf_id" ON "public"."dn_tb_r_cbf_electric" USING "btree" ("cbf_id");



CREATE INDEX "idx_cbf_fertilizer_cbf_id" ON "public"."dn_tb_r_cbf_fertilizer" USING "btree" ("cbf_id");



CREATE INDEX "idx_cbf_fuel_cbf_id" ON "public"."dn_tb_r_cbf_fuel" USING "btree" ("cbf_id");



CREATE INDEX "idx_cbf_material_cbf_id" ON "public"."dn_tb_r_cbf_material" USING "btree" ("cbf_id");



CREATE INDEX "idx_cbf_user_id" ON "public"."dn_tb_m_cbf" USING "btree" ("user_id");



CREATE INDEX "idx_certify_crop_id" ON "public"."dn_tb_m_certify" USING "btree" ("app_crop_id");



CREATE INDEX "idx_certify_dates" ON "public"."dn_tb_m_certify" USING "btree" ("application_date", "issued_date", "expiry_date");



CREATE INDEX "idx_certify_deleted" ON "public"."dn_tb_m_certify" USING "btree" ("is_deleted");



CREATE INDEX "idx_certify_land_id" ON "public"."dn_tb_m_certify" USING "btree" ("app_land_id");



CREATE INDEX "idx_certify_status" ON "public"."dn_tb_m_certify" USING "btree" ("cert_status");



CREATE INDEX "idx_certify_user_active" ON "public"."dn_tb_m_certify" USING "btree" ("user_id", "is_deleted", "cert_status");



CREATE INDEX "idx_certify_user_id" ON "public"."dn_tb_m_certify" USING "btree" ("user_id");



CREATE INDEX "idx_chemical_chemicals" ON "public"."dn_operations_chemical" USING "gin" ("chemicals");



CREATE INDEX "idx_chemical_crop_id" ON "public"."dn_operations_chemical" USING "btree" ("app_crop_id");



CREATE INDEX "idx_chemical_deleted" ON "public"."dn_operations_chemical" USING "btree" ("is_deleted");



CREATE INDEX "idx_chemical_equipments" ON "public"."dn_operations_chemical" USING "gin" ("equipments");



CREATE INDEX "idx_chemical_harvest_chemicals" ON "public"."dn_operations_chemical_harvest" USING "gin" ("chemicals");



CREATE INDEX "idx_chemical_harvest_crop_id" ON "public"."dn_operations_chemical_harvest" USING "btree" ("app_crop_id");



CREATE INDEX "idx_chemical_harvest_deleted" ON "public"."dn_operations_chemical_harvest" USING "btree" ("is_deleted");



CREATE INDEX "idx_chemical_harvest_equipments" ON "public"."dn_operations_chemical_harvest" USING "gin" ("equipments");



CREATE INDEX "idx_chemical_harvest_lot" ON "public"."dn_operations_chemical_harvest" USING "btree" ("harvest_lot_number");



CREATE INDEX "idx_chemical_harvest_oper_date" ON "public"."dn_operations_chemical_harvest" USING "btree" ("oper_date");



CREATE INDEX "idx_chemical_oper_date" ON "public"."dn_operations_chemical" USING "btree" ("oper_date");



CREATE INDEX "idx_commands_device" ON "public"."dn_iot_commands" USING "btree" ("device_id");



CREATE INDEX "idx_commands_status" ON "public"."dn_iot_commands" USING "btree" ("status");



CREATE INDEX "idx_commands_status_created" ON "public"."dn_iot_commands" USING "btree" ("status", "created_at");



CREATE INDEX "idx_crop_cost_crop_id" ON "public"."dn_actions_crop_cost" USING "btree" ("app_crop_id");



CREATE INDEX "idx_crop_cost_date_range" ON "public"."dn_actions_crop_cost" USING "btree" ("from_date", "to_date");



CREATE INDEX "idx_crop_cost_deleted" ON "public"."dn_actions_crop_cost" USING "btree" ("is_deleted");



CREATE INDEX "idx_crop_fruit_bloom_crop_id" ON "public"."dn_actions_crop_fruit_bloom" USING "btree" ("app_crop_id");



CREATE INDEX "idx_crop_fruit_bloom_deleted" ON "public"."dn_actions_crop_fruit_bloom" USING "btree" ("is_deleted");



CREATE INDEX "idx_crop_stages_deleted" ON "public"."dn_actions_crop_stages" USING "btree" ("is_deleted");



CREATE INDEX "idx_crop_yield_deleted" ON "public"."dn_actions_crop_yield" USING "btree" ("is_deleted");



CREATE INDEX "idx_devices_last_seen" ON "public"."dn_iot_devices" USING "btree" ("last_seen");



CREATE INDEX "idx_dn_actions_crop_app_crop_id" ON "public"."dn_actions_crop" USING "btree" ("app_crop_id");



CREATE INDEX "idx_dn_actions_crop_app_land_id" ON "public"."dn_actions_crop" USING "btree" ("app_land_id");



CREATE INDEX "idx_dn_actions_crop_breed" ON "public"."dn_actions_crop" USING "btree" ("breed_name");



CREATE INDEX "idx_dn_actions_crop_cost_app_crop_id" ON "public"."dn_actions_crop_cost" USING "btree" ("app_crop_id");



CREATE INDEX "idx_dn_actions_crop_created_at" ON "public"."dn_actions_crop" USING "btree" ("created_at");



CREATE INDEX "idx_dn_actions_crop_crop_year" ON "public"."dn_actions_crop" USING "btree" ("crop_year");



CREATE INDEX "idx_dn_actions_crop_fruit_bloom_app_crop_id" ON "public"."dn_actions_crop_fruit_bloom" USING "btree" ("app_crop_id");



CREATE INDEX "idx_dn_actions_crop_is_deleted" ON "public"."dn_actions_crop" USING "btree" ("is_deleted");



CREATE INDEX "idx_dn_actions_crop_land_crop_deleted" ON "public"."dn_actions_crop" USING "btree" ("app_land_id", "app_crop_id", "is_deleted");



CREATE INDEX "idx_dn_actions_crop_stages_app_crop_id" ON "public"."dn_actions_crop_stages" USING "btree" ("app_crop_id");



CREATE INDEX "idx_dn_actions_crop_yield_app_crop_id" ON "public"."dn_actions_crop_yield" USING "btree" ("app_crop_id");



CREATE INDEX "idx_dn_iot_sensor_device_type_created" ON "public"."dn_iot_sensor" USING "btree" ("device_id", "sensor_type_id", "created_at");



CREATE INDEX "idx_dn_iot_supply_list_serial_number" ON "public"."dn_iot_supply_list" USING "btree" ("serial_number");



CREATE INDEX "idx_dn_tb_m_cbf_app_crop_id" ON "public"."dn_tb_m_cbf" USING "btree" ("app_crop_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_m_farm_created_at" ON "public"."dn_tb_m_farm" USING "btree" ("created_at");



CREATE INDEX "idx_dn_tb_m_farm_farmer_id" ON "public"."dn_tb_m_farm" USING "btree" ("farmer_id");



CREATE INDEX "idx_dn_tb_m_farm_province" ON "public"."dn_tb_m_farm" USING "btree" ("province");



CREATE INDEX "idx_dn_tb_m_land_created_at" ON "public"."dn_tb_m_land" USING "btree" ("created_at");



CREATE INDEX "idx_dn_tb_m_land_farmer_id" ON "public"."dn_tb_m_land" USING "btree" ("farmer_id");



CREATE INDEX "idx_dn_tb_m_land_farmer_land_id" ON "public"."dn_tb_m_land" USING "btree" ("farmer_id", "land_id");



CREATE INDEX "idx_dn_tb_m_land_land_type" ON "public"."dn_tb_m_land" USING "btree" ("land_type");



CREATE INDEX "idx_dn_tb_m_price_breed_name" ON "public"."dn_tb_m_price" USING "btree" ("breed_name");



CREATE INDEX "idx_dn_tb_m_price_created_at" ON "public"."dn_tb_m_price" USING "btree" ("created_at");



CREATE INDEX "idx_dn_tb_m_price_data_source" ON "public"."dn_tb_m_price" USING "btree" ("data_source");



CREATE INDEX "idx_dn_tb_m_price_date_province_breed" ON "public"."dn_tb_m_price" USING "btree" ("price_date", "province", "breed_name");



CREATE INDEX "idx_dn_tb_m_price_price_date" ON "public"."dn_tb_m_price" USING "btree" ("price_date");



CREATE INDEX "idx_dn_tb_m_price_province" ON "public"."dn_tb_m_price" USING "btree" ("province");



CREATE INDEX "idx_dn_tb_r_cbf_chemical_app_crop_id" ON "public"."dn_tb_r_cbf_chemical" USING "btree" ("app_crop_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_chemical_cbf_id" ON "public"."dn_tb_r_cbf_chemical" USING "btree" ("cbf_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_electric_app_crop_id" ON "public"."dn_tb_r_cbf_electric" USING "btree" ("app_crop_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_electric_cbf_id" ON "public"."dn_tb_r_cbf_electric" USING "btree" ("cbf_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_fertilizer_app_crop_id" ON "public"."dn_tb_r_cbf_fertilizer" USING "btree" ("app_crop_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_fertilizer_cbf_id" ON "public"."dn_tb_r_cbf_fertilizer" USING "btree" ("cbf_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_fuel_app_crop_id" ON "public"."dn_tb_r_cbf_fuel" USING "btree" ("app_crop_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_fuel_cbf_id" ON "public"."dn_tb_r_cbf_fuel" USING "btree" ("cbf_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_material_app_crop_id" ON "public"."dn_tb_r_cbf_material" USING "btree" ("app_crop_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_dn_tb_r_cbf_material_cbf_id" ON "public"."dn_tb_r_cbf_material" USING "btree" ("cbf_id") WHERE ("is_deleted" = false);



CREATE INDEX "idx_external_log_created_at" ON "public"."dn_tb_m_external_log" USING "btree" ("created_at");



CREATE INDEX "idx_external_log_function_name" ON "public"."dn_tb_m_external_log" USING "btree" ("function_name");



CREATE INDEX "idx_external_log_success" ON "public"."dn_tb_m_external_log" USING "btree" ("success");



CREATE INDEX "idx_fertilizing_crop_id" ON "public"."dn_operations_fertilizing" USING "btree" ("app_crop_id");



CREATE INDEX "idx_fertilizing_deleted" ON "public"."dn_operations_fertilizing" USING "btree" ("is_deleted");



CREATE INDEX "idx_fertilizing_equip_type" ON "public"."dn_operations_fertilizing" USING "gin" ("equipments");



CREATE INDEX "idx_fertilizing_fert_type" ON "public"."dn_operations_fertilizing" USING "gin" ("fertilizers");



CREATE INDEX "idx_fertilizing_oper_date" ON "public"."dn_operations_fertilizing" USING "btree" ("oper_date");



CREATE INDEX "idx_harvest_crop_id" ON "public"."dn_operations_harvest" USING "btree" ("app_crop_id");



CREATE INDEX "idx_harvest_deleted" ON "public"."dn_operations_harvest" USING "btree" ("is_deleted");



CREATE INDEX "idx_harvest_lot_number" ON "public"."dn_operations_harvest" USING "btree" ("lot_number");



CREATE INDEX "idx_harvest_oper_date" ON "public"."dn_operations_harvest" USING "btree" ("oper_date");



CREATE INDEX "idx_license_type_tier" ON "public"."tb_r_license_type" USING "btree" ("tier_level", "tier_name");



CREATE INDEX "idx_license_user_active" ON "public"."tb_m_license" USING "btree" ("user_id", "is_active", "expiration_date");



CREATE INDEX "idx_mp_order_items_order" ON "public"."mp_order_items" USING "btree" ("order_id");



CREATE INDEX "idx_mp_order_items_variant" ON "public"."mp_order_items" USING "btree" ("product_variant_id");



CREATE INDEX "idx_mp_order_sales_paid_created" ON "public"."mp_order_sales" USING "btree" ("paid_at", "created_at");



CREATE INDEX "idx_mp_product_delivery_config_product" ON "public"."mp_product_delivery_config" USING "btree" ("product_id");



CREATE INDEX "idx_notification_log_order_id" ON "public"."mp_order_notification_log" USING "btree" ("order_id");



CREATE INDEX "idx_notifications_user_id" ON "public"."dn_tb_m_notifications" USING "btree" ("user_id");



CREATE INDEX "idx_notifications_user_unread" ON "public"."dn_tb_m_notifications" USING "btree" ("user_id", "is_read") WHERE ("is_read" = false);



CREATE INDEX "idx_order_sales_timeout" ON "public"."mp_order_sales" USING "btree" ("payment_status", "shipped_at", "confirmed_at") WHERE (("payment_status" = 'DELIVERY_PENDING'::"text") AND ("shipped_at" IS NULL));



CREATE INDEX "idx_pest_control_carrier" ON "public"."dn_operations_pest_control" USING "btree" ("carrier_type");



CREATE INDEX "idx_pest_control_crop_id" ON "public"."dn_operations_pest_control" USING "btree" ("app_crop_id");



CREATE INDEX "idx_pest_control_deleted" ON "public"."dn_operations_pest_control" USING "btree" ("is_deleted");



CREATE INDEX "idx_pest_control_equipments" ON "public"."dn_operations_pest_control" USING "gin" ("equipments");



CREATE INDEX "idx_pest_control_oper_date" ON "public"."dn_operations_pest_control" USING "btree" ("oper_date");



CREATE INDEX "idx_product_boost_active_slot" ON "public"."tb_m_product_boost" USING "btree" ("boost_slot", "expires_at") WHERE ("status" = 'active'::"text");



CREATE INDEX "idx_product_boost_shop" ON "public"."tb_m_product_boost" USING "btree" ("shop_id", "created_at" DESC);



CREATE UNIQUE INDEX "idx_product_boost_unique_active" ON "public"."tb_m_product_boost" USING "btree" ("product_id", "boost_slot") WHERE ("status" = 'active'::"text");



CREATE INDEX "idx_sensor_device" ON "public"."dn_iot_sensor" USING "btree" ("device_id");



CREATE INDEX "idx_survey_crop_id" ON "public"."dn_operations_survey" USING "btree" ("app_crop_id");



CREATE INDEX "idx_survey_deleted" ON "public"."dn_operations_survey" USING "btree" ("is_deleted");



CREATE INDEX "idx_survey_equipments" ON "public"."dn_operations_survey" USING "gin" ("equipments");



CREATE INDEX "idx_survey_oper_date" ON "public"."dn_operations_survey" USING "btree" ("oper_date");



CREATE INDEX "idx_survey_problem_type" ON "public"."dn_operations_survey" USING "btree" ("problem_type");



CREATE INDEX "idx_watering_crop_id" ON "public"."dn_operations_watering" USING "btree" ("app_crop_id");



CREATE INDEX "idx_watering_deleted" ON "public"."dn_operations_watering" USING "btree" ("is_deleted");



CREATE INDEX "idx_watering_oper_date" ON "public"."dn_operations_watering" USING "btree" ("oper_date");



CREATE INDEX "mp_chat_members_member_id_idx" ON "public"."mp_chat_members" USING "btree" ("member_id");



CREATE INDEX "mp_chat_messages_room_time_idx" ON "public"."mp_chat_messages" USING "btree" ("chat_room_id", "created_at" DESC);



CREATE INDEX "mp_chat_msg_attach_message_id_idx" ON "public"."mp_chat_message_attachments" USING "btree" ("message_id");



CREATE INDEX "mp_chat_msg_attach_order_id_idx" ON "public"."mp_chat_message_attachments" USING "btree" ("order_id");



CREATE INDEX "mp_chat_msg_attach_product_id_idx" ON "public"."mp_chat_message_attachments" USING "btree" ("product_id");



CREATE INDEX "mp_chat_rooms_buyer_last_msg_idx" ON "public"."mp_chat_rooms" USING "btree" ("buyer_id", "last_message_at" DESC);



CREATE UNIQUE INDEX "mp_chat_rooms_unique_pair" ON "public"."mp_chat_rooms" USING "btree" ("buyer_id", "seller_id");



CREATE INDEX "mp_delivery_rate_method_idx" ON "public"."mp_delivery_rate" USING "btree" ("delivery_method_id");



CREATE INDEX "mp_promotion_products_variant_idx" ON "public"."mp_promotion_products" USING "btree" ("product_variant_id");



CREATE INDEX "mp_promotion_shop_active_idx" ON "public"."mp_promotion" USING "btree" ("shop_id", "start_at", "end_at");



CREATE UNIQUE INDEX "mp_shop_province_shop_province_uq" ON "public"."mp_shop_province" USING "btree" ("shop_id", "province_id");



CREATE INDEX "profile_first_name_last_name_idx" ON "public"."profile" USING "gin" ("first_name" "public"."gin_trgm_ops", "last_name" "public"."gin_trgm_ops");



CREATE INDEX "shop_province_province_id_idx" ON "public"."mp_shop_province" USING "btree" ("province_id");



CREATE INDEX "shop_province_shop_id_idx" ON "public"."mp_shop_province" USING "btree" ("shop_id");



CREATE INDEX "sub_district_amp_id_idx" ON "public"."sub_district" USING "btree" ("amp_id");



CREATE INDEX "sub_district_amphoe_th_idx" ON "public"."sub_district" USING "btree" ("amphoe_th");



CREATE INDEX "sub_district_postcode_idx" ON "public"."sub_district" USING "btree" ("postcode");



CREATE INDEX "sub_district_pro_id_idx" ON "public"."sub_district" USING "btree" ("pro_id");



CREATE INDEX "sub_district_province_th_idx" ON "public"."sub_district" USING "btree" ("province_th");



CREATE INDEX "sub_district_province_th_idx1" ON "public"."sub_district" USING "gin" ("province_th" "public"."gin_trgm_ops");



CREATE INDEX "sub_district_tam_id_idx" ON "public"."sub_district" USING "btree" ("tam_id");



CREATE INDEX "sub_district_tambon_th_idx" ON "public"."sub_district" USING "btree" ("tambon_th");



CREATE INDEX "ty_commands_command_index" ON "public"."ty_commands" USING "gin" ("command");



CREATE INDEX "ty_commands_device_id_index" ON "public"."ty_commands" USING "hash" ("device_id");



CREATE INDEX "ty_commands_time_index" ON "public"."ty_commands" USING "brin" ("time");



CREATE INDEX "ty_devices_metadata_index" ON "public"."ty_devices" USING "gin" ("metadata");



CREATE INDEX "ty_devices_owner_id_index" ON "public"."ty_devices" USING "hash" ("owner_id");



CREATE INDEX "ty_sensors_device_id_index" ON "public"."ty_sensors" USING "hash" ("device_id");



CREATE INDEX "ty_sensors_sensor_name_index" ON "public"."ty_sensors" USING "hash" ("sensor_name");



CREATE INDEX "ty_sensors_time_index" ON "public"."ty_sensors" USING "brin" ("time");



CREATE INDEX "user_permissions_user_id_index" ON "public"."user_permissions" USING "btree" ("user_id");



CREATE OR REPLACE TRIGGER "Mobile Push Notification" AFTER INSERT ON "public"."notification" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://epmtixqczpklpqlafynr.supabase.co/functions/v1/notify', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVwbXRpeHFjenBrbHBxbGFmeW5yIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTY2MDIwNzk4OSwiZXhwIjoxOTc1NzgzOTg5fQ.NPEKlthD1fHtqRKq-zIXLHW3nr0LoQghxCS3MYF2L4Y","Password":"9kIeiTaZ2J9HKoe11F4MsIO9"}', '{}', '10000');



CREATE OR REPLACE TRIGGER "check_relay_detail" AFTER UPDATE ON "public"."dn_iot_supply_list" FOR EACH ROW WHEN (("old"."relay_detail" IS DISTINCT FROM "new"."relay_detail")) EXECUTE FUNCTION "public"."check_relay_boolean"();



CREATE OR REPLACE TRIGGER "notify-discord-new-device" AFTER INSERT OR UPDATE ON "public"."dn_iot_supply_list" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://test-qc-farmfeed-web.demo-xiang.workers.dev/api/webhook/new-device', 'POST', '{"Content-type":"application/json","x-webhook-secret":"61a0d08ea3f53445d4554d2f3faa5580ccb369dd7502ecb5a94a382c2db7f82e"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_ha_bridges_inserted" AFTER INSERT ON "public"."ha_bridges" FOR EACH ROW EXECUTE FUNCTION "public"."handle_ha_bridges_inserted"();



CREATE OR REPLACE TRIGGER "on_ha_states_inserted" AFTER INSERT ON "public"."ha_states" FOR EACH ROW EXECUTE FUNCTION "public"."handle_ha_states_inserted"();



CREATE OR REPLACE TRIGGER "on_notification_insert_send_push" AFTER INSERT ON "public"."dn_tb_m_notifications" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://epmtixqczpklpqlafynr.supabase.co/functions/v1/dn-send-push-notification', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVwbXRpeHFjenBrbHBxbGFmeW5yIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTY2MDIwNzk4OSwiZXhwIjoxOTc1NzgzOTg5fQ.NPEKlthD1fHtqRKq-zIXLHW3nr0LoQghxCS3MYF2L4Y"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "on_profile_insert_or_update" AFTER INSERT OR UPDATE ON "public"."profile" FOR EACH ROW EXECUTE FUNCTION "public"."handle_profile_insert_or_update"();



CREATE OR REPLACE TRIGGER "on_user_permissions_insert_or_update" AFTER INSERT OR UPDATE ON "public"."user_permissions" FOR EACH ROW EXECUTE FUNCTION "public"."handle_user_permissions_insert_or_update"();



CREATE OR REPLACE TRIGGER "prevent_activity_insert" BEFORE INSERT ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_activity_insert"();



CREATE OR REPLACE TRIGGER "prevent_activity_update" BEFORE UPDATE ON "public"."activity" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_activity_update"();



CREATE OR REPLACE TRIGGER "prevent_comment_update" BEFORE UPDATE ON "public"."comment" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_comment_update"();



CREATE OR REPLACE TRIGGER "prevent_farm_group_update" BEFORE UPDATE ON "public"."farm_group" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_farm_group_update"();



CREATE OR REPLACE TRIGGER "prevent_farm_insert" BEFORE INSERT ON "public"."farm" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_farm_insert"();



CREATE OR REPLACE TRIGGER "prevent_farm_update" BEFORE UPDATE ON "public"."farm" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_farm_update"();



CREATE OR REPLACE TRIGGER "prevent_group_update" BEFORE UPDATE ON "public"."group" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_group_update"();



CREATE OR REPLACE TRIGGER "prevent_harvest_insert" BEFORE INSERT ON "public"."harvest" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_harvest_insert"();



CREATE OR REPLACE TRIGGER "prevent_harvest_update" BEFORE UPDATE ON "public"."harvest" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_harvest_update"();



CREATE OR REPLACE TRIGGER "prevent_media_limit" BEFORE INSERT ON "public"."mp_review_media" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_media_limit"();



CREATE OR REPLACE TRIGGER "prevent_product_option_update" BEFORE UPDATE ON "public"."product_option" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_product_option_update"();



CREATE OR REPLACE TRIGGER "prevent_product_update" BEFORE UPDATE ON "public"."product" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_product_update"();



CREATE OR REPLACE TRIGGER "prevent_profile_update" BEFORE UPDATE ON "public"."profile" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_profile_update"();



CREATE OR REPLACE TRIGGER "prevent_shop_update" BEFORE UPDATE ON "public"."shop" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_shop_update"();



CREATE OR REPLACE TRIGGER "prevent_username_update" BEFORE UPDATE ON "public"."profile" FOR EACH ROW EXECUTE FUNCTION "public"."util_handle_update_username"();



CREATE OR REPLACE TRIGGER "trg_mp_order_sales_before_insert" BEFORE INSERT ON "public"."mp_order_sales" FOR EACH ROW EXECUTE FUNCTION "public"."mp_order_sales_before_insert"();



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client"
    ADD CONSTRAINT "client_group_fkey" FOREIGN KEY ("group") REFERENCES "public"."group"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_order"
    ADD CONSTRAINT "client_order_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."client"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_order_item"
    ADD CONSTRAINT "client_order_item_farm_type_id_fkey" FOREIGN KEY ("farm_type_id") REFERENCES "public"."farm_type"("id");



ALTER TABLE ONLY "public"."client_order_item"
    ADD CONSTRAINT "client_order_item_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."client_order"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment"
    ADD CONSTRAINT "comment_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."mp_product"("product_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment"
    ADD CONSTRAINT "comment_product_variant_id_fkey" FOREIGN KEY ("product_variant_id") REFERENCES "public"."mp_product_variant"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment"
    ADD CONSTRAINT "comment_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cost_group"
    ADD CONSTRAINT "cost_group_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cost"
    ADD CONSTRAINT "cost_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_iot_commands"
    ADD CONSTRAINT "dn_iot_commands_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."dn_iot_devices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_iot_devices"
    ADD CONSTRAINT "dn_iot_devices_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profile"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."dn_iot_sensor_log_daily"
    ADD CONSTRAINT "dn_iot_sensor_log_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."dn_iot_devices"("id");



ALTER TABLE ONLY "public"."dn_iot_sensor"
    ADD CONSTRAINT "dn_iot_sensor_logs_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."dn_iot_devices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_iot_sensor"
    ADD CONSTRAINT "dn_iot_sensor_logs_sensor_type_id_fkey" FOREIGN KEY ("sensor_type_id") REFERENCES "public"."dn_iot_sensor_types"("id");



ALTER TABLE ONLY "public"."dn_iot_supply_list"
    ADD CONSTRAINT "dn_iot_supply_list_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."dn_iot_devices"("id");



ALTER TABLE ONLY "public"."dn_iot_supply_list"
    ADD CONSTRAINT "dn_iot_supply_list_electrician_id_fkey" FOREIGN KEY ("electrician_id") REFERENCES "public"."profile"("id");



ALTER TABLE ONLY "public"."dn_iot_supply_list"
    ADD CONSTRAINT "dn_iot_supply_list_sub_district_id_fkey" FOREIGN KEY ("sub_district_id") REFERENCES "public"."sub_district"("id");



ALTER TABLE ONLY "public"."dn_iot_supply_list"
    ADD CONSTRAINT "dn_iot_supply_list_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."profile"("id");



ALTER TABLE ONLY "public"."dn_tb_m_cbf"
    ADD CONSTRAINT "dn_tb_m_cbf_app_crop_id_fkey" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_tb_m_cbf"
    ADD CONSTRAINT "dn_tb_m_cbf_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id");



ALTER TABLE ONLY "public"."dn_tb_m_community_memberships"
    ADD CONSTRAINT "dn_tb_m_community_memberships_comm_id_fkey" FOREIGN KEY ("comm_id") REFERENCES "public"."dn_tb_m_community"("comm_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_m_community_memberships"
    ADD CONSTRAINT "dn_tb_m_community_memberships_farmer_id_fkey" FOREIGN KEY ("farmer_id") REFERENCES "public"."dn_tb_m_user"("user_id");



ALTER TABLE ONLY "public"."dn_tb_m_community"
    ADD CONSTRAINT "dn_tb_m_community_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."dn_tb_m_user"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_m_device_tokens"
    ADD CONSTRAINT "dn_tb_m_device_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_m_farm"
    ADD CONSTRAINT "dn_tb_m_farm_farmer_id_fkey" FOREIGN KEY ("farmer_id") REFERENCES "public"."dn_tb_m_user"("user_id");



ALTER TABLE ONLY "public"."dn_tb_m_land"
    ADD CONSTRAINT "dn_tb_m_land_farmer_id_fkey" FOREIGN KEY ("farmer_id") REFERENCES "public"."dn_tb_m_user"("user_id");



ALTER TABLE ONLY "public"."dn_tb_m_land"
    ADD CONSTRAINT "dn_tb_m_land_land_type_fkey" FOREIGN KEY ("land_type") REFERENCES "public"."dn_tb_m_land_type"("type_id");



ALTER TABLE ONLY "public"."dn_tb_m_news_comment"
    ADD CONSTRAINT "dn_tb_m_news_comment_news_id_fkey" FOREIGN KEY ("news_id") REFERENCES "public"."dn_tb_m_news"("news_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_m_news_comment"
    ADD CONSTRAINT "dn_tb_m_news_comment_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."dn_tb_m_user"("user_id");



ALTER TABLE ONLY "public"."dn_tb_m_news_like"
    ADD CONSTRAINT "dn_tb_m_news_like_news_id_fkey" FOREIGN KEY ("news_id") REFERENCES "public"."dn_tb_m_news"("news_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_m_news"
    ADD CONSTRAINT "dn_tb_m_news_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."dn_tb_m_user"("user_id");



ALTER TABLE ONLY "public"."dn_tb_m_notifications"
    ADD CONSTRAINT "dn_tb_m_notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_r_cbf_chemical"
    ADD CONSTRAINT "dn_tb_r_cbf_chemical_cbf_id_fkey" FOREIGN KEY ("cbf_id") REFERENCES "public"."dn_tb_m_cbf"("cbf_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_r_cbf_electric"
    ADD CONSTRAINT "dn_tb_r_cbf_electric_cbf_id_fkey" FOREIGN KEY ("cbf_id") REFERENCES "public"."dn_tb_m_cbf"("cbf_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_r_cbf_fertilizer"
    ADD CONSTRAINT "dn_tb_r_cbf_fertilizer_cbf_id_fkey" FOREIGN KEY ("cbf_id") REFERENCES "public"."dn_tb_m_cbf"("cbf_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_r_cbf_fuel"
    ADD CONSTRAINT "dn_tb_r_cbf_fuel_cbf_id_fkey" FOREIGN KEY ("cbf_id") REFERENCES "public"."dn_tb_m_cbf"("cbf_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_r_cbf_material"
    ADD CONSTRAINT "dn_tb_r_cbf_material_cbf_id_fkey" FOREIGN KEY ("cbf_id") REFERENCES "public"."dn_tb_m_cbf"("cbf_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."factor_detail"
    ADD CONSTRAINT "factor_detail_stock_id_fkey" FOREIGN KEY ("stock_id") REFERENCES "public"."factor_stock"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."factor_stock"
    ADD CONSTRAINT "factor_stock_app_crop_id_fkey" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."factor_stock"
    ADD CONSTRAINT "factor_stock_cycle_id_fkey" FOREIGN KEY ("cycle_id") REFERENCES "public"."plant_cycle"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."farm_type"
    ADD CONSTRAINT "farm_group" FOREIGN KEY ("group") REFERENCES "public"."group"("id") NOT VALID;



ALTER TABLE ONLY "public"."farm"
    ADD CONSTRAINT "farm_group_fkey" FOREIGN KEY ("group") REFERENCES "public"."farm_group"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."farm_group"
    ADD CONSTRAINT "farm_group_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."farm"
    ADD CONSTRAINT "farm_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dn_tb_m_certify"
    ADD CONSTRAINT "fk_certify_land_id" FOREIGN KEY ("app_land_id") REFERENCES "public"."dn_tb_m_land"("land_id");



ALTER TABLE ONLY "public"."dn_tb_m_certify"
    ADD CONSTRAINT "fk_certify_user_id" FOREIGN KEY ("user_id") REFERENCES "public"."dn_tb_m_user"("user_id");



ALTER TABLE ONLY "public"."dn_operations_chemical"
    ADD CONSTRAINT "fk_chemical_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_operations_chemical_harvest"
    ADD CONSTRAINT "fk_chemical_harvest_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_actions_crop_stages"
    ADD CONSTRAINT "fk_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_actions_crop_fruit_bloom"
    ADD CONSTRAINT "fk_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_actions_crop_cost"
    ADD CONSTRAINT "fk_crop_cost" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_actions_crop_yield"
    ADD CONSTRAINT "fk_crop_yield" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_operations_fertilizing"
    ADD CONSTRAINT "fk_fertilizing_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_operations_harvest"
    ADD CONSTRAINT "fk_harvest_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_actions_crop"
    ADD CONSTRAINT "fk_land_id" FOREIGN KEY ("app_land_id") REFERENCES "public"."dn_tb_m_land"("land_id");



ALTER TABLE ONLY "public"."dn_operations_pest_control"
    ADD CONSTRAINT "fk_pest_control_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_operations_survey"
    ADD CONSTRAINT "fk_survey_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."dn_operations_watering"
    ADD CONSTRAINT "fk_watering_crop" FOREIGN KEY ("app_crop_id") REFERENCES "public"."dn_actions_crop"("app_crop_id");



ALTER TABLE ONLY "public"."ha_bridges"
    ADD CONSTRAINT "ha_bridges_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ha_command"
    ADD CONSTRAINT "ha_command_bridge_id_fkey" FOREIGN KEY ("bridge_id") REFERENCES "public"."ha_bridges"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ha_entities"
    ADD CONSTRAINT "ha_entities_bridge_id_fkey" FOREIGN KEY ("bridge_id") REFERENCES "public"."ha_bridges"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ha_states"
    ADD CONSTRAINT "ha_states_state_ref_fkey" FOREIGN KEY ("state_ref") REFERENCES "public"."ha_entities"("state_ref") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."master_product_type"
    ADD CONSTRAINT "master_products_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."master_product_category"("category_id");



ALTER TABLE ONLY "public"."mp_basket_items"
    ADD CONSTRAINT "mp_basket_items_basket_id_fkey" FOREIGN KEY ("basket_id") REFERENCES "public"."mp_basket"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_basket_items"
    ADD CONSTRAINT "mp_basket_items_product_variant_id_fkey" FOREIGN KEY ("product_variant_id") REFERENCES "public"."mp_product_variant"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_basket"
    ADD CONSTRAINT "mp_basket_selected_address_fkey" FOREIGN KEY ("selected_address") REFERENCES "public"."mp_user_address"("address_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."mp_basket"
    ADD CONSTRAINT "mp_basket_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_message_attachments"
    ADD CONSTRAINT "mp_chat_attach_order_fk" FOREIGN KEY ("order_id") REFERENCES "public"."mp_order_sales"("order_id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."mp_chat_message_attachments"
    ADD CONSTRAINT "mp_chat_attach_product_fk" FOREIGN KEY ("product_id") REFERENCES "public"."mp_product"("product_id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."mp_chat_members"
    ADD CONSTRAINT "mp_chat_members_chat_room_id_fkey" FOREIGN KEY ("chat_room_id") REFERENCES "public"."mp_chat_rooms"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_members"
    ADD CONSTRAINT "mp_chat_members_member_id_fkey" FOREIGN KEY ("member_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_message_attachments"
    ADD CONSTRAINT "mp_chat_message_attachments_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."mp_chat_messages"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_messages"
    ADD CONSTRAINT "mp_chat_messages_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_messages"
    ADD CONSTRAINT "mp_chat_messages_chat_room_id_fkey" FOREIGN KEY ("chat_room_id") REFERENCES "public"."mp_chat_rooms"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_room_reads"
    ADD CONSTRAINT "mp_chat_room_reads_room_fk" FOREIGN KEY ("chat_room_id") REFERENCES "public"."mp_chat_rooms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_room_reads"
    ADD CONSTRAINT "mp_chat_room_reads_user_fk" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_rooms"
    ADD CONSTRAINT "mp_chat_rooms_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_chat_rooms"
    ADD CONSTRAINT "mp_chat_rooms_seller_id_fkey" FOREIGN KEY ("seller_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_delivery_method"
    ADD CONSTRAINT "mp_delivery_method_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_delivery_rate"
    ADD CONSTRAINT "mp_delivery_rate_delivery_method_id_fkey" FOREIGN KEY ("delivery_method_id") REFERENCES "public"."mp_delivery_method"("delivery_method_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_disputes"
    ADD CONSTRAINT "mp_order_disputes_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_disputes"
    ADD CONSTRAINT "mp_order_disputes_final_decision_by_fkey" FOREIGN KEY ("final_decision_by") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_disputes"
    ADD CONSTRAINT "mp_order_disputes_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."mp_order_sales"("order_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_disputes"
    ADD CONSTRAINT "mp_order_disputes_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_items"
    ADD CONSTRAINT "mp_order_items_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."mp_order_sales"("order_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_items"
    ADD CONSTRAINT "mp_order_items_product_variant_id_fkey" FOREIGN KEY ("product_variant_id") REFERENCES "public"."mp_product_variant"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_notification_log"
    ADD CONSTRAINT "mp_order_notification_log_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."mp_order_sales"("order_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_sales"
    ADD CONSTRAINT "mp_order_sales_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_sales"
    ADD CONSTRAINT "mp_order_sales_customer_id_fkey1" FOREIGN KEY ("customer_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_order_sales"
    ADD CONSTRAINT "mp_order_sales_payout_log_id_fkey" FOREIGN KEY ("payout_log_id") REFERENCES "public"."mp_payout_log"("id");



ALTER TABLE ONLY "public"."mp_order_sales"
    ADD CONSTRAINT "mp_order_sales_platform_payout_log_id_fkey" FOREIGN KEY ("platform_payout_log_id") REFERENCES "public"."mp_platform_payout_log"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."mp_order_sales"
    ADD CONSTRAINT "mp_order_sales_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_payment_method"
    ADD CONSTRAINT "mp_payment_method_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."mp_shop_payment"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_payment_method"
    ADD CONSTRAINT "mp_payment_method_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_product_delivery_config"
    ADD CONSTRAINT "mp_product_delivery_config_method_fkey" FOREIGN KEY ("delivery_method_id") REFERENCES "public"."mp_delivery_method"("delivery_method_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_product_delivery_config"
    ADD CONSTRAINT "mp_product_delivery_config_product_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."mp_product"("product_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_product"
    ADD CONSTRAINT "mp_product_product_category_fkey" FOREIGN KEY ("product_category") REFERENCES "public"."master_product_category"("category_id");



ALTER TABLE ONLY "public"."mp_product"
    ADD CONSTRAINT "mp_product_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_product_variant"
    ADD CONSTRAINT "mp_product_variant_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."mp_product"("product_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_promotion_products"
    ADD CONSTRAINT "mp_promotion_products_product_variant_id_fkey" FOREIGN KEY ("product_variant_id") REFERENCES "public"."mp_product_variant"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_promotion_products"
    ADD CONSTRAINT "mp_promotion_products_promotion_id_fkey" FOREIGN KEY ("promotion_id") REFERENCES "public"."mp_promotion"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_promotion"
    ADD CONSTRAINT "mp_promotion_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_review_media"
    ADD CONSTRAINT "mp_review_media_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."mp_reviews"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_reviews"
    ADD CONSTRAINT "mp_reviews_product_variant_id_fkey" FOREIGN KEY ("product_variant_id") REFERENCES "public"."mp_product_variant"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_reviews"
    ADD CONSTRAINT "mp_reviews_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_reviews"
    ADD CONSTRAINT "mp_reviews_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_seller_violations"
    ADD CONSTRAINT "mp_seller_violations_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."mp_order_sales"("order_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_seller_violations"
    ADD CONSTRAINT "mp_seller_violations_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_shop_address"
    ADD CONSTRAINT "mp_shop_address_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_shop_address"
    ADD CONSTRAINT "mp_shop_address_sub_district_id_fkey" FOREIGN KEY ("sub_district_id") REFERENCES "public"."sub_district"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_shop_payment"
    ADD CONSTRAINT "mp_shop_payment_bank_code_fkey" FOREIGN KEY ("bank_code") REFERENCES "public"."master_bank_list"("bank_acronyms");



ALTER TABLE ONLY "public"."mp_tb_user_sessions"
    ADD CONSTRAINT "mp_tb_user_sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_user_address"
    ADD CONSTRAINT "mp_user_address_sub_district_id_fkey" FOREIGN KEY ("sub_district_id") REFERENCES "public"."sub_district"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_user_address"
    ADD CONSTRAINT "mp_user_address_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_user_daily_summary"
    ADD CONSTRAINT "mp_user_daily_summary_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_history_file"
    ADD CONSTRAINT "order_history_file_group_fkey" FOREIGN KEY ("group") REFERENCES "public"."group"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_payout_log"
    ADD CONSTRAINT "payout_log_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id");



ALTER TABLE ONLY "public"."plant_cycle"
    ADD CONSTRAINT "plant_cycle_land_id_fkey" FOREIGN KEY ("land_id") REFERENCES "public"."dn_tb_m_land"("land_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tb_m_planting_cycles"
    ADD CONSTRAINT "planting_cycles_farm_id_fkey" FOREIGN KEY ("farm_id") REFERENCES "public"."farm"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pre_activity"
    ADD CONSTRAINT "pre_activity_farm_type_fkey" FOREIGN KEY ("farm_type") REFERENCES "public"."farm_type"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pre_activity"
    ADD CONSTRAINT "pre_activity_type_fkey" FOREIGN KEY ("type") REFERENCES "public"."activity_type"("id") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."pre_activity"
    ADD CONSTRAINT "pre_activity_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product"
    ADD CONSTRAINT "product_farm_id_fkey" FOREIGN KEY ("farm_id") REFERENCES "public"."farm"("id");



ALTER TABLE ONLY "public"."product_option"
    ADD CONSTRAINT "product_option_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."product"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product"
    ADD CONSTRAINT "product_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profile"
    ADD CONSTRAINT "profile_dn_app_id_fkey" FOREIGN KEY ("dn_app_id") REFERENCES "public"."dn_tb_m_user"("user_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profile"
    ADD CONSTRAINT "profile_email_fkey" FOREIGN KEY ("email") REFERENCES "auth"."users"("email");



ALTER TABLE ONLY "public"."profile"
    ADD CONSTRAINT "profile_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profile"
    ADD CONSTRAINT "profile_user_level_fkey" FOREIGN KEY ("user_level") REFERENCES "public"."user_levels"("user_level") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "public_activity_farm_id_fkey" FOREIGN KEY ("farm_id") REFERENCES "public"."farm"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "public_activity_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."activity_type"("id");



ALTER TABLE ONLY "public"."cost"
    ADD CONSTRAINT "public_cost_group_fkey" FOREIGN KEY ("group") REFERENCES "public"."cost_group"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."farm"
    ADD CONSTRAINT "public_farm_ha_bridge_id_fkey" FOREIGN KEY ("ha_bridge_id") REFERENCES "public"."ha_bridges"("id");



ALTER TABLE ONLY "public"."farm"
    ADD CONSTRAINT "public_farm_sub_district_id_fkey" FOREIGN KEY ("sub_district_id") REFERENCES "public"."sub_district"("id");



ALTER TABLE ONLY "public"."farm"
    ADD CONSTRAINT "public_farm_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."farm_type"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."harvest"
    ADD CONSTRAINT "public_harvest_farm_id_fkey" FOREIGN KEY ("farm_id") REFERENCES "public"."farm"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."harvest"
    ADD CONSTRAINT "public_harvest_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profile"
    ADD CONSTRAINT "public_profile_group_fkey" FOREIGN KEY ("group") REFERENCES "public"."group"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profile"
    ADD CONSTRAINT "public_profile_sub_district_id_fkey" FOREIGN KEY ("sub_district_id") REFERENCES "public"."sub_district"("id");



ALTER TABLE ONLY "public"."quota"
    ADD CONSTRAINT "quota_group_fkey" FOREIGN KEY ("group") REFERENCES "public"."group"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."quota_item"
    ADD CONSTRAINT "quota_item_farm_id_fkey" FOREIGN KEY ("farm_id") REFERENCES "public"."farm"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."quota_item"
    ADD CONSTRAINT "quota_item_farm_type_id_fkey" FOREIGN KEY ("farm_type_id") REFERENCES "public"."farm_type"("id");



ALTER TABLE ONLY "public"."quota_item"
    ADD CONSTRAINT "quota_item_quota_id_fkey" FOREIGN KEY ("quota_id") REFERENCES "public"."quota"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."quota"
    ADD CONSTRAINT "quota_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_shop_province"
    ADD CONSTRAINT "shop_province_province_id_fkey" FOREIGN KEY ("province_id") REFERENCES "public"."province"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mp_shop_province"
    ADD CONSTRAINT "shop_province_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shop"
    ADD CONSTRAINT "shop_sub_district_id_fkey" FOREIGN KEY ("sub_district_id") REFERENCES "public"."sub_district"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shop"
    ADD CONSTRAINT "shop_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."standard"
    ADD CONSTRAINT "standard_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."standard_type"("id");



ALTER TABLE ONLY "public"."standard"
    ADD CONSTRAINT "standard_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tb_h_wallet"
    ADD CONSTRAINT "tb_h_wallet_reward_id_fkey" FOREIGN KEY ("reward_id") REFERENCES "public"."tb_m_reward"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tb_h_wallet"
    ADD CONSTRAINT "tb_h_wallet_transaction_id_fkey" FOREIGN KEY ("transaction_id") REFERENCES "public"."mp_order_sales"("order_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tb_h_wallet"
    ADD CONSTRAINT "tb_h_wallet_wallet_id_fkey" FOREIGN KEY ("wallet_id") REFERENCES "public"."tb_m_wallet"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tb_m_license"
    ADD CONSTRAINT "tb_m_license_license_type_fkey" FOREIGN KEY ("license_type") REFERENCES "public"."tb_r_license_type"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tb_m_license"
    ADD CONSTRAINT "tb_m_license_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tb_m_planting_cycles"
    ADD CONSTRAINT "tb_m_planting_cycles_farm_type_id_fkey" FOREIGN KEY ("farm_type_id") REFERENCES "public"."farm_type"("id");



ALTER TABLE ONLY "public"."tb_m_product_boost"
    ADD CONSTRAINT "tb_m_product_boost_boost_plan_id_fkey" FOREIGN KEY ("boost_plan_id") REFERENCES "public"."tb_m_mp_boost_plan"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."tb_m_product_boost"
    ADD CONSTRAINT "tb_m_product_boost_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."mp_product"("product_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tb_m_product_boost"
    ADD CONSTRAINT "tb_m_product_boost_shop_id_fkey" FOREIGN KEY ("shop_id") REFERENCES "public"."shop"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tb_m_product_boost"
    ADD CONSTRAINT "tb_m_product_boost_wallet_id_fkey" FOREIGN KEY ("wallet_id") REFERENCES "public"."tb_m_wallet"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."tb_m_wallet"
    ADD CONSTRAINT "tb_m_wallet_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profile"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tb_m_wallet"
    ADD CONSTRAINT "tb_m_wallet_wallet_type_fkey" FOREIGN KEY ("wallet_type") REFERENCES "public"."tb_r_wallet_type"("type") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ty_commands"
    ADD CONSTRAINT "ty_commands_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."ty_devices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ty_devices"
    ADD CONSTRAINT "ty_devices_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ty_sensor_detail"
    ADD CONSTRAINT "ty_sensor_detail_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."ty_devices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ty_sensors"
    ADD CONSTRAINT "ty_sensors_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."ty_devices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ty_sensors"
    ADD CONSTRAINT "ty_sensors_sensor_type_id_fkey" FOREIGN KEY ("sensor_type_id") REFERENCES "public"."ty_sensor_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_level_fkey" FOREIGN KEY ("user_level") REFERENCES "public"."user_levels"("user_level");



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_role_fkey" FOREIGN KEY ("user_role") REFERENCES "public"."user_roles"("id");



ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_user_subscription_fkey" FOREIGN KEY ("user_subscription") REFERENCES "public"."user_subscription"("id");



CREATE POLICY " All by owner and superadmin" ON "public"."profile" USING (("public"."rls_is_owner"("id") OR "public"."rls_is_superadmin"())) WITH CHECK (("public"."rls_is_owner"("id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "Admins can manage land types" ON "public"."dn_tb_m_land_type" USING (((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text") OR ((("auth"."jwt"() -> 'user_metadata'::"text") ->> 'role'::"text") = 'admin'::"text"))) WITH CHECK (((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text") OR ((("auth"."jwt"() -> 'user_metadata'::"text") ->> 'role'::"text") = 'admin'::"text")));



CREATE POLICY "All For Anon and Authenticated Users" ON "public"."mp_order_items" TO "anon", "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "All For Authenticated" ON "public"."tb_h_wallet" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "All For Logged In User With Check Only Themselves" ON "public"."dn_iot_supply_list" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "All by group admin on their own group" ON "public"."client" USING (((ARRAY["group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"()));



CREATE POLICY "All by group admin on their own group" ON "public"."client_order" USING (((ARRAY[( SELECT "client"."group"
   FROM "public"."client"
  WHERE ("client"."id" = "client_order"."client_id"))] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"())) WITH CHECK (((ARRAY[( SELECT "client"."group"
   FROM "public"."client"
  WHERE ("client"."id" = "client_order"."client_id"))] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"()));



CREATE POLICY "All by group admin on their own group" ON "public"."client_order_item" USING (((ARRAY[( SELECT "c"."group"
   FROM ("public"."client" "c"
     JOIN "public"."client_order" "co" ON (("co"."client_id" = "c"."id")))
  WHERE ("co"."id" = "client_order_item"."order_id"))] && ( SELECT "array_agg"("g"."id") AS "array_agg"
   FROM "public"."group" "g"
  WHERE (ARRAY["auth"."uid"()] && "g"."admin_id"))) AND "public"."rls_is_admin"())) WITH CHECK (((ARRAY[( SELECT "c"."group"
   FROM ("public"."client" "c"
     JOIN "public"."client_order" "co" ON (("co"."client_id" = "c"."id")))
  WHERE ("co"."id" = "client_order_item"."order_id"))] && ( SELECT "array_agg"("g"."id") AS "array_agg"
   FROM "public"."group" "g"
  WHERE (ARRAY["auth"."uid"()] && "g"."admin_id"))) AND "public"."rls_is_admin"()));



CREATE POLICY "All by group admin on their own group" ON "public"."order_history_file" USING (((ARRAY["group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"())) WITH CHECK (((ARRAY["group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"()));



CREATE POLICY "All by group admin on their own group" ON "public"."quota" USING (((ARRAY["group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"())) WITH CHECK (((ARRAY["group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"()));



CREATE POLICY "All by group admin on their own group" ON "public"."quota_item" USING (((ARRAY[( SELECT "quota"."group"
   FROM "public"."quota"
  WHERE ("quota"."id" = "quota_item"."quota_id"))] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"())) WITH CHECK (((ARRAY[( SELECT "quota"."group"
   FROM "public"."quota"
  WHERE ("quota"."id" = "quota_item"."quota_id"))] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"()));



CREATE POLICY "All by owner and super admin" ON "public"."cost" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "All by owner and superadmin" ON "public"."activity" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "All by owner and superadmin" ON "public"."comment" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"())) WITH CHECK (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "All by owner and superadmin" ON "public"."farm" USING ((("public"."rls_is_owner"("user_id") AND "public"."rls_is_farm_group_owner"("group")) OR "public"."rls_is_superadmin"()));



CREATE POLICY "All by owner and superadmin" ON "public"."product" USING ((("public"."rls_is_shop_owner"("shop_id") AND "public"."rls_is_farm_owner"("farm_id")) OR "public"."rls_is_superadmin"())) WITH CHECK ((("public"."rls_is_shop_owner"("shop_id") AND "public"."rls_is_farm_owner"("farm_id")) OR "public"."rls_is_superadmin"()));



CREATE POLICY "All by owner and superadmin" ON "public"."product_option" USING (("public"."rls_is_product_owner"("product_id") OR "public"."rls_is_superadmin"())) WITH CHECK (("public"."rls_is_product_owner"("product_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "All by owner and superadmin" ON "public"."shop" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"())) WITH CHECK (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "All by owner and superadmin" ON "public"."standard" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "All by superadmin" ON "public"."group" USING ("public"."rls_is_superadmin"()) WITH CHECK ("public"."rls_is_superadmin"());



CREATE POLICY "All commands for logged in users" ON "public"."mp_user_address" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "All for Authenticated user" ON "public"."mp_promotion" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "All for Authenticated users" ON "public"."mp_promotion_products" TO "anon", "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "All for logged in users" ON "public"."mp_basket" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Allow anonymous read access to comments" ON "public"."dn_tb_m_news_comment" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Allow anonymous read access to likes" ON "public"."dn_tb_m_news_like" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Allow anonymous read access to news" ON "public"."dn_tb_m_news" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Allow anonymous read access to price data" ON "public"."dn_tb_m_price" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to view external logs" ON "public"."dn_tb_m_external_log" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow service role full access to external logs" ON "public"."dn_tb_m_external_log" USING (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "Allow user registration" ON "public"."dn_tb_m_user" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_record"("user_id")));



CREATE POLICY "Authenticated users can do anything" ON "public"."dn_tb_m_community_memberships" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can do anything" ON "public"."dn_tb_m_news" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can do anything" ON "public"."dn_tb_m_news_comment" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can do anything" ON "public"."dn_tb_m_news_like" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can insert traceback" ON "public"."traceback" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can read basic profile info" ON "public"."profile" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can read land types" ON "public"."dn_tb_m_land_type" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can read public profile info" ON "public"."dn_tb_m_user" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can update traceback" ON "public"."traceback" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Delete by group admin on their own group" ON "public"."activity" FOR DELETE USING ((("user_id" IN ( SELECT "profile"."id"
   FROM "public"."profile"
  WHERE (ARRAY["profile"."group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
           FROM "public"."group"
          WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))))) AND "public"."rls_is_admin"()));



CREATE POLICY "Enable insert for authenticated users only" ON "public"."activity_type" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."farm_type" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."news" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."standard_type" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."sub_district" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."maintenance" FOR SELECT USING (true);



CREATE POLICY "Enable read for users based on user_id" ON "public"."quota" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Insert by group admin on their own group" ON "public"."activity" FOR INSERT WITH CHECK ((("user_id" IN ( SELECT "profile"."id"
   FROM "public"."profile"
  WHERE (ARRAY["profile"."group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
           FROM "public"."group"
          WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))))) AND "public"."rls_is_admin"()));



CREATE POLICY "Price managers can create price data" ON "public"."dn_tb_m_price" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_can_manage_prices"()));



CREATE POLICY "Price managers can delete price data" ON "public"."dn_tb_m_price" FOR DELETE USING ((("auth"."uid"() IS NOT NULL) AND "public"."user_can_manage_prices"()));



CREATE POLICY "Price managers can update price data" ON "public"."dn_tb_m_price" FOR UPDATE USING ((("auth"."uid"() IS NOT NULL) AND "public"."user_can_manage_prices"())) WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_can_manage_prices"()));



CREATE POLICY "Public can read comments" ON "public"."dn_tb_m_news_comment" FOR SELECT USING (true);



CREATE POLICY "Public can read energy ef" ON "public"."dn_tb_m_cbf_energy_ef" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Public can read likes" ON "public"."dn_tb_m_news_like" FOR SELECT USING (true);



CREATE POLICY "Public can read news" ON "public"."dn_tb_m_news" FOR SELECT USING (true);



CREATE POLICY "Public can read price data" ON "public"."dn_tb_m_price" FOR SELECT USING (true);



CREATE POLICY "Public can read traceback" ON "public"."traceback" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Public can read transport ef" ON "public"."dn_tb_m_cbf_transport_ef" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Select For Anon and Authenticated Users" ON "public"."master_product_category" FOR SELECT TO "anon", "authenticated" USING (true);



CREATE POLICY "Select by owner" ON "public"."quota_item" FOR SELECT USING (("quota_id" IN ( SELECT "quota"."id"
   FROM "public"."quota"
  WHERE ("quota"."user_id" = "auth"."uid"()))));



CREATE POLICY "Select for Public" ON "public"."mp_promotion_products" FOR SELECT USING (true);



CREATE POLICY "Select for public" ON "public"."mp_promotion" FOR SELECT USING (true);



CREATE POLICY "Service role full access" ON "public"."dn_tb_m_user" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on comments" ON "public"."dn_tb_m_news_comment" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on crop costs" ON "public"."dn_actions_crop_cost" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on crop fruit bloom" ON "public"."dn_actions_crop_fruit_bloom" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on crop stages" ON "public"."dn_actions_crop_stages" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on crop yields" ON "public"."dn_actions_crop_yield" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on crops" ON "public"."dn_actions_crop" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on farm" ON "public"."dn_tb_m_farm" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on land" ON "public"."dn_tb_m_land" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on likes" ON "public"."dn_tb_m_news_like" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on news" ON "public"."dn_tb_m_news" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on prices" ON "public"."dn_tb_m_price" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Service role full access on profile" ON "public"."profile" USING ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'role'::"text") = 'service_role'::"text"));



CREATE POLICY "Update by owner" ON "public"."quota_item" FOR UPDATE USING (("quota_id" IN ( SELECT "quota"."id"
   FROM "public"."quota"
  WHERE ("quota"."user_id" = "auth"."uid"())))) WITH CHECK (("quota_id" IN ( SELECT "quota"."id"
   FROM "public"."quota"
  WHERE ("quota"."user_id" = "auth"."uid"()))));



CREATE POLICY "Users can create comments" ON "public"."dn_tb_m_news_comment" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND (("user_id" IS NULL) OR "public"."user_owns_record"("user_id"))));



CREATE POLICY "Users can create crop cost records for own crops" ON "public"."dn_actions_crop_cost" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_crop_by_id"(("app_crop_id")::"text")));



CREATE POLICY "Users can create crop fruit bloom records for own crops" ON "public"."dn_actions_crop_fruit_bloom" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_crop_by_id"(("app_crop_id")::"text")));



CREATE POLICY "Users can create crop records on own land" ON "public"."dn_actions_crop" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_crop"(("app_land_id")::"text")));



CREATE POLICY "Users can create crop stage records for own crops" ON "public"."dn_actions_crop_stages" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_crop_by_id"(("app_crop_id")::"text")));



CREATE POLICY "Users can create crop yield records for own crops" ON "public"."dn_actions_crop_yield" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_crop_by_id"(("app_crop_id")::"text")));



CREATE POLICY "Users can create likes" ON "public"."dn_tb_m_news_like" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_record"("user_id")));



CREATE POLICY "Users can create news" ON "public"."dn_tb_m_news" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_record"("user_id")));



CREATE POLICY "Users can create own farm records" ON "public"."dn_tb_m_farm" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_farm"("farmer_id")));



CREATE POLICY "Users can create own land records" ON "public"."dn_tb_m_land" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND "public"."user_owns_land"("farmer_id")));



CREATE POLICY "Users can delete own comments" ON "public"."dn_tb_m_news_comment" FOR DELETE USING ("public"."user_owns_record"("user_id"));



CREATE POLICY "Users can delete own community" ON "public"."dn_tb_m_community" FOR DELETE USING ("public"."user_owns_record"("user_id"));



CREATE POLICY "Users can delete own crop cost records" ON "public"."dn_actions_crop_cost" FOR DELETE USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can delete own crop fruit bloom records" ON "public"."dn_actions_crop_fruit_bloom" FOR DELETE USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can delete own crop records" ON "public"."dn_actions_crop" FOR DELETE USING ("public"."user_owns_crop"(("app_land_id")::"text"));



CREATE POLICY "Users can delete own crop stage records" ON "public"."dn_actions_crop_stages" FOR DELETE USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can delete own crop yield records" ON "public"."dn_actions_crop_yield" FOR DELETE USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can delete own farm records" ON "public"."dn_tb_m_farm" FOR DELETE USING ("public"."user_owns_farm"("farmer_id"));



CREATE POLICY "Users can delete own land records" ON "public"."dn_tb_m_land" FOR DELETE USING ("public"."user_owns_land"("farmer_id"));



CREATE POLICY "Users can delete own likes" ON "public"."dn_tb_m_news_like" FOR DELETE USING ("public"."user_owns_record"("user_id"));



CREATE POLICY "Users can delete own news" ON "public"."dn_tb_m_news" FOR DELETE USING ("public"."user_owns_record"("user_id"));



CREATE POLICY "Users can delete their own cbf chemical" ON "public"."dn_tb_r_cbf_chemical" FOR DELETE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_chemical"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can delete their own cbf electric" ON "public"."dn_tb_r_cbf_electric" FOR DELETE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_electric"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can delete their own cbf fertilizer" ON "public"."dn_tb_r_cbf_fertilizer" FOR DELETE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fertilizer"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can delete their own cbf fuel" ON "public"."dn_tb_r_cbf_fuel" FOR DELETE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fuel"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can delete their own cbf material" ON "public"."dn_tb_r_cbf_material" FOR DELETE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_material"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can delete their own certifications" ON "public"."dn_tb_m_certify" FOR UPDATE USING (((("user_id")::"text" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))) AND ("is_deleted" = false))) WITH CHECK (((("user_id")::"text" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))) AND ("is_deleted" = true)));



CREATE POLICY "Users can delete their own dn_tb_m_cbf" ON "public"."dn_tb_m_cbf" FOR DELETE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can insert own profile" ON "public"."profile" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert their own cbf chemical" ON "public"."dn_tb_r_cbf_chemical" FOR INSERT TO "anon", "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_chemical"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can insert their own cbf electric" ON "public"."dn_tb_r_cbf_electric" FOR INSERT TO "anon", "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_electric"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can insert their own cbf fertilizer" ON "public"."dn_tb_r_cbf_fertilizer" FOR INSERT TO "anon", "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fertilizer"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can insert their own cbf fuel" ON "public"."dn_tb_r_cbf_fuel" FOR INSERT TO "anon", "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fuel"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can insert their own cbf material" ON "public"."dn_tb_r_cbf_material" FOR INSERT TO "anon", "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_material"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can insert their own certifications" ON "public"."dn_tb_m_certify" FOR INSERT WITH CHECK ((("user_id")::"text" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))));



CREATE POLICY "Users can insert their own community" ON "public"."dn_tb_m_community" FOR INSERT WITH CHECK (("user_id" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))));



CREATE POLICY "Users can insert their own dn_tb_m_cbf" ON "public"."dn_tb_m_cbf" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read own crop cost records" ON "public"."dn_actions_crop_cost" FOR SELECT USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can read own crop fruit bloom records" ON "public"."dn_actions_crop_fruit_bloom" FOR SELECT USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can read own crop records" ON "public"."dn_actions_crop" FOR SELECT USING ("public"."user_owns_crop"(("app_land_id")::"text"));



CREATE POLICY "Users can read own crop stage records" ON "public"."dn_actions_crop_stages" FOR SELECT USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can read own crop yield records" ON "public"."dn_actions_crop_yield" FOR SELECT USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can read own farm records" ON "public"."dn_tb_m_farm" FOR SELECT USING ("public"."user_owns_farm"("farmer_id"));



CREATE POLICY "Users can read own land records" ON "public"."dn_tb_m_land" FOR SELECT USING ("public"."user_owns_land"("farmer_id"));



CREATE POLICY "Users can read own profile" ON "public"."dn_tb_m_user" FOR SELECT USING ("public"."user_owns_record"("user_id"));



CREATE POLICY "Users can read own profile" ON "public"."profile" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can read their own cbf chemical" ON "public"."dn_tb_r_cbf_chemical" FOR SELECT TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_chemical"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can read their own cbf electric" ON "public"."dn_tb_r_cbf_electric" FOR SELECT TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_electric"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can read their own cbf fertilizer" ON "public"."dn_tb_r_cbf_fertilizer" FOR SELECT TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fertilizer"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can read their own cbf fuel" ON "public"."dn_tb_r_cbf_fuel" FOR SELECT TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fuel"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can read their own cbf material" ON "public"."dn_tb_r_cbf_material" FOR SELECT TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_material"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can read their own dn_tb_m_cbf" ON "public"."dn_tb_m_cbf" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update own crop cost records" ON "public"."dn_actions_crop_cost" FOR UPDATE USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text")) WITH CHECK ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can update own crop fruit bloom records" ON "public"."dn_actions_crop_fruit_bloom" FOR UPDATE USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text")) WITH CHECK ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can update own crop records" ON "public"."dn_actions_crop" FOR UPDATE USING ("public"."user_owns_crop"(("app_land_id")::"text")) WITH CHECK ("public"."user_owns_crop"(("app_land_id")::"text"));



CREATE POLICY "Users can update own crop stage records" ON "public"."dn_actions_crop_stages" FOR UPDATE USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text")) WITH CHECK ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can update own crop yield records" ON "public"."dn_actions_crop_yield" FOR UPDATE USING ("public"."user_owns_crop_by_id"(("app_crop_id")::"text")) WITH CHECK ("public"."user_owns_crop_by_id"(("app_crop_id")::"text"));



CREATE POLICY "Users can update own farm records" ON "public"."dn_tb_m_farm" FOR UPDATE USING ("public"."user_owns_farm"("farmer_id")) WITH CHECK ("public"."user_owns_farm"("farmer_id"));



CREATE POLICY "Users can update own land records" ON "public"."dn_tb_m_land" FOR UPDATE USING ("public"."user_owns_land"("farmer_id")) WITH CHECK ("public"."user_owns_land"("farmer_id"));



CREATE POLICY "Users can update own news" ON "public"."dn_tb_m_news" FOR UPDATE USING ("public"."user_owns_record"("user_id")) WITH CHECK ("public"."user_owns_record"("user_id"));



CREATE POLICY "Users can update own profile" ON "public"."dn_tb_m_user" FOR UPDATE USING ("public"."user_owns_record"("user_id")) WITH CHECK ("public"."user_owns_record"("user_id"));



CREATE POLICY "Users can update own profile" ON "public"."profile" FOR UPDATE USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can update their own cbf chemical" ON "public"."dn_tb_r_cbf_chemical" FOR UPDATE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_chemical"."cbf_id") AND ("m"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_chemical"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can update their own cbf electric" ON "public"."dn_tb_r_cbf_electric" FOR UPDATE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_electric"."cbf_id") AND ("m"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_electric"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can update their own cbf fertilizer" ON "public"."dn_tb_r_cbf_fertilizer" FOR UPDATE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fertilizer"."cbf_id") AND ("m"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fertilizer"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can update their own cbf fuel" ON "public"."dn_tb_r_cbf_fuel" FOR UPDATE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fuel"."cbf_id") AND ("m"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_fuel"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can update their own cbf material" ON "public"."dn_tb_r_cbf_material" FOR UPDATE TO "anon", "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_material"."cbf_id") AND ("m"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."dn_tb_m_cbf" "m"
  WHERE (("m"."cbf_id" = "dn_tb_r_cbf_material"."cbf_id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can update their own certifications" ON "public"."dn_tb_m_certify" FOR UPDATE USING (((("user_id")::"text" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))) AND ("is_deleted" = false))) WITH CHECK ((("user_id")::"text" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))));



CREATE POLICY "Users can update their own community" ON "public"."dn_tb_m_community" FOR UPDATE USING (("user_id" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"())))) WITH CHECK (("user_id" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))));



CREATE POLICY "Users can update their own dn_tb_m_cbf" ON "public"."dn_tb_m_cbf" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view their own certifications" ON "public"."dn_tb_m_certify" FOR SELECT USING (((("user_id")::"text" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))) AND ("is_deleted" = false)));



CREATE POLICY "Users can view their own community" ON "public"."dn_tb_m_community" FOR SELECT USING (("user_id" = ( SELECT "p"."dn_app_id"
   FROM "public"."profile" "p"
  WHERE ("p"."id" = "auth"."uid"()))));



ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."activity_type" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "all by admin" ON "public"."ty_commands" USING ("public"."rls_is_admin"()) WITH CHECK ("public"."rls_is_admin"());



CREATE POLICY "all by admin" ON "public"."ty_devices" USING ("public"."rls_is_admin"()) WITH CHECK ("public"."rls_is_admin"());



CREATE POLICY "all by admin" ON "public"."ty_sensor_types" USING ("public"."rls_is_admin"()) WITH CHECK ("public"."rls_is_admin"());



CREATE POLICY "all by admin" ON "public"."ty_sensors" USING ("public"."rls_is_admin"()) WITH CHECK ("public"."rls_is_admin"());



CREATE POLICY "all by owner and superadmin" ON "public"."cost_group" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "all by owner and superadmin" ON "public"."farm_group" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "all by owner and superadmin" ON "public"."harvest" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "all by owner and superadmin" ON "public"."pre_activity" USING (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"())) WITH CHECK (("public"."rls_is_owner"("user_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "all by superadmin" ON "public"."user_levels" USING ("public"."rls_is_superadmin"()) WITH CHECK ("public"."rls_is_superadmin"());



CREATE POLICY "all for authenticated" ON "public"."mp_delivery_rate" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for authenticated" ON "public"."mp_shop_province" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for authenticated" ON "public"."tb_m_license" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_basket_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_chat_members" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_chat_message_attachments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_chat_messages" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_chat_room_reads" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_chat_rooms" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_order_disputes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_payout_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_platform_payout_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."mp_seller_violations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for logged in users" ON "public"."shop" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "all for public" ON "public"."mp_delivery_method" USING (true) WITH CHECK (true);



CREATE POLICY "all for public" ON "public"."mp_delivery_rate" FOR SELECT USING (true);



CREATE POLICY "all for public" ON "public"."mp_product" USING (true);



CREATE POLICY "all for public" ON "public"."mp_product_variant" USING (true);



CREATE POLICY "all for public" ON "public"."mp_review_media" USING (true) WITH CHECK (true);



CREATE POLICY "all for public" ON "public"."mp_reviews" USING (true) WITH CHECK (true);



CREATE POLICY "all for public" ON "public"."mp_shop_address" USING (true) WITH CHECK (true);



CREATE POLICY "all_for_login_user" ON "public"."tb_m_wallet" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow anon" ON "public"."ty_devices" FOR SELECT TO "anon" USING (true);



CREATE POLICY "allow_anon_key" ON "public"."ty_sensor_detail" FOR SELECT USING (true);



CREATE POLICY "allow_edge_function_anon_key" ON "public"."master_product_category" TO "anon" USING (true);



CREATE POLICY "allow_edge_function_anon_key" ON "public"."mp_order_items" TO "anon" USING (true);



CREATE POLICY "allow_edge_function_anon_key" ON "public"."mp_order_sales" TO "anon", "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."client" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_order" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_order_item" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comment" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cost" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cost_group" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."debug_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "device_tokens_delete_own" ON "public"."dn_tb_m_device_tokens" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "device_tokens_insert_own" ON "public"."dn_tb_m_device_tokens" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "device_tokens_select_own" ON "public"."dn_tb_m_device_tokens" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "device_tokens_update_own" ON "public"."dn_tb_m_device_tokens" FOR UPDATE USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."dn_actions_crop" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_actions_crop_cost" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_actions_crop_fruit_bloom" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_actions_crop_stages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_actions_crop_yield" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_cbf" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_cbf_energy_ef" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_cbf_transport_ef" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_community" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_community_memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_device_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_external_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_farm" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_iot_hubs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_land" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_land_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_news" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_news_comment" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_news_like" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_price" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_m_user" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_r_cbf_chemical" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_r_cbf_electric" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_r_cbf_fertilizer" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_r_cbf_fuel" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dn_tb_r_cbf_material" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "edge-function-anon" ON "public"."master_bank_list" TO "anon", "authenticated" USING (true);



CREATE POLICY "edge-function-anon" ON "public"."mp_payment_method" TO "anon", "authenticated" USING (true);



CREATE POLICY "edge-function-anon" ON "public"."mp_shop_payment" TO "anon", "authenticated" USING (true);



CREATE POLICY "edge-function-anon" ON "public"."shop" TO "anon" USING (true);



ALTER TABLE "public"."farm" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."farm_group" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."farm_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."group" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ha_bridges" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ha_bridges - all by owner or superadmin" ON "public"."ha_bridges" USING (("public"."rls_is_owner"("owner_id") OR "public"."rls_is_superadmin"())) WITH CHECK (("public"."rls_is_owner"("owner_id") OR "public"."rls_is_superadmin"()));



CREATE POLICY "ha_bridges - select by shared to user" ON "public"."ha_bridges" FOR SELECT USING (((("auth"."jwt"() ->> 'sub'::"text"))::"uuid" = ANY ("shared_to")));



CREATE POLICY "ha_bridges - select by users and group users" ON "public"."ha_bridges" FOR SELECT USING (("owner_id" IN ( SELECT "profile"."id"
   FROM "public"."profile")));



ALTER TABLE "public"."ha_command" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ha_command - all by owner of ha_bridges and superadmin" ON "public"."ha_command" USING (("bridge_id" IN ( SELECT "ha_bridges"."id"
   FROM "public"."ha_bridges"
  WHERE ("public"."rls_is_superadmin"() OR "public"."rls_is_owner"("ha_bridges"."owner_id"))))) WITH CHECK (("bridge_id" IN ( SELECT "ha_bridges"."id"
   FROM "public"."ha_bridges"
  WHERE ("public"."rls_is_superadmin"() OR "public"."rls_is_owner"("ha_bridges"."owner_id")))));



ALTER TABLE "public"."ha_entities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ha_entities - delete by owner of ha_bridges" ON "public"."ha_entities" FOR DELETE USING (("bridge_id" IN ( SELECT "public"."rls_get_ha_entities_can_be_modified"() AS "rls_get_ha_entities_can_be_modified")));



CREATE POLICY "ha_entities - insert by owner of ha_bridges" ON "public"."ha_entities" FOR INSERT WITH CHECK (("bridge_id" IN ( SELECT "public"."rls_get_ha_entities_can_be_modified"() AS "rls_get_ha_entities_can_be_modified")));



CREATE POLICY "ha_entities - select by sharing in ha_sharing" ON "public"."ha_entities" FOR SELECT USING (("bridge_id" IN ( SELECT "ha_bridges"."id"
   FROM "public"."ha_bridges")));



CREATE POLICY "ha_entities - update by owner of ha_bridges" ON "public"."ha_entities" FOR UPDATE USING (("bridge_id" IN ( SELECT "public"."rls_get_ha_entities_can_be_modified"() AS "rls_get_ha_entities_can_be_modified")));



ALTER TABLE "public"."ha_states" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ha_states - delete by owner of ha_bridges" ON "public"."ha_states" FOR DELETE USING (("state_ref" IN ( SELECT "public"."rls_get_ha_states_can_be_modified"() AS "rls_get_ha_states_can_be_modified")));



CREATE POLICY "ha_states - insert by owner of ha_bridges" ON "public"."ha_states" FOR INSERT WITH CHECK (("state_ref" IN ( SELECT "public"."rls_get_ha_states_can_be_modified"() AS "rls_get_ha_states_can_be_modified")));



CREATE POLICY "ha_states - select by sharing in ha_sharing" ON "public"."ha_states" FOR SELECT USING (("state_ref" IN ( SELECT "ha_entities"."state_ref"
   FROM "public"."ha_entities")));



CREATE POLICY "ha_states - update by owner of ha_bridges" ON "public"."ha_states" FOR UPDATE USING (("state_ref" IN ( SELECT "public"."rls_get_ha_states_can_be_modified"() AS "rls_get_ha_states_can_be_modified")));



ALTER TABLE "public"."harvest" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "insert by owner" ON "public"."quota_item" FOR INSERT WITH CHECK (("quota_id" IN ( SELECT "quota"."id"
   FROM "public"."quota"
  WHERE ("quota"."user_id" = "auth"."uid"()))));



CREATE POLICY "insert by owner" ON "public"."ty_commands" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ty_devices"
  WHERE ("ty_commands"."device_id" = "ty_devices"."id"))));



ALTER TABLE "public"."maintenance" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_bank_list" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_delivery_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_product_category" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_product_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_basket" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_basket_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_chat_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_chat_message_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_chat_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_chat_room_reads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_chat_rooms" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_delivery_method" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_delivery_rate" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_order_disputes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_order_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_order_sales" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_payment_method" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_payout_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_platform_payout_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_product" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_product_variant" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_promotion" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_promotion_products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_review_media" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_reviews" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_seller_violations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_shop_address" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_shop_payment" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_shop_province" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_tb_m_dispute_reason" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_tb_m_order_status" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mp_user_address" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notification" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_select_own" ON "public"."dn_tb_m_notifications" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "notifications_update_own" ON "public"."dn_tb_m_notifications" FOR UPDATE USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."order_history_file" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pre_activity" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_option" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profile" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profile - all by admin" ON "public"."profile" USING (("public"."rls_is_admin"() OR true)) WITH CHECK (("public"."rls_is_admin"() OR true));



ALTER TABLE "public"."quota" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."quota_item" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "select by admin_id" ON "public"."group" FOR SELECT USING ((ARRAY["auth"."uid"()] && "admin_id"));



CREATE POLICY "select by any logged in users" ON "public"."debug_log" FOR SELECT USING (true);



CREATE POLICY "select by authenticated user" ON "public"."ty_sensor_types" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "select by device owner" ON "public"."ty_devices" FOR SELECT USING ("public"."rls_is_owner"("owner_id"));



CREATE POLICY "select by group admin on their own group" ON "public"."activity" FOR SELECT USING ((("user_id" IN ( SELECT "profile"."id"
   FROM "public"."profile"
  WHERE (ARRAY["profile"."group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
           FROM "public"."group"
          WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))))) AND "public"."rls_is_admin"()));



CREATE POLICY "select by group admin on their own group" ON "public"."farm" FOR SELECT USING ((("user_id" IN ( SELECT "profile"."id"
   FROM "public"."profile"
  WHERE (ARRAY["profile"."group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
           FROM "public"."group"
          WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))))) AND "public"."rls_is_admin"()));



CREATE POLICY "select by group admin on their own group" ON "public"."harvest" FOR SELECT USING ((("user_id" IN ( SELECT "profile"."id"
   FROM "public"."profile"
  WHERE (ARRAY["profile"."group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
           FROM "public"."group"
          WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))))) AND "public"."rls_is_admin"()));



CREATE POLICY "select by group admin on their own group" ON "public"."profile" FOR SELECT USING (((ARRAY["group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"()));



CREATE POLICY "select by owner" ON "public"."notification" FOR SELECT USING (((ARRAY["auth"."uid"()] && "user_id") OR ("user_id" IS NULL)));



CREATE POLICY "select by owner" ON "public"."ty_commands" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ty_devices"
  WHERE ("ty_commands"."device_id" = "ty_devices"."id"))));



CREATE POLICY "select by sensor owner" ON "public"."ty_sensors" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ty_devices"
  WHERE ("ty_sensors"."device_id" = "ty_devices"."id"))));



ALTER TABLE "public"."shop" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."standard" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."standard_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tb_h_wallet" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tb_m_license" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tb_m_partners" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tb_m_planting_cycles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tb_m_reward" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tb_m_wallet" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tb_r_license_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tb_r_wallet_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."traceback" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ty_commands" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ty_devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ty_sensor_detail" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ty_sensor_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ty_sensors" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "update by admin_id" ON "public"."group" FOR UPDATE USING ((ARRAY["auth"."uid"()] && "admin_id")) WITH CHECK ((ARRAY["auth"."uid"()] && "admin_id"));



CREATE POLICY "update by group admin on their own group" ON "public"."profile" FOR UPDATE USING (((ARRAY["group"] && ( SELECT "array_agg"("group"."id") AS "array_agg"
   FROM "public"."group"
  WHERE (ARRAY["auth"."uid"()] && "group"."admin_id"))) AND "public"."rls_is_admin"()));



ALTER TABLE "public"."user_levels" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_log - all by superadmin" ON "public"."user_log" USING ("public"."rls_is_superadmin"()) WITH CHECK ("public"."rls_is_superadmin"());



CREATE POLICY "user_log - select by owner" ON "public"."user_log" FOR SELECT USING ("public"."rls_is_owner"("user_id"));



ALTER TABLE "public"."user_permissions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_permissions - all by superadmin" ON "public"."user_permissions" USING ((((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'user_level'::"text"))::integer > 2)) WITH CHECK ((((("auth"."jwt"() -> 'app_metadata'::"text") ->> 'user_level'::"text"))::integer > 2));



CREATE POLICY "user_permissions - select by owner" ON "public"."user_permissions" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_roles - all by superadmin" ON "public"."user_roles" USING ("public"."rls_is_superadmin"()) WITH CHECK ("public"."rls_is_superadmin"());



ALTER TABLE "public"."user_subscription" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."dn_iot_devices";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."dn_iot_sensor";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."dn_iot_supply_list";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."dn_tb_m_notifications";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."ha_command";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."ha_entities";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."ha_states";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."mp_chat_messages";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."ty_commands";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."ty_sensors";









REVOKE USAGE ON SCHEMA "public" FROM PUBLIC;
GRANT ALL ON SCHEMA "public" TO PUBLIC;
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";











































































GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";















































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































































GRANT ALL ON FUNCTION "public"."aggregate_daily_usage"("target_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."aggregate_daily_usage"("target_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."aggregate_daily_usage"("target_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_cancel_order"("p_dispute_id" "uuid", "p_admin_id" "uuid", "p_internal_notes" "text", "p_public_resolution" "text", OUT "r_order_id" "uuid", OUT "r_shop_line_id" "text", OUT "r_customer_line_id" "text", OUT "r_order_code" "text", OUT "r_strike_points" integer, OUT "r_total_strike_points" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."approve_cancel_order"("p_dispute_id" "uuid", "p_admin_id" "uuid", "p_internal_notes" "text", "p_public_resolution" "text", OUT "r_order_id" "uuid", OUT "r_shop_line_id" "text", OUT "r_customer_line_id" "text", OUT "r_order_code" "text", OUT "r_strike_points" integer, OUT "r_total_strike_points" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_cancel_order"("p_dispute_id" "uuid", "p_admin_id" "uuid", "p_internal_notes" "text", "p_public_resolution" "text", OUT "r_order_id" "uuid", OUT "r_shop_line_id" "text", OUT "r_customer_line_id" "text", OUT "r_order_code" "text", OUT "r_strike_points" integer, OUT "r_total_strike_points" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "postgres";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "anon";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "service_role";



GRANT ALL ON FUNCTION "public"."cc_delete_claim"("uid" "uuid", "claim" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."cc_delete_claim"("uid" "uuid", "claim" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cc_delete_claim"("uid" "uuid", "claim" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cc_get_claim"("uid" "uuid", "claim" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."cc_get_claim"("uid" "uuid", "claim" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cc_get_claim"("uid" "uuid", "claim" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cc_get_claims"("uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."cc_get_claims"("uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cc_get_claims"("uid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cc_get_my_claim"("claim" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."cc_get_my_claim"("claim" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cc_get_my_claim"("claim" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cc_get_my_claims"() TO "anon";
GRANT ALL ON FUNCTION "public"."cc_get_my_claims"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cc_get_my_claims"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cc_is_claims_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."cc_is_claims_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cc_is_claims_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cc_set_claim"("uid" "uuid", "claim" "text", "value" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."cc_set_claim"("uid" "uuid", "claim" "text", "value" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cc_set_claim"("uid" "uuid", "claim" "text", "value" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_relay_boolean"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_relay_boolean"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_relay_boolean"() TO "service_role";



GRANT ALL ON PROCEDURE "public"."cleanup_unpaid_orders_24h"() TO "anon";
GRANT ALL ON PROCEDURE "public"."cleanup_unpaid_orders_24h"() TO "authenticated";
GRANT ALL ON PROCEDURE "public"."cleanup_unpaid_orders_24h"() TO "service_role";



GRANT ALL ON FUNCTION "public"."count_delivery_pending_active"("p_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."count_delivery_pending_active"("p_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."count_delivery_pending_active"("p_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_product_boost"("p_product_id" "uuid", "p_shop_id" "uuid", "p_wallet_id" bigint, "p_boost_plan_id" bigint, "p_points_cost" bigint, "p_duration_hours" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_product_boost"("p_product_id" "uuid", "p_shop_id" "uuid", "p_wallet_id" bigint, "p_boost_plan_id" bigint, "p_points_cost" bigint, "p_duration_hours" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_product_boost"("p_product_id" "uuid", "p_shop_id" "uuid", "p_wallet_id" bigint, "p_boost_plan_id" bigint, "p_points_cost" bigint, "p_duration_hours" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cron_nightly_vacuum"() TO "anon";
GRANT ALL ON FUNCTION "public"."cron_nightly_vacuum"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cron_nightly_vacuum"() TO "service_role";



GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "postgres";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "anon";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."debug_auth"() TO "anon";
GRANT ALL ON FUNCTION "public"."debug_auth"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."debug_auth"() TO "service_role";



GRANT ALL ON FUNCTION "public"."decrement_news_comment_count"("news_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."decrement_news_comment_count"("news_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decrement_news_comment_count"("news_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."decrement_news_like_count"("news_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."decrement_news_like_count"("news_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decrement_news_like_count"("news_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_old_pre_activity"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_old_pre_activity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_old_pre_activity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "postgres";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "anon";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "service_role";



GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_device_serial"("length" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."generate_device_serial"("length" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_device_serial"("length" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_amphoes"("p_pro_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."get_amphoes"("p_pro_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_amphoes"("p_pro_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_by_postcode"("p_postcode" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."get_by_postcode"("p_postcode" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_by_postcode"("p_postcode" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_cbf_summary_simple_v1"("p_crop_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_cbf_summary_simple_v1"("p_crop_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_cbf_summary_simple_v1"("p_crop_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pending_commands"("_batch_size" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_pending_commands"("_batch_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_commands"("_batch_size" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_product_detail"("p_product_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_product_detail"("p_product_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_product_detail"("p_product_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_products"("_search" "text", "_shop_id" "uuid", "_category_ids" bigint[], "_rating" integer[], "_region" "text"[], "_availability" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_products"("_search" "text", "_shop_id" "uuid", "_category_ids" bigint[], "_rating" integer[], "_region" "text"[], "_availability" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_products"("_search" "text", "_shop_id" "uuid", "_category_ids" bigint[], "_rating" integer[], "_region" "text"[], "_availability" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_products_paginated"("_search" "text", "_shop_id" "uuid", "_category_ids" bigint[], "_rating" integer[], "_region" "text"[], "_availability" "text", "_limit" integer, "_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_products_paginated"("_search" "text", "_shop_id" "uuid", "_category_ids" bigint[], "_rating" integer[], "_region" "text"[], "_availability" "text", "_limit" integer, "_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_products_paginated"("_search" "text", "_shop_id" "uuid", "_category_ids" bigint[], "_rating" integer[], "_region" "text"[], "_availability" "text", "_limit" integer, "_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_provinces"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_provinces"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_provinces"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_shop_total_orders"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_shop_total_orders"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_shop_total_orders"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_tambons"("p_pro_id" bigint, "p_amp_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."get_tambons"("p_pro_id" bigint, "p_amp_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tambons"("p_pro_id" bigint, "p_amp_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_traceback_durian"("p_crop_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_traceback_durian"("p_crop_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_traceback_durian"("p_crop_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_orders"("p_user_id" "uuid", "p_order_ids" "uuid"[], "p_shop_id" "uuid", "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_orders"("p_user_id" "uuid", "p_order_ids" "uuid"[], "p_shop_id" "uuid", "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_orders"("p_user_id" "uuid", "p_order_ids" "uuid"[], "p_shop_id" "uuid", "p_limit" integer, "p_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_auth_user_created"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_auth_user_created"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_auth_user_created"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_ha_bridges_inserted"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_ha_bridges_inserted"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_ha_bridges_inserted"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_ha_states_inserted"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_ha_states_inserted"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_ha_states_inserted"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_profile_insert_or_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_profile_insert_or_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_profile_insert_or_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_user_permissions_insert_or_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_user_permissions_insert_or_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_user_permissions_insert_or_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_news_comment_count"("news_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_news_comment_count"("news_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_news_comment_count"("news_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_news_like_count"("news_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_news_like_count"("news_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_news_like_count"("news_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "postgres";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "service_role";



GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "postgres";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "anon";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "authenticated";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "service_role";



GRANT ALL ON FUNCTION "public"."misc_get_jwt_claims"() TO "anon";
GRANT ALL ON FUNCTION "public"."misc_get_jwt_claims"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."misc_get_jwt_claims"() TO "service_role";



GRANT ALL ON FUNCTION "public"."mp_order_sales_before_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."mp_order_sales_before_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mp_order_sales_before_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "postgres";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "anon";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "service_role";



GRANT ALL ON FUNCTION "public"."perform_weekly_strike_decay"() TO "anon";
GRANT ALL ON FUNCTION "public"."perform_weekly_strike_decay"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."perform_weekly_strike_decay"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_activity_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_activity_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_activity_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_activity_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_activity_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_activity_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_comment_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_comment_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_comment_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_cost_group_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_cost_group_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_cost_group_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_cost_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_cost_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_cost_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_cost_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_cost_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_cost_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_farm_group_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_farm_group_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_farm_group_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_farm_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_farm_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_farm_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_farm_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_farm_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_farm_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_group_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_group_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_group_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_harvest_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_harvest_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_harvest_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_harvest_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_harvest_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_harvest_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_media_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_media_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_media_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_product_option_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_product_option_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_product_option_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_product_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_product_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_product_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_profile_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_profile_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_profile_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_shop_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_shop_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_shop_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."release_seller_funds"("p_batch_size" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."release_seller_funds"("p_batch_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."release_seller_funds"("p_batch_size" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_get_activity_can_be_modified"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_get_activity_can_be_modified"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_get_activity_can_be_modified"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_get_field_can_be_modified"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_get_field_can_be_modified"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_get_field_can_be_modified"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_get_groups_for_group_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_get_groups_for_group_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_get_groups_for_group_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_get_ha_entities_can_be_modified"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_get_ha_entities_can_be_modified"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_get_ha_entities_can_be_modified"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_get_ha_states_can_be_modified"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_get_ha_states_can_be_modified"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_get_ha_states_can_be_modified"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_is_farm_group_owner"("_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."rls_is_farm_group_owner"("_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_is_farm_group_owner"("_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_is_farm_owner"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."rls_is_farm_owner"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_is_farm_owner"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_is_group_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_is_group_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_is_group_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_is_owner"("_uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rls_is_owner"("_uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_is_owner"("_uid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_is_product_owner"("_product_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rls_is_product_owner"("_product_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_is_product_owner"("_product_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_is_shop_owner"("_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rls_is_shop_owner"("_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_is_shop_owner"("_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_is_superadmin"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_is_superadmin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_is_superadmin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."to_base36"("n" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."to_base36"("n" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."to_base36"("n" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_old_pre_activity_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_old_pre_activity_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_old_pre_activity_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."user_can_manage_prices"() TO "anon";
GRANT ALL ON FUNCTION "public"."user_can_manage_prices"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_can_manage_prices"() TO "service_role";



GRANT ALL ON FUNCTION "public"."user_owns_crop"("target_app_land_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."user_owns_crop"("target_app_land_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_owns_crop"("target_app_land_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."user_owns_crop_by_id"("target_app_crop_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."user_owns_crop_by_id"("target_app_crop_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_owns_crop_by_id"("target_app_crop_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."user_owns_farm"("target_farmer_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."user_owns_farm"("target_farmer_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_owns_farm"("target_farmer_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."user_owns_land"("target_farmer_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."user_owns_land"("target_farmer_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_owns_land"("target_farmer_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."user_owns_record"("target_user_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."user_owns_record"("target_user_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_owns_record"("target_user_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_activity"("p_farm_id" bigint, "p_activity_type_id" bigint, "p_note" "text", "p_date" timestamp without time zone, "p_user_id" "uuid", "p_label_color" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_activity"("p_farm_id" bigint, "p_activity_type_id" bigint, "p_note" "text", "p_date" timestamp without time zone, "p_user_id" "uuid", "p_label_color" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_activity"("p_farm_id" bigint, "p_activity_type_id" bigint, "p_note" "text", "p_date" timestamp without time zone, "p_user_id" "uuid", "p_label_color" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text", "_img_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text", "_img_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_bulk_activity"("_farm_id_arr" bigint[], "_farm_group_arr" bigint[], "_activity_type_id" bigint, "_note" "text", "_date" timestamp without time zone, "_user_id" "uuid", "_label_color" "text", "_img_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_cost"("_user_id" "uuid", "_cost_group_id" bigint, "_detail" "text", "_price" double precision, "_category" "text", "_date" timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_cost"("_user_id" "uuid", "_cost_group_id" bigint, "_detail" "text", "_price" double precision, "_category" "text", "_date" timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_cost"("_user_id" "uuid", "_cost_group_id" bigint, "_detail" "text", "_price" double precision, "_category" "text", "_date" timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_cost_group"("_name" "text", "_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_cost_group"("_name" "text", "_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_cost_group"("_name" "text", "_user_id" "uuid") TO "service_role";






GRANT ALL ON FUNCTION "public"."util_add_farm_group"("_name" "text", "_farm_ids" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_farm_group"("_name" "text", "_farm_ids" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_farm_group"("_name" "text", "_farm_ids" bigint[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_group"("_group_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_group"("_group_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_group"("_group_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_harvest"("_user_id" "uuid", "_amount" double precision, "_farm_id" bigint, "_date" timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_harvest"("_user_id" "uuid", "_amount" double precision, "_farm_id" bigint, "_date" timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_harvest"("_user_id" "uuid", "_amount" double precision, "_farm_id" bigint, "_date" timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_product"("_name" "text", "_detail" "json", "_categories" "text", "_shop_id" "uuid", "_shipping" "json") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_product"("_name" "text", "_detail" "json", "_categories" "text", "_shop_id" "uuid", "_shipping" "json") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_product"("_name" "text", "_detail" "json", "_categories" "text", "_shop_id" "uuid", "_shipping" "json") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_product_in_shop"("_shop_id" "uuid", "_product_detail" "json", "_product_option_detail" "json") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_product_in_shop"("_shop_id" "uuid", "_product_detail" "json", "_product_option_detail" "json") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_product_in_shop"("_shop_id" "uuid", "_product_detail" "json", "_product_option_detail" "json") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_product_option"("_product_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_product_option"("_product_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_product_option"("_product_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_shop"("_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_shop"("_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_shop"("_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_add_standard"("_user_id" "uuid", "_detail" "json", "_type_id" bigint, "_file_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_add_standard"("_user_id" "uuid", "_detail" "json", "_type_id" bigint, "_file_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_add_standard"("_user_id" "uuid", "_detail" "json", "_type_id" bigint, "_file_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_cal_cost_by_group"("_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_cal_cost_by_group"("_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_cal_cost_by_group"("_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_create_farm_group_and_farms"("_user_id" "uuid", "_group_name" "text", "_farms" "json") TO "anon";
GRANT ALL ON FUNCTION "public"."util_create_farm_group_and_farms"("_user_id" "uuid", "_group_name" "text", "_farms" "json") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_create_farm_group_and_farms"("_user_id" "uuid", "_group_name" "text", "_farms" "json") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_create_farm_group_and_farms_mobile"("_user_id" "uuid", "_group_name" "text", "_farms" "json") TO "anon";
GRANT ALL ON FUNCTION "public"."util_create_farm_group_and_farms_mobile"("_user_id" "uuid", "_group_name" "text", "_farms" "json") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_create_farm_group_and_farms_mobile"("_user_id" "uuid", "_group_name" "text", "_farms" "json") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_activity"("_activity_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_activity"("_activity_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_activity"("_activity_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_client"("_client_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_client"("_client_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_client"("_client_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_client_order"("_client_order_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_client_order"("_client_order_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_client_order"("_client_order_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_cost"("_cost_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_cost"("_cost_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_cost"("_cost_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_cost_group"("_cost_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_cost_group"("_cost_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_cost_group"("_cost_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_farm"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_farm"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_farm"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_farm_group"("_farm_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_farm_group"("_farm_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_farm_group"("_farm_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_group"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_group"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_group"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_harvest"("_harvest_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_harvest"("_harvest_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_harvest"("_harvest_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_order_history"("_order_history_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_order_history"("_order_history_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_order_history"("_order_history_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_product"("_product_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_product"("_product_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_product"("_product_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_product_option"("_product_option_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_product_option"("_product_option_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_product_option"("_product_option_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_quota"("_quota_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_quota"("_quota_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_quota"("_quota_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_quota_item"("_quota_item_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_quota_item"("_quota_item_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_quota_item"("_quota_item_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_delete_standard"("_standard_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_delete_standard"("_standard_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_delete_standard"("_standard_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_add_device"("_device_id" "text", "_owner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_add_device"("_device_id" "text", "_owner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_add_device"("_device_id" "text", "_owner_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_all_info"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_all_info"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_all_info"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_check_amount_qc"("_supplier_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_check_amount_qc"("_supplier_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_check_amount_qc"("_supplier_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_check_device_installed"("_search" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_check_device_installed"("_search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_check_device_installed"("_search" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_count_summary"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_count_summary"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_count_summary"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_get_device_list"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_get_device_list"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_get_device_list"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_get_device_log"("_device_id" "text", "_date" "text", "_type_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_get_device_log"("_device_id" "text", "_date" "text", "_type_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_get_device_log"("_device_id" "text", "_date" "text", "_type_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_get_qc"("_device_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_get_qc"("_device_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_get_qc"("_device_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_location"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_location"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_location"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_dn_iot_remove_device"("_device_id" "text", "_owner_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_dn_iot_remove_device"("_device_id" "text", "_owner_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_dn_iot_remove_device"("_device_id" "text", "_owner_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_duplicate_farm_group_with_type"("_group_name" "text", "_group_id" bigint, "_is_type_id" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."util_duplicate_farm_group_with_type"("_group_name" "text", "_group_id" bigint, "_is_type_id" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_duplicate_farm_group_with_type"("_group_name" "text", "_group_id" bigint, "_is_type_id" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_activity_by_group"("_group" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_activity_by_group"("_group" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_activity_by_group"("_group" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_activity_detail_superadmin"("_user_id" "uuid", "_start_date" timestamp without time zone, "_end_date" timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_activity_detail_superadmin"("_user_id" "uuid", "_start_date" timestamp without time zone, "_end_date" timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_activity_detail_superadmin"("_user_id" "uuid", "_start_date" timestamp without time zone, "_end_date" timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_activity_farm"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_activity_farm"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_activity_farm"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_activity_id"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_activity_id"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_activity_id"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_activity_report_modal_superadmin"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_activity_report_modal_superadmin"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_activity_report_modal_superadmin"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_activity_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid", "_offset" integer, "_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_activity_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid", "_offset" integer, "_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_activity_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid", "_offset" integer, "_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_activity_type_by_farm_type"("_farm_type_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_activity_type_by_farm_type"("_farm_type_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_activity_type_by_farm_type"("_farm_type_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_activity_type_ordered_priority"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_activity_type_ordered_priority"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_activity_type_ordered_priority"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_address"("lon" double precision, "lat" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_address"("lon" double precision, "lat" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_address"("lon" double precision, "lat" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_activity"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_activity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_activity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_activity_type"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_activity_type"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_activity_type"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_client"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_client"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_client"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_comment"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_comment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_comment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_cost"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_cost"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_cost"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_cost_group_with_sub_total"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_cost_group_with_sub_total"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_cost_group_with_sub_total"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_farm"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_farm"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_farm"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_farm_disabled"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_farm_disabled"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_farm_disabled"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_farm_group"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_farm_group"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_farm_group"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_farm_type"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_farm_type"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_farm_type"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_group"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_group"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_group"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_harvest"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_harvest"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_harvest"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_harvest_from_farm"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_harvest_from_farm"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_harvest_from_farm"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_news"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_news"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_news"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_product"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_product"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_product"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_product_option"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_product_option"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_product_option"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_profile"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_profile"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_profile_superadmin"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_profile_superadmin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_profile_superadmin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_quota"("_meeting_date" "date", "_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_quota"("_meeting_date" "date", "_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_quota"("_meeting_date" "date", "_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_quota_farm_null"("_meeting_date" "date", "_user_id" "uuid", "_null_flag" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_quota_farm_null"("_meeting_date" "date", "_user_id" "uuid", "_null_flag" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_quota_farm_null"("_meeting_date" "date", "_user_id" "uuid", "_null_flag" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_shop"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_shop"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_shop"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_standard"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_standard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_standard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_standard_type"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_standard_type"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_standard_type"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_sub_district"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_sub_district"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_sub_district"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_all_transaction"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_all_transaction"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_all_transaction"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_comment_review_product"("_product_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_comment_review_product"("_product_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_comment_review_product"("_product_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_cost_by_group"("_cost_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_cost_by_group"("_cost_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_cost_by_group"("_cost_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_dashboard"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_dashboard"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_dashboard"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_district"("province_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_district"("province_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_district"("province_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_activity"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_activity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_activity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_age"("ids" integer[]) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_age"("ids" integer[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_age"("ids" integer[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group"("_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group"("_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group"("_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group_disabled"("_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group_disabled"("_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group_disabled"("_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group_enabled"("_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group_enabled"("_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_by_f_group_enabled"("_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_by_id"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_by_id"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_by_id"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_from_group"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_from_group"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_from_group"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_from_id_with_ha"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_from_id_with_ha"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_from_id_with_ha"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_from_name"("_farm_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_from_name"("_farm_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_from_name"("_farm_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_from_user"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_from_user"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_from_user"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_group_null"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_group_null"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_group_null"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_list"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_list"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_list"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_group"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_group"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_group"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_group_enabled"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_group_enabled"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_group_enabled"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_name"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_name"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_name"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_name_disabled"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_name_disabled"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_ordered_name_disabled"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_owner"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_owner"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_owner"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_owner_from_group"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_owner_from_group"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_owner_from_group"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_status_desc"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_status_desc"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_status_desc"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_type_group"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_type_group"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_type_group"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_type_ordered"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_type_ordered"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_type_ordered"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_type_plant"("_farm_type_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_type_plant"("_farm_type_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_type_plant"("_farm_type_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_type_type"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_type_type"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_type_type"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_farm_with_plant"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_farm_with_plant"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_farm_with_plant"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_group_detail"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_group_detail"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_group_detail"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_harvest_by_farm"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_harvest_by_farm"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_harvest_by_farm"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_harvest_in_shop_by_user"("_username" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_harvest_in_shop_by_user"("_username" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_harvest_in_shop_by_user"("_username" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_maintenance"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_maintenance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_maintenance"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_news_ordered"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_news_ordered"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_news_ordered"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_news_type"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_news_type"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_news_type"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_notification"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_notification"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_notification"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_planting_cycles"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_planting_cycles"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_planting_cycles"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_plot_product_detail"("_month" smallint, "_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_plot_product_detail"("_month" smallint, "_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_plot_product_detail"("_month" smallint, "_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_plot_stat"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_plot_stat"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_plot_stat"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_plot_type_stat"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_plot_type_stat"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_plot_type_stat"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_product_detail"("_product_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_product_detail"("_product_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_product_detail"("_product_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_product_in_shop"("_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_product_in_shop"("_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_product_in_shop"("_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_profile_from_group"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_profile_from_group"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_profile_from_group"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_profile_from_id"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_profile_from_id"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_profile_from_id"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_profile_from_line"("_line_id" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_profile_from_line"("_line_id" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_profile_from_line"("_line_id" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_profile_sub_district"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_profile_sub_district"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_profile_sub_district"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_province"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_province"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_province"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_quota_item"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_quota_item"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_quota_item"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_report_data_superadmin"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_report_data_superadmin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_report_data_superadmin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_report_data_superadmin"("_date" timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_report_data_superadmin"("_date" timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_report_data_superadmin"("_date" timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_sensor"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_sensor"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_sensor"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_shop_by_id"("_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_shop_by_id"("_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_shop_by_id"("_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_shop_by_user"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_shop_by_user"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_shop_by_user"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_shop_detail"("_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_shop_detail"("_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_shop_detail"("_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_shop_detail_page"("_username" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_shop_detail_page"("_username" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_shop_detail_page"("_username" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_shop_product_chart"("_shop_id" "uuid", "_month" smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_shop_product_chart"("_shop_id" "uuid", "_month" smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_shop_product_chart"("_shop_id" "uuid", "_month" smallint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_shop_product_detail"("_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_shop_product_detail"("_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_shop_product_detail"("_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_signurl_activity"("_url" "text", "_expiration_interval" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_signurl_activity"("_url" "text", "_expiration_interval" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_signurl_activity"("_url" "text", "_expiration_interval" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_signurl_snapshot"("_url" "text", "_expiration_interval" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_signurl_snapshot"("_url" "text", "_expiration_interval" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_signurl_snapshot"("_url" "text", "_expiration_interval" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_standard_by_user_id"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_standard_by_user_id"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_standard_by_user_id"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_standard_type"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_standard_type"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_standard_type"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_status_area_farm"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_status_area_farm"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_status_area_farm"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_sub_district"("district" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_sub_district"("district" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_sub_district"("district" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_sub_district_by_id"("_sub_district_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_sub_district_by_id"("_sub_district_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_sub_district_by_id"("_sub_district_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_traceback"("_farm_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_traceback"("_farm_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_traceback"("_farm_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_transaction_by_shop"("_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_transaction_by_shop"("_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_transaction_by_shop"("_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_true_farm_owner_from_group"("_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_true_farm_owner_from_group"("_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_true_farm_owner_from_group"("_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_true_farm_with_plant"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_true_farm_with_plant"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_true_farm_with_plant"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_user_ids_in_group"("gid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_user_ids_in_group"("gid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_user_ids_in_group"("gid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_user_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_user_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_user_report_superadmin"("_start_date" timestamp without time zone, "_end_date" timestamp without time zone, "_user_id" "uuid", "_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_username"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_username"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_username"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_get_username_update_time"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_get_username_update_time"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_get_username_update_time"("_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_handle_update_username"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_handle_update_username"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_handle_update_username"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_join_group"("gid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_join_group"("gid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_join_group"("gid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_join_group_to_user"("gid" "uuid", "uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_join_group_to_user"("gid" "uuid", "uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_join_group_to_user"("gid" "uuid", "uid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_leave_group"("gid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_leave_group"("gid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_leave_group"("gid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_leave_group_from_user"("gid" "uuid", "uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_leave_group_from_user"("gid" "uuid", "uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_leave_group_from_user"("gid" "uuid", "uid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_predict_all_yield"() TO "anon";
GRANT ALL ON FUNCTION "public"."util_predict_all_yield"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_predict_all_yield"() TO "service_role";



GRANT ALL ON FUNCTION "public"."util_product_on_sell_in_shop"("_shop_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_product_on_sell_in_shop"("_shop_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_product_on_sell_in_shop"("_shop_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_purge_group"("gid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_purge_group"("gid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_purge_group"("gid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_remove_img_snapshot"("_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_remove_img_snapshot"("_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_remove_img_snapshot"("_url" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_activity_img_path"("_activity_id" bigint, "_img_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_activity_img_path"("_activity_id" bigint, "_img_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_activity_img_path"("_activity_id" bigint, "_img_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_cost_group"("_cost_group_id" bigint, "_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_cost_group"("_cost_group_id" bigint, "_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_cost_group"("_cost_group_id" bigint, "_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_farm_area_name"("_farm_id" bigint, "_name" "text", "_area_size" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_farm_area_name"("_farm_id" bigint, "_name" "text", "_area_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_farm_area_name"("_farm_id" bigint, "_name" "text", "_area_size" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_farm_area_name_status"("_farm_id" bigint, "_name" "text", "_area_size" bigint, "_status" boolean, "_village_name" character varying, "_moo" character varying, "_road" character varying, "_soi" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_farm_area_name_status"("_farm_id" bigint, "_name" "text", "_area_size" bigint, "_status" boolean, "_village_name" character varying, "_moo" character varying, "_road" character varying, "_soi" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_farm_area_name_status"("_farm_id" bigint, "_name" "text", "_area_size" bigint, "_status" boolean, "_village_name" character varying, "_moo" character varying, "_road" character varying, "_soi" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_farm_name"("p_farm_id" bigint, "p_farm_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_farm_name"("p_farm_id" bigint, "p_farm_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_farm_name"("p_farm_id" bigint, "p_farm_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_farm_status"("p_farm_status" boolean, "p_farm_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_farm_status"("p_farm_status" boolean, "p_farm_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_farm_status"("p_farm_status" boolean, "p_farm_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_group"("p_group_id" "uuid", "_name" "text", "_address" "text", "_biography" "text", "_about" "text", "_email" "text", "_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_group"("p_group_id" "uuid", "_name" "text", "_address" "text", "_biography" "text", "_about" "text", "_email" "text", "_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_group"("p_group_id" "uuid", "_name" "text", "_address" "text", "_biography" "text", "_about" "text", "_email" "text", "_phone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_group_banner"("_group_id" "uuid", "_img_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_group_banner"("_group_id" "uuid", "_img_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_group_banner"("_group_id" "uuid", "_img_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_group_farm"("_farm_id" bigint[], "_group_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_group_farm"("_farm_id" bigint[], "_group_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_group_farm"("_farm_id" bigint[], "_group_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_group_img_path"("_group_id" "uuid", "_img_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_group_img_path"("_group_id" "uuid", "_img_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_group_img_path"("_group_id" "uuid", "_img_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_img_path_profile"("_user_id" "uuid", "_img_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_img_path_profile"("_user_id" "uuid", "_img_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_img_path_profile"("_user_id" "uuid", "_img_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_product"("_product_id" "uuid", "_name" "text", "_detail" "json", "_shipping" "json", "_categories" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_product"("_product_id" "uuid", "_name" "text", "_detail" "json", "_shipping" "json", "_categories" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_product"("_product_id" "uuid", "_name" "text", "_detail" "json", "_shipping" "json", "_categories" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_product_img"("_image_path" "text"[], "_product_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_product_img"("_image_path" "text"[], "_product_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_product_img"("_image_path" "text"[], "_product_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_product_option"("_product_option_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_product_option"("_product_option_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_product_option"("_product_option_id" "uuid", "_name" "text", "_detail" "json", "_price" integer, "_unit" "text", "_stock" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_product_option_img"("_image_path" "text", "_product_option_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_product_option_img"("_image_path" "text", "_product_option_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_product_option_img"("_image_path" "text", "_product_option_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_product_option_status"("_product_option_id" "uuid", "_status" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_product_option_status"("_product_option_id" "uuid", "_status" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_product_option_status"("_product_option_id" "uuid", "_status" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_product_status"("_product_id" "uuid", "_status" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_product_status"("_product_id" "uuid", "_status" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_product_status"("_product_id" "uuid", "_status" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_profile"("_user_id" "uuid", "_first_name" character varying, "_last_name" character varying, "_address" character varying, "_sub_district_id" integer, "_id_card" character varying, "_farm_type_category" "public"."profile_farm_type_category", "_farmer_id" character varying, "_farmer_id_register_date" "date", "_date_of_birth" "date", "_house_id" character varying, "_default_lat" double precision, "_default_lon" double precision, "_prefix" "public"."profile_name_prefix") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_profile"("_user_id" "uuid", "_first_name" character varying, "_last_name" character varying, "_address" character varying, "_sub_district_id" integer, "_id_card" character varying, "_farm_type_category" "public"."profile_farm_type_category", "_farmer_id" character varying, "_farmer_id_register_date" "date", "_date_of_birth" "date", "_house_id" character varying, "_default_lat" double precision, "_default_lon" double precision, "_prefix" "public"."profile_name_prefix") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_profile"("_user_id" "uuid", "_first_name" character varying, "_last_name" character varying, "_address" character varying, "_sub_district_id" integer, "_id_card" character varying, "_farm_type_category" "public"."profile_farm_type_category", "_farmer_id" character varying, "_farmer_id_register_date" "date", "_date_of_birth" "date", "_house_id" character varying, "_default_lat" double precision, "_default_lon" double precision, "_prefix" "public"."profile_name_prefix") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_shop"("_shop_id" "uuid", "_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_account_name" "text", "_img_path" "text", "_banner_img_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_shop"("_shop_id" "uuid", "_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_account_name" "text", "_img_path" "text", "_banner_img_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_shop"("_shop_id" "uuid", "_name" "text", "_detail" "json", "_address" "text", "_phone" "text", "_line_id" "text", "_account_name" "text", "_img_path" "text", "_banner_img_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_shop_img_path"("_shop_id" "uuid", "_img_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_shop_img_path"("_shop_id" "uuid", "_img_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_shop_img_path"("_shop_id" "uuid", "_img_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_shop_payment_img_path"("_shop_id" "uuid", "_payment_img_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_shop_payment_img_path"("_shop_id" "uuid", "_payment_img_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_shop_payment_img_path"("_shop_id" "uuid", "_payment_img_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_snapshot_farm"("_farm_id" bigint, "_path_snapshot_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_snapshot_farm"("_farm_id" bigint, "_path_snapshot_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_snapshot_farm"("_farm_id" bigint, "_path_snapshot_url" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_standard"("_standard_id" "uuid", "_detail" "json", "_file_path" "text", "_type_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_standard"("_standard_id" "uuid", "_detail" "json", "_file_path" "text", "_type_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_standard"("_standard_id" "uuid", "_detail" "json", "_file_path" "text", "_type_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_update_username"("_user_id" "uuid", "_username" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."util_update_username"("_user_id" "uuid", "_username" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_update_username"("_user_id" "uuid", "_username" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_updateretry"("input_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."util_updateretry"("input_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_updateretry"("input_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_upsert_client"("_client_id" bigint, "_name" character varying, "_delivery_round" character varying[], "_status" boolean, "_group" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_upsert_client"("_client_id" bigint, "_name" character varying, "_delivery_round" character varying[], "_status" boolean, "_group" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_upsert_client"("_client_id" bigint, "_name" character varying, "_delivery_round" character varying[], "_status" boolean, "_group" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_upsert_client_order"("_order_id" bigint, "_client_id" bigint, "_delivery_date" "date", "_order_date" "date", "_farm_type_id" bigint, "_amount" double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."util_upsert_client_order"("_order_id" bigint, "_client_id" bigint, "_delivery_date" "date", "_order_date" "date", "_farm_type_id" bigint, "_amount" double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_upsert_client_order"("_order_id" bigint, "_client_id" bigint, "_delivery_date" "date", "_order_date" "date", "_farm_type_id" bigint, "_amount" double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_upsert_farm"("_farm_id" bigint, "_status" boolean, "_user_id" "uuid", "_name" "text", "_type_id" bigint, "_create_date" timestamp without time zone, "_title_deed_no" "text", "_area_size" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_upsert_farm"("_farm_id" bigint, "_status" boolean, "_user_id" "uuid", "_name" "text", "_type_id" bigint, "_create_date" timestamp without time zone, "_title_deed_no" "text", "_area_size" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_upsert_farm"("_farm_id" bigint, "_status" boolean, "_user_id" "uuid", "_name" "text", "_type_id" bigint, "_create_date" timestamp without time zone, "_title_deed_no" "text", "_area_size" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_upsert_farm_traceable"("_farm_id" bigint, "_traceable" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."util_upsert_farm_traceable"("_farm_id" bigint, "_traceable" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_upsert_farm_traceable"("_farm_id" bigint, "_traceable" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_upsert_order_history"("_order_history_id" bigint, "_file_path" character varying, "_group" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_upsert_order_history"("_order_history_id" bigint, "_file_path" character varying, "_group" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_upsert_order_history"("_order_history_id" bigint, "_file_path" character varying, "_group" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."util_upsert_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint, "_cycle_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."util_upsert_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint, "_cycle_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_upsert_planting_cycle"("_farm_id" bigint, "_cycle_name" "text", "_area_usage_rai" bigint, "_crop_age" bigint, "_crop_age_unit" "text", "_crop_name" "text", "_total_trees" bigint, "_growth_month_start" smallint, "_growth_month_end" smallint, "_harvest_month_start" smallint, "_harvest_month_end" smallint, "_expected_annual_yield" bigint, "_type_id" bigint, "_cycle_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."util_upsert_quota_order"("_id" bigint, "_user_id" "uuid", "_meeting_date" "date", "_delivery_round" character varying[], "_farm_data" "jsonb", "_group" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."util_upsert_quota_order"("_id" bigint, "_user_id" "uuid", "_meeting_date" "date", "_delivery_round" character varying[], "_farm_data" "jsonb", "_group" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."util_upsert_quota_order"("_id" bigint, "_user_id" "uuid", "_meeting_date" "date", "_delivery_round" character varying[], "_farm_data" "jsonb", "_group" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";














































































GRANT ALL ON TABLE "public"."client" TO "anon";
GRANT ALL ON TABLE "public"."client" TO "authenticated";
GRANT ALL ON TABLE "public"."client" TO "service_role";



GRANT ALL ON SEQUENCE "public"."Client_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."Client_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."Client_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."activity" TO "anon";
GRANT ALL ON TABLE "public"."activity" TO "authenticated";
GRANT ALL ON TABLE "public"."activity" TO "service_role";



GRANT ALL ON SEQUENCE "public"."activities_activity_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."activities_activity_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."activities_activity_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."activity_type" TO "anon";
GRANT ALL ON TABLE "public"."activity_type" TO "authenticated";
GRANT ALL ON TABLE "public"."activity_type" TO "service_role";



GRANT ALL ON SEQUENCE "public"."activity_type_activity_type_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."activity_type_activity_type_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."activity_type_activity_type_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."client_order" TO "anon";
GRANT ALL ON TABLE "public"."client_order" TO "authenticated";
GRANT ALL ON TABLE "public"."client_order" TO "service_role";



GRANT ALL ON SEQUENCE "public"."client_order_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."client_order_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."client_order_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."client_order_item" TO "anon";
GRANT ALL ON TABLE "public"."client_order_item" TO "authenticated";
GRANT ALL ON TABLE "public"."client_order_item" TO "service_role";



GRANT ALL ON SEQUENCE "public"."client_order_item_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."client_order_item_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."client_order_item_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."comment_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."comment_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."comment_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."comment" TO "anon";
GRANT ALL ON TABLE "public"."comment" TO "authenticated";
GRANT ALL ON TABLE "public"."comment" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cost_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cost_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cost_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cost" TO "anon";
GRANT ALL ON TABLE "public"."cost" TO "authenticated";
GRANT ALL ON TABLE "public"."cost" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cost_calculation_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cost_calculation_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cost_calculation_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cost_group" TO "anon";
GRANT ALL ON TABLE "public"."cost_group" TO "authenticated";
GRANT ALL ON TABLE "public"."cost_group" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cost_group_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cost_group_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cost_group_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."debug_log" TO "anon";
GRANT ALL ON TABLE "public"."debug_log" TO "authenticated";
GRANT ALL ON TABLE "public"."debug_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."debug_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."debug_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."debug_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_actions_crop" TO "anon";
GRANT ALL ON TABLE "public"."dn_actions_crop" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_actions_crop" TO "service_role";



GRANT ALL ON TABLE "public"."dn_actions_crop_cost" TO "anon";
GRANT ALL ON TABLE "public"."dn_actions_crop_cost" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_actions_crop_cost" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_actions_crop_cost_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_actions_crop_cost_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_actions_crop_cost_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_actions_crop_fruit_bloom" TO "anon";
GRANT ALL ON TABLE "public"."dn_actions_crop_fruit_bloom" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_actions_crop_fruit_bloom" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_actions_crop_fruit_bloom_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_actions_crop_fruit_bloom_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_actions_crop_fruit_bloom_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_actions_crop_stages" TO "anon";
GRANT ALL ON TABLE "public"."dn_actions_crop_stages" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_actions_crop_stages" TO "service_role";



GRANT ALL ON TABLE "public"."dn_actions_crop_yield" TO "anon";
GRANT ALL ON TABLE "public"."dn_actions_crop_yield" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_actions_crop_yield" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_actions_crop_yield_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_actions_crop_yield_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_actions_crop_yield_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_iot_commands" TO "anon";
GRANT ALL ON TABLE "public"."dn_iot_commands" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_iot_commands" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_iot_commands_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_iot_commands_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_iot_commands_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_iot_devices" TO "anon";
GRANT ALL ON TABLE "public"."dn_iot_devices" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_iot_devices" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_iot_devices_device_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_iot_devices_device_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_iot_devices_device_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_iot_electrician_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_iot_electrician_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_iot_electrician_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_iot_sensor" TO "anon";
GRANT ALL ON TABLE "public"."dn_iot_sensor" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_iot_sensor" TO "service_role";



GRANT ALL ON TABLE "public"."dn_iot_sensor_log_daily" TO "anon";
GRANT ALL ON TABLE "public"."dn_iot_sensor_log_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_iot_sensor_log_daily" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_iot_sensor_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_iot_sensor_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_iot_sensor_log_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_iot_sensor_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_iot_sensor_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_iot_sensor_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_iot_sensor_types" TO "anon";
GRANT ALL ON TABLE "public"."dn_iot_sensor_types" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_iot_sensor_types" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_iot_supplier_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_iot_supplier_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_iot_supplier_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_iot_supply_list" TO "anon";
GRANT ALL ON TABLE "public"."dn_iot_supply_list" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_iot_supply_list" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_iot_supply_list_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_iot_supply_list_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_iot_supply_list_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_operations_chemical" TO "anon";
GRANT ALL ON TABLE "public"."dn_operations_chemical" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_operations_chemical" TO "service_role";



GRANT ALL ON TABLE "public"."dn_operations_chemical_harvest" TO "anon";
GRANT ALL ON TABLE "public"."dn_operations_chemical_harvest" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_operations_chemical_harvest" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_operations_chemical_harvest_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_operations_chemical_harvest_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_operations_chemical_harvest_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_operations_chemical_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_operations_chemical_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_operations_chemical_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_operations_fertilizing" TO "anon";
GRANT ALL ON TABLE "public"."dn_operations_fertilizing" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_operations_fertilizing" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_operations_fertilizing_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_operations_fertilizing_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_operations_fertilizing_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_operations_harvest" TO "anon";
GRANT ALL ON TABLE "public"."dn_operations_harvest" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_operations_harvest" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_operations_harvest_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_operations_harvest_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_operations_harvest_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_operations_pest_control" TO "anon";
GRANT ALL ON TABLE "public"."dn_operations_pest_control" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_operations_pest_control" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_operations_pest_control_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_operations_pest_control_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_operations_pest_control_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_operations_survey" TO "anon";
GRANT ALL ON TABLE "public"."dn_operations_survey" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_operations_survey" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_operations_survey_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_operations_survey_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_operations_survey_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_operations_watering" TO "anon";
GRANT ALL ON TABLE "public"."dn_operations_watering" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_operations_watering" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_operations_watering_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_operations_watering_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_operations_watering_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_cbf" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_cbf" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_cbf" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_cbf_energy_ef" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_cbf_energy_ef" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_cbf_energy_ef" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_cbf_transport_ef" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_cbf_transport_ef" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_cbf_transport_ef" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_certify" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_certify" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_certify" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_community" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_community" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_community" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_community_memberships" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_community_memberships" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_community_memberships" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_tb_m_community_memberships_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_community_memberships_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_community_memberships_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_crop_stage" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_crop_stage" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_crop_stage" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_tb_m_crop_stage_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_crop_stage_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_crop_stage_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_device_tokens" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_device_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_device_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_external_log" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_external_log" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_external_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_tb_m_external_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_external_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_external_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_farm" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_farm" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_farm" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_iot_hubs" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_iot_hubs" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_iot_hubs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_tb_m_iot_hubs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_iot_hubs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_iot_hubs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_land" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_land" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_land" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_land_type" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_land_type" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_land_type" TO "service_role";



GRANT ALL ON SEQUENCE "public"."dn_tb_m_land_type_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_land_type_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."dn_tb_m_land_type_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_news" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_news" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_news" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_news_comment" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_news_comment" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_news_comment" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_news_like" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_news_like" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_news_like" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_notifications" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_price" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_price" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_price" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_m_user" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_m_user" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_m_user" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_r_cbf_chemical" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_chemical" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_chemical" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_r_cbf_electric" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_electric" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_electric" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_r_cbf_fertilizer" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_fertilizer" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_fertilizer" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_r_cbf_fuel" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_fuel" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_fuel" TO "service_role";



GRANT ALL ON TABLE "public"."dn_tb_r_cbf_material" TO "anon";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_material" TO "authenticated";
GRANT ALL ON TABLE "public"."dn_tb_r_cbf_material" TO "service_role";



GRANT ALL ON TABLE "public"."factor_detail" TO "anon";
GRANT ALL ON TABLE "public"."factor_detail" TO "authenticated";
GRANT ALL ON TABLE "public"."factor_detail" TO "service_role";



GRANT ALL ON TABLE "public"."factor_stock" TO "anon";
GRANT ALL ON TABLE "public"."factor_stock" TO "authenticated";
GRANT ALL ON TABLE "public"."factor_stock" TO "service_role";



GRANT ALL ON TABLE "public"."farm" TO "anon";
GRANT ALL ON TABLE "public"."farm" TO "authenticated";
GRANT ALL ON TABLE "public"."farm" TO "service_role";



GRANT ALL ON TABLE "public"."farm_group" TO "anon";
GRANT ALL ON TABLE "public"."farm_group" TO "authenticated";
GRANT ALL ON TABLE "public"."farm_group" TO "service_role";



GRANT ALL ON SEQUENCE "public"."farm_group_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."farm_group_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."farm_group_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."farm_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."farm_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."farm_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."farm_type" TO "anon";
GRANT ALL ON TABLE "public"."farm_type" TO "authenticated";
GRANT ALL ON TABLE "public"."farm_type" TO "service_role";



GRANT ALL ON TABLE "public"."group" TO "anon";
GRANT ALL ON TABLE "public"."group" TO "authenticated";
GRANT ALL ON TABLE "public"."group" TO "service_role";



GRANT ALL ON TABLE "public"."ha_bridges" TO "anon";
GRANT ALL ON TABLE "public"."ha_bridges" TO "authenticated";
GRANT ALL ON TABLE "public"."ha_bridges" TO "service_role";



GRANT ALL ON TABLE "public"."ha_command" TO "anon";
GRANT ALL ON TABLE "public"."ha_command" TO "authenticated";
GRANT ALL ON TABLE "public"."ha_command" TO "service_role";



GRANT ALL ON TABLE "public"."ha_entities" TO "anon";
GRANT ALL ON TABLE "public"."ha_entities" TO "authenticated";
GRANT ALL ON TABLE "public"."ha_entities" TO "service_role";



GRANT ALL ON TABLE "public"."ha_states" TO "anon";
GRANT ALL ON TABLE "public"."ha_states" TO "authenticated";
GRANT ALL ON TABLE "public"."ha_states" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ha_states_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ha_states_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ha_states_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."harvest" TO "anon";
GRANT ALL ON TABLE "public"."harvest" TO "authenticated";
GRANT ALL ON TABLE "public"."harvest" TO "service_role";



GRANT ALL ON SEQUENCE "public"."harvest_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."harvest_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."harvest_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."maintenance" TO "anon";
GRANT ALL ON TABLE "public"."maintenance" TO "authenticated";
GRANT ALL ON TABLE "public"."maintenance" TO "service_role";



GRANT ALL ON SEQUENCE "public"."maintenance_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."maintenance_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."maintenance_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."master_bank_list" TO "anon";
GRANT ALL ON TABLE "public"."master_bank_list" TO "authenticated";
GRANT ALL ON TABLE "public"."master_bank_list" TO "service_role";



GRANT ALL ON TABLE "public"."master_delivery_type" TO "anon";
GRANT ALL ON TABLE "public"."master_delivery_type" TO "authenticated";
GRANT ALL ON TABLE "public"."master_delivery_type" TO "service_role";



GRANT ALL ON SEQUENCE "public"."master_delivery_type_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."master_delivery_type_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."master_delivery_type_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."master_product_category" TO "anon";
GRANT ALL ON TABLE "public"."master_product_category" TO "authenticated";
GRANT ALL ON TABLE "public"."master_product_category" TO "service_role";



GRANT ALL ON SEQUENCE "public"."master_product_category_category_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."master_product_category_category_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."master_product_category_category_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."master_product_type" TO "anon";
GRANT ALL ON TABLE "public"."master_product_type" TO "authenticated";
GRANT ALL ON TABLE "public"."master_product_type" TO "service_role";



GRANT ALL ON TABLE "public"."mp_basket" TO "anon";
GRANT ALL ON TABLE "public"."mp_basket" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_basket" TO "service_role";



GRANT ALL ON TABLE "public"."mp_basket_items" TO "anon";
GRANT ALL ON TABLE "public"."mp_basket_items" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_basket_items" TO "service_role";



GRANT ALL ON TABLE "public"."mp_chat_members" TO "anon";
GRANT ALL ON TABLE "public"."mp_chat_members" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_chat_members" TO "service_role";



GRANT ALL ON TABLE "public"."mp_chat_message_attachments" TO "anon";
GRANT ALL ON TABLE "public"."mp_chat_message_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_chat_message_attachments" TO "service_role";



GRANT ALL ON TABLE "public"."mp_chat_messages" TO "anon";
GRANT ALL ON TABLE "public"."mp_chat_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_chat_messages" TO "service_role";



GRANT ALL ON TABLE "public"."mp_chat_room_reads" TO "anon";
GRANT ALL ON TABLE "public"."mp_chat_room_reads" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_chat_room_reads" TO "service_role";



GRANT ALL ON TABLE "public"."mp_chat_rooms" TO "anon";
GRANT ALL ON TABLE "public"."mp_chat_rooms" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_chat_rooms" TO "service_role";



GRANT ALL ON TABLE "public"."mp_delivery_method" TO "anon";
GRANT ALL ON TABLE "public"."mp_delivery_method" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_delivery_method" TO "service_role";



GRANT ALL ON TABLE "public"."mp_delivery_rate" TO "anon";
GRANT ALL ON TABLE "public"."mp_delivery_rate" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_delivery_rate" TO "service_role";



GRANT ALL ON TABLE "public"."mp_order_disputes" TO "anon";
GRANT ALL ON TABLE "public"."mp_order_disputes" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_order_disputes" TO "service_role";



GRANT ALL ON TABLE "public"."mp_order_items" TO "anon";
GRANT ALL ON TABLE "public"."mp_order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_order_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mp_order_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mp_order_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mp_order_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mp_order_notification_log" TO "anon";
GRANT ALL ON TABLE "public"."mp_order_notification_log" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_order_notification_log" TO "service_role";



GRANT ALL ON TABLE "public"."mp_order_sales" TO "anon";
GRANT ALL ON TABLE "public"."mp_order_sales" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_order_sales" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mp_order_sales_code_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mp_order_sales_code_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mp_order_sales_code_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mp_payment_method" TO "anon";
GRANT ALL ON TABLE "public"."mp_payment_method" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_payment_method" TO "service_role";



GRANT ALL ON TABLE "public"."mp_payout_log" TO "anon";
GRANT ALL ON TABLE "public"."mp_payout_log" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_payout_log" TO "service_role";



GRANT ALL ON TABLE "public"."mp_platform_payout_log" TO "anon";
GRANT ALL ON TABLE "public"."mp_platform_payout_log" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_platform_payout_log" TO "service_role";



GRANT ALL ON TABLE "public"."mp_product" TO "anon";
GRANT ALL ON TABLE "public"."mp_product" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_product" TO "service_role";



GRANT ALL ON TABLE "public"."mp_product_delivery_config" TO "anon";
GRANT ALL ON TABLE "public"."mp_product_delivery_config" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_product_delivery_config" TO "service_role";



GRANT ALL ON TABLE "public"."mp_product_variant" TO "anon";
GRANT ALL ON TABLE "public"."mp_product_variant" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_product_variant" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mp_product_variant_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mp_product_variant_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mp_product_variant_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mp_promotion" TO "anon";
GRANT ALL ON TABLE "public"."mp_promotion" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_promotion" TO "service_role";



GRANT ALL ON TABLE "public"."mp_promotion_products" TO "anon";
GRANT ALL ON TABLE "public"."mp_promotion_products" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_promotion_products" TO "service_role";



GRANT ALL ON TABLE "public"."mp_review_media" TO "anon";
GRANT ALL ON TABLE "public"."mp_review_media" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_review_media" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mp_review_media_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mp_review_media_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mp_review_media_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mp_reviews" TO "anon";
GRANT ALL ON TABLE "public"."mp_reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_reviews" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mp_reviews_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mp_reviews_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mp_reviews_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mp_seller_violations" TO "anon";
GRANT ALL ON TABLE "public"."mp_seller_violations" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_seller_violations" TO "service_role";



GRANT ALL ON TABLE "public"."mp_shop_address" TO "anon";
GRANT ALL ON TABLE "public"."mp_shop_address" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_shop_address" TO "service_role";



GRANT ALL ON TABLE "public"."mp_shop_payment" TO "anon";
GRANT ALL ON TABLE "public"."mp_shop_payment" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_shop_payment" TO "service_role";



GRANT ALL ON TABLE "public"."mp_shop_province" TO "anon";
GRANT ALL ON TABLE "public"."mp_shop_province" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_shop_province" TO "service_role";



GRANT ALL ON TABLE "public"."mp_tb_m_dispute_reason" TO "anon";
GRANT ALL ON TABLE "public"."mp_tb_m_dispute_reason" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_tb_m_dispute_reason" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mp_tb_m_dispute_reason_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mp_tb_m_dispute_reason_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mp_tb_m_dispute_reason_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mp_tb_m_order_status" TO "anon";
GRANT ALL ON TABLE "public"."mp_tb_m_order_status" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_tb_m_order_status" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mp_tb_m_order_status_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mp_tb_m_order_status_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mp_tb_m_order_status_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mp_tb_user_sessions" TO "anon";
GRANT ALL ON TABLE "public"."mp_tb_user_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_tb_user_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."mp_user_address" TO "anon";
GRANT ALL ON TABLE "public"."mp_user_address" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_user_address" TO "service_role";



GRANT ALL ON TABLE "public"."mp_user_daily_summary" TO "anon";
GRANT ALL ON TABLE "public"."mp_user_daily_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."mp_user_daily_summary" TO "service_role";



GRANT ALL ON TABLE "public"."news" TO "anon";
GRANT ALL ON TABLE "public"."news" TO "authenticated";
GRANT ALL ON TABLE "public"."news" TO "service_role";



GRANT ALL ON SEQUENCE "public"."news_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."news_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."news_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."notification" TO "anon";
GRANT ALL ON TABLE "public"."notification" TO "authenticated";
GRANT ALL ON TABLE "public"."notification" TO "service_role";



GRANT ALL ON SEQUENCE "public"."notification_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notification_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notification_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."order_history_file" TO "anon";
GRANT ALL ON TABLE "public"."order_history_file" TO "authenticated";
GRANT ALL ON TABLE "public"."order_history_file" TO "service_role";



GRANT ALL ON SEQUENCE "public"."order_history_file_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."order_history_file_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."order_history_file_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON TABLE "public"."plant_cycle" TO "anon";
GRANT ALL ON TABLE "public"."plant_cycle" TO "authenticated";
GRANT ALL ON TABLE "public"."plant_cycle" TO "service_role";



GRANT ALL ON TABLE "public"."tb_m_planting_cycles" TO "anon";
GRANT ALL ON TABLE "public"."tb_m_planting_cycles" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_m_planting_cycles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."planting_cycles_cycle_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."planting_cycles_cycle_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."planting_cycles_cycle_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."plot_type_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."plot_type_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."plot_type_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pre_activity" TO "anon";
GRANT ALL ON TABLE "public"."pre_activity" TO "authenticated";
GRANT ALL ON TABLE "public"."pre_activity" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pre_activity_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pre_activity_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pre_activity_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."product" TO "anon";
GRANT ALL ON TABLE "public"."product" TO "authenticated";
GRANT ALL ON TABLE "public"."product" TO "service_role";



GRANT ALL ON TABLE "public"."product_option" TO "anon";
GRANT ALL ON TABLE "public"."product_option" TO "authenticated";
GRANT ALL ON TABLE "public"."product_option" TO "service_role";



GRANT ALL ON TABLE "public"."profile" TO "anon";
GRANT ALL ON TABLE "public"."profile" TO "authenticated";
GRANT ALL ON TABLE "public"."profile" TO "service_role";



GRANT ALL ON TABLE "public"."province" TO "anon";
GRANT ALL ON TABLE "public"."province" TO "authenticated";
GRANT ALL ON TABLE "public"."province" TO "service_role";



GRANT ALL ON TABLE "public"."quota" TO "anon";
GRANT ALL ON TABLE "public"."quota" TO "authenticated";
GRANT ALL ON TABLE "public"."quota" TO "service_role";



GRANT ALL ON SEQUENCE "public"."quota_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."quota_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."quota_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."quota_item" TO "anon";
GRANT ALL ON TABLE "public"."quota_item" TO "authenticated";
GRANT ALL ON TABLE "public"."quota_item" TO "service_role";



GRANT ALL ON SEQUENCE "public"."quota_item_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."quota_item_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."quota_item_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."result" TO "anon";
GRANT ALL ON TABLE "public"."result" TO "authenticated";
GRANT ALL ON TABLE "public"."result" TO "service_role";



GRANT ALL ON TABLE "public"."shop" TO "anon";
GRANT ALL ON TABLE "public"."shop" TO "authenticated";
GRANT ALL ON TABLE "public"."shop" TO "service_role";



GRANT ALL ON SEQUENCE "public"."shop_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."shop_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."shop_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."standard" TO "anon";
GRANT ALL ON TABLE "public"."standard" TO "authenticated";
GRANT ALL ON TABLE "public"."standard" TO "service_role";



GRANT ALL ON TABLE "public"."standard_type" TO "anon";
GRANT ALL ON TABLE "public"."standard_type" TO "authenticated";
GRANT ALL ON TABLE "public"."standard_type" TO "service_role";



GRANT ALL ON SEQUENCE "public"."standard_type_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."standard_type_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."standard_type_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sub_district" TO "anon";
GRANT ALL ON TABLE "public"."sub_district" TO "authenticated";
GRANT ALL ON TABLE "public"."sub_district" TO "service_role";



GRANT ALL ON TABLE "public"."tb_h_wallet" TO "anon";
GRANT ALL ON TABLE "public"."tb_h_wallet" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_h_wallet" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tb_h_wallet_wallet_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tb_h_wallet_wallet_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tb_h_wallet_wallet_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tb_m_license" TO "anon";
GRANT ALL ON TABLE "public"."tb_m_license" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_m_license" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tb_m_license_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tb_m_license_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tb_m_license_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tb_m_mp_boost_plan" TO "anon";
GRANT ALL ON TABLE "public"."tb_m_mp_boost_plan" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_m_mp_boost_plan" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tb_m_mp_boost_plan_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tb_m_mp_boost_plan_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tb_m_mp_boost_plan_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tb_m_partners" TO "anon";
GRANT ALL ON TABLE "public"."tb_m_partners" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_m_partners" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tb_m_partners_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tb_m_partners_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tb_m_partners_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tb_m_product_boost" TO "anon";
GRANT ALL ON TABLE "public"."tb_m_product_boost" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_m_product_boost" TO "service_role";



GRANT ALL ON TABLE "public"."tb_m_reward" TO "anon";
GRANT ALL ON TABLE "public"."tb_m_reward" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_m_reward" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tb_m_reward_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tb_m_reward_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tb_m_reward_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tb_m_wallet" TO "anon";
GRANT ALL ON TABLE "public"."tb_m_wallet" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_m_wallet" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tb_m_wallet_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tb_m_wallet_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tb_m_wallet_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tb_r_wallet_type" TO "anon";
GRANT ALL ON TABLE "public"."tb_r_wallet_type" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_r_wallet_type" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tb_m_wallet_type_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tb_m_wallet_type_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tb_m_wallet_type_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tb_r_license_type" TO "anon";
GRANT ALL ON TABLE "public"."tb_r_license_type" TO "authenticated";
GRANT ALL ON TABLE "public"."tb_r_license_type" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tb_r_license_type_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tb_r_license_type_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tb_r_license_type_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."traceback" TO "anon";
GRANT ALL ON TABLE "public"."traceback" TO "authenticated";
GRANT ALL ON TABLE "public"."traceback" TO "service_role";



GRANT ALL ON SEQUENCE "public"."traceback_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."traceback_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."traceback_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."transaction_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."transaction_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."transaction_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ty_commands" TO "anon";
GRANT ALL ON TABLE "public"."ty_commands" TO "authenticated";
GRANT ALL ON TABLE "public"."ty_commands" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ty_commands_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ty_commands_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ty_commands_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ty_devices" TO "anon";
GRANT ALL ON TABLE "public"."ty_devices" TO "authenticated";
GRANT ALL ON TABLE "public"."ty_devices" TO "service_role";



GRANT ALL ON TABLE "public"."ty_sensor_detail" TO "anon";
GRANT ALL ON TABLE "public"."ty_sensor_detail" TO "authenticated";
GRANT ALL ON TABLE "public"."ty_sensor_detail" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ty_sensor_detail_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ty_sensor_detail_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ty_sensor_detail_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ty_sensor_types" TO "anon";
GRANT ALL ON TABLE "public"."ty_sensor_types" TO "authenticated";
GRANT ALL ON TABLE "public"."ty_sensor_types" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ty_sensor_types_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ty_sensor_types_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ty_sensor_types_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ty_sensors" TO "anon";
GRANT ALL ON TABLE "public"."ty_sensors" TO "authenticated";
GRANT ALL ON TABLE "public"."ty_sensors" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ty_sensors_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ty_sensors_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ty_sensors_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_levels" TO "anon";
GRANT ALL ON TABLE "public"."user_levels" TO "authenticated";
GRANT ALL ON TABLE "public"."user_levels" TO "service_role";



GRANT ALL ON SEQUENCE "public"."user_levels_level_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."user_levels_level_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."user_levels_level_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_log" TO "anon";
GRANT ALL ON TABLE "public"."user_log" TO "authenticated";
GRANT ALL ON TABLE "public"."user_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."user_log_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."user_log_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."user_log_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_permissions" TO "anon";
GRANT ALL ON TABLE "public"."user_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_permissions" TO "service_role";



GRANT ALL ON TABLE "public"."user_roles" TO "anon";
GRANT ALL ON TABLE "public"."user_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_roles" TO "service_role";



GRANT ALL ON TABLE "public"."user_subscription" TO "anon";
GRANT ALL ON TABLE "public"."user_subscription" TO "authenticated";
GRANT ALL ON TABLE "public"."user_subscription" TO "service_role";



GRANT ALL ON SEQUENCE "public"."user_subscription_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."user_subscription_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."user_subscription_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."v_user_license" TO "anon";
GRANT ALL ON TABLE "public"."v_user_license" TO "authenticated";
GRANT ALL ON TABLE "public"."v_user_license" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";































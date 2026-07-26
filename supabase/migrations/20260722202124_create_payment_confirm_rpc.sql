-- Migration for create_payment_confirm RPC
-- ============================================================================
-- Migration: create_payment_confirm_rpc
-- Phase: 3 — Payment Lifecycle Migration
-- Task: 2 — Confirm RPC (Fully Implemented)
--
-- Purpose: Implements the "confirm" step of the intent → execute → confirm
--          orchestration pattern (Core P8) for the Razorpay payment lifecycle.
--          Finalizes ledger_entries and payment/order status following a
--          successful external Razorpay confirmation performed by the
--          calling Edge Function. Enforces atomic state transitions and 
--          strict zero-trust canonical error sanitization.
--
-- Idempotency: First-writer-wins. Both the webhook path and the Edge
--          Function's own confirm call invoke this RPC; the second arrival
--          must be detected and returned as a replay, never re-executed.
--
-- Spec refs: 01-core-architecture-specification.md P2, P8, P11
--            02-state-machines.md §1
--            03-database-ledger-specification.md §1.2, §1.3, §3
--            04-operational-standards.md §1
-- ============================================================================

-- Drop prior signatures if this function is being redefined during development.
-- No prior version of create_payment_confirm exists as of this migration;
-- included per project convention for forward-compatibility with future
-- signature changes.
DROP FUNCTION IF EXISTS public.create_payment_confirm(UUID, UUID, TEXT, TEXT, UUID);
DROP FUNCTION IF EXISTS public.create_payment_confirm(UUID, UUID, TEXT, TEXT, UUID, BOOLEAN);
DROP FUNCTION IF EXISTS public.create_payment_confirm(UUID, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT);

CREATE OR REPLACE FUNCTION public.create_payment_confirm(
  p_payment_id           UUID,
  p_order_id             UUID,
  p_razorpay_payment_id  TEXT DEFAULT NULL,
  p_razorpay_signature   TEXT DEFAULT NULL,
  p_customer_id          UUID DEFAULT NULL,
  p_is_admin             BOOLEAN DEFAULT FALSE,
  p_transaction_id       TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public, pg_temp
AS $$
DECLARE
  -- --------------------------------------------------------------------
  -- Payment lookup
  -- --------------------------------------------------------------------
  v_payment_row                RECORD;

  -- --------------------------------------------------------------------
  -- Order lookup
  -- --------------------------------------------------------------------
  v_order_row                  RECORD;

  -- --------------------------------------------------------------------
  -- Ledger lookup
  -- --------------------------------------------------------------------
  v_ledger_pending_count         INTEGER;
  v_ledger_confirmed             BOOLEAN;
  
  -- --------------------------------------------------------------------
  -- Update tracking
  -- --------------------------------------------------------------------
  v_payment_rows_updated         INTEGER;
  v_order_rows_updated           INTEGER;
  v_ledger_rows_updated          INTEGER;

  -- --------------------------------------------------------------------
  -- Idempotency / replay handling
  -- --------------------------------------------------------------------
  v_is_idempotent_replay        BOOLEAN := FALSE;
  v_replay_data                  JSONB;
  
  -- Replay Hydration Variables
  v_order_status                 TEXT;
  v_amount_paise                 BIGINT;
  v_razorpay_payment_id          TEXT;
  v_operation_key                TEXT;
  v_credited_at                  TIMESTAMPTZ;

  -- --------------------------------------------------------------------
  -- Timestamps
  -- --------------------------------------------------------------------
  v_now                        TIMESTAMPTZ := now();

  -- --------------------------------------------------------------------
  -- Response construction
  -- --------------------------------------------------------------------
  v_response                    JSONB;

BEGIN

  -- ==========================================================================
  -- 1. AUTHORIZATION
  -- ==========================================================================
  -- This RPC is service_role-only (see GRANT below) and is invoked
  -- exclusively by trusted Edge Functions, never directly by a client.
  -- There is no caller-identity resolution step here — service_role
  -- execution is itself the authorization boundary (Core P1, §4).
  -- Zero-trust applies instead to the *data*: ownership of the payment,
  -- order, and customer relationship is verified entirely through
  -- database lookups in Section 2, never assumed from the parameters
  -- as passed.


  -- ==========================================================================
  -- 2. VALIDATION & OWNERSHIP VERIFICATION
  -- ==========================================================================
  IF p_payment_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'VALIDATION_MISSING_PAYMENT_ID'
    );
  END IF;

  IF p_order_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'VALIDATION_MISSING_ORDER_ID'
    );
  END IF;

  IF NOT p_is_admin THEN
    IF p_customer_id IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'data', null,
        'isIdempotentReplay', false,
        'errorCode', 'VALIDATION_MISSING_CUSTOMER_ID'
      );
    END IF;
  END IF;

  SELECT * INTO v_payment_row FROM public.payments WHERE id = p_payment_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'NOT_FOUND'
    );
  END IF;

  IF v_payment_row.payment_provider = 'razorpay' THEN
    IF p_razorpay_payment_id IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'data', null,
        'isIdempotentReplay', false,
        'errorCode', 'VALIDATION_MISSING_RAZORPAY_PAYMENT_ID'
      );
    END IF;

    IF p_razorpay_signature IS NULL AND NOT p_is_admin THEN
      RETURN jsonb_build_object(
        'success', false,
        'data', null,
        'isIdempotentReplay', false,
        'errorCode', 'VALIDATION_MISSING_RAZORPAY_SIGNATURE'
      );
    END IF;
  END IF;

  SELECT * INTO v_order_row FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'NOT_FOUND'
    );
  END IF;

  IF v_payment_row.order_id IS DISTINCT FROM v_order_row.id THEN
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'FORBIDDEN'
    );
  END IF;

  IF NOT p_is_admin AND v_order_row.customer_id IS DISTINCT FROM p_customer_id THEN
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'FORBIDDEN'
    );
  END IF;

  IF v_payment_row.status = 'pending' AND v_order_row.status = 'pending' THEN
    -- Allow execution to proceed
    NULL;
  ELSIF v_payment_row.status = 'confirmed' AND v_order_row.status = 'confirmed' THEN
    -- Fall through to Step 3 (Idempotency Guard)
    NULL;
  ELSE
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'CONFLICT'
    );
  END IF;


  -- ==========================================================================
  -- 3. IDEMPOTENCY GUARD
  -- ==========================================================================
  SELECT EXISTS(
    SELECT 1 FROM public.ledger_entries
    WHERE order_id = p_order_id AND payment_id = p_payment_id AND status = 'confirmed'
  ) INTO v_ledger_confirmed;

  IF (v_payment_row.credited_at IS NOT NULL) AND v_ledger_confirmed THEN
    v_is_idempotent_replay := TRUE;
    
    SELECT operation_key INTO v_operation_key
    FROM public.ledger_entries
    WHERE order_id = p_order_id AND payment_id = p_payment_id AND status = 'confirmed'
    ORDER BY id ASC
    LIMIT 1;

    v_order_status        := v_order_row.status;
    v_amount_paise        := v_payment_row.amount_paise;
    v_razorpay_payment_id := v_payment_row.razorpay_payment_id;
    v_credited_at         := v_payment_row.credited_at;
    
  ELSIF (v_payment_row.credited_at IS NOT NULL) OR v_ledger_confirmed THEN
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'CONFLICT'
    );
  ELSE
    v_is_idempotent_replay := FALSE;
  END IF;


  -- ==========================================================================
  -- 4. PAYMENT / ORDER / LEDGER LOOKUP
  -- ==========================================================================
  IF NOT v_is_idempotent_replay THEN
    SELECT count(*), max(operation_key) INTO v_ledger_pending_count, v_operation_key
    FROM public.ledger_entries
    WHERE order_id = p_order_id AND payment_id = p_payment_id AND status = 'pending';

    IF v_ledger_pending_count = 0 THEN
      RETURN jsonb_build_object(
        'success', false,
        'data', null,
        'isIdempotentReplay', false,
        'errorCode', 'CONFLICT'
      );
    END IF;
  END IF;


  -- ==========================================================================
  -- 5. ATOMIC STATE TRANSITIONS
  -- ==========================================================================
  IF NOT v_is_idempotent_replay THEN
    BEGIN
      -- Mutate state sequentially, validating uniqueness via RETURNING clauses
      UPDATE public.payments 
      SET status = 'confirmed', 
          razorpay_payment_id = COALESCE(p_razorpay_payment_id, razorpay_payment_id), 
          razorpay_signature = COALESCE(p_razorpay_signature, razorpay_signature), 
          transaction_id = COALESCE(p_transaction_id, transaction_id),
          credited_at = v_now 
      WHERE id = p_payment_id AND status = 'pending'
      RETURNING 1 INTO v_payment_rows_updated;

      IF v_payment_rows_updated IS NULL THEN
        RAISE EXCEPTION 'state_transition_conflict';
      END IF;

      UPDATE public.orders 
      SET status = 'confirmed' 
      WHERE id = p_order_id AND status = 'pending'
      RETURNING 1 INTO v_order_rows_updated;

      IF v_order_rows_updated IS NULL THEN
        RAISE EXCEPTION 'state_transition_conflict';
      END IF;

      UPDATE public.ledger_entries 
      SET status = 'confirmed', 
          confirmed_at = v_now 
      WHERE order_id = p_order_id AND payment_id = p_payment_id AND status = 'pending'
      RETURNING operation_key INTO v_operation_key;

      IF v_operation_key IS NULL THEN
        RAISE EXCEPTION 'state_transition_conflict';
      END IF;

    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM = 'state_transition_conflict' THEN
          RETURN jsonb_build_object(
            'success', false,
            'data', null,
            'isIdempotentReplay', false,
            'errorCode', 'CONFLICT'
          );
        ELSE
          RAISE;
        END IF;
    END;
  END IF;


  -- ==========================================================================
  -- 6. RESPONSE CONSTRUCTION
  -- ==========================================================================
  IF v_is_idempotent_replay THEN
    v_replay_data := jsonb_build_object(
      'paymentId', p_payment_id,
      'orderId', p_order_id,
      'status', v_order_status,
      'amountPaise', v_amount_paise,
      'razorpayPaymentId', v_razorpay_payment_id,
      'operationKey', v_operation_key,
      'creditedAt', v_credited_at
    );

    v_response := jsonb_build_object(
      'success', true,
      'data', v_replay_data,
      'isIdempotentReplay', true,
      'errorCode', null
    );
    RETURN v_response;
  ELSE
    v_amount_paise := v_payment_row.amount_paise;
    
    v_response := jsonb_build_object(
      'success', true,
      'data', jsonb_build_object(
        'paymentId', p_payment_id,
        'orderId', p_order_id,
        'status', 'confirmed',
        'amountPaise', v_amount_paise,
        'razorpayPaymentId', p_razorpay_payment_id,
        'operationKey', v_operation_key,
        'creditedAt', v_now
      ),
      'isIdempotentReplay', false,
      'errorCode', null
    );
    RETURN v_response;
  END IF;


  -- ==========================================================================
  -- 7. ERROR HANDLING
  -- ==========================================================================
  -- Catch-all for unexpected database failures. By design, we suppress 
  -- all PostgreSQL internals (SQLSTATE, SQLERRM) to prevent information 
  -- leakage. No internal logging is performed at this tier; failures are 
  -- normalized into a canonical INTERNAL_ERROR contract for the client.
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'data', null,
      'isIdempotentReplay', false,
      'errorCode', 'INTERNAL_ERROR'
    );
END;
$$;

-- ============================================================================
-- Grants
-- ============================================================================
REVOKE ALL ON FUNCTION public.create_payment_confirm(UUID, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_payment_confirm(UUID, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.create_payment_confirm(UUID, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT) TO service_role;

-- ============================================================================
-- Documentation
-- ============================================================================
COMMENT ON FUNCTION public.create_payment_confirm(UUID, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT) IS
'Phase 3 confirm-step RPC. Finalizes payment/order/ledger status following
successful Razorpay confirmation. Idempotent via credited_at + ledger_entries.status
dual guard (first-writer-wins). Enforces atomic state transitions and sanitizes
all runtime errors into a canonical JSONB response contract.';
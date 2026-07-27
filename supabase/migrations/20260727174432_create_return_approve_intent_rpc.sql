/* Phase 4 Task 1 

 Structural skeleton only.

 Business logic intentionally deferred to Phase 4 Task 2. */

CREATE OR REPLACE FUNCTION public.approve_return_intent(
    p_order_item_id UUID,
    p_vendor_id UUID,
    p_customer_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public, pg_temp
AS $$
DECLARE
    -- order item
    v_order_item RECORD;
    v_order_item_status text;
    v_order_item_vendor_id UUID;
    v_ledger_entry_id UUID;
    -- order
    v_order RECORD;
    v_order_customer_id UUID;
    v_order_payment_id UUID;
    -- payment
    v_payment RECORD;
    v_payment_vendor_earnings BIGINT;
    v_payment_platform_commission BIGINT;
    -- vendor
    v_vendor_withdrawable_balance BIGINT;
    v_projected_balance_paise BIGINT;
    v_requires_escalation BOOLEAN;
    
    -- escalation
    v_escalation RECORD;
    
    -- refund calculation
    v_refund_amount_paise BIGINT;
    
    -- reversal calculation
    v_vendor_reversal_paise BIGINT;
    
    -- operation key
    v_operation_key TEXT;
    
    -- escalation id
    v_escalation_id UUID;
    
    -- idempotency flag
    v_is_idempotent_replay BOOLEAN := false;
    
    -- timestamps
    v_now TIMESTAMPTZ := now();
    
    -- response variables
    v_error_code TEXT;
    v_response_data JSONB;
    v_response JSONB := jsonb_build_object('success', false, 'data', null, 'isIdempotentReplay', false, 'errorCode', 'NOT_IMPLEMENTED');
BEGIN
    -------------------------------------------------------------------------
    -- 1. Authorization
    -------------------------------------------------------------------------
    -- SECURITY DEFINER forces us to manually verify the caller's identity.
    IF auth.uid() IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.vendors WHERE id = p_vendor_id AND user_id = auth.uid()
    ) THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"UNAUTHORIZED"');
        RETURN v_response;
    END IF;

    -------------------------------------------------------------------------
    -- 2. Validation & Ownership Verification
    -------------------------------------------------------------------------
    -- 1. Fetch the order item
    SELECT * INTO v_order_item
    FROM public.order_items
    WHERE id = p_order_item_id
    FOR UPDATE;

    IF v_order_item IS NULL THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"NOT_FOUND"');
        RETURN v_response;
    END IF;

    -- 2. Validate return status
    IF v_order_item.return_status <> 'requested' THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"VALIDATION_FAILED"');
        RETURN v_response;
    END IF;

    -- 3. Fetch the parent order
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = v_order_item.order_id;

    IF v_order IS NULL THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"NOT_FOUND"');
        RETURN v_response;
    END IF;

    -- 4. Vendor verification
    IF v_order_item.vendor_id <> p_vendor_id THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"FORBIDDEN"');
        RETURN v_response;
    END IF;

    -- 5. Customer verification
    IF v_order.customer_id <> p_customer_id THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"FORBIDDEN"');
        RETURN v_response;
    END IF;

    -- 6. Preserve data for later sections
    v_order_item_status := v_order_item.return_status;
    v_order_item_vendor_id := v_order_item.vendor_id;
    v_order_customer_id := v_order.customer_id;
    v_order_payment_id := v_order.payment_id;

    -------------------------------------------------------------------------
    -- 3. Commission & Refund Calculation
    -------------------------------------------------------------------------
    -- Retrieve the canonical payment record for the validated order
    SELECT * INTO v_payment
    FROM public.payments
    WHERE id = v_order_payment_id;

    IF v_payment IS NULL THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"PAYMENT_NOT_FOUND"');
        RETURN v_response;
    END IF;

    -- Store for reference in paise
    -- Retained ROUND(x * 100) because payments stores values as NUMERIC (rupees)
    v_payment_vendor_earnings := ROUND(v_payment.vendor_earnings * 100)::BIGINT;
    v_payment_platform_commission := ROUND(v_payment.platform_commission * 100)::BIGINT;

    -- Determine the full refund amount in integer paise
    -- Retained ROUND(x * 100) because order_items.price is NUMERIC (rupees)
    v_refund_amount_paise := ROUND(v_order_item.price * v_order_item.quantity * 100)::BIGINT;

    -- Retrieve canonical vendor earnings directly from the ledger to completely 
    -- avoid duplicate arithmetic and preserve exact Phase 3 calculations.
    -- type = 'credit' natively isolates the initial earning as adjustments use distinct enum values.
    SELECT id, amount_paise INTO v_ledger_entry_id, v_vendor_reversal_paise
    FROM public.ledger_entries
    WHERE order_item_id = p_order_item_id
      AND type = 'credit'
      AND status = 'confirmed';

    IF v_vendor_reversal_paise IS NULL THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"LEDGER_ENTRY_MISSING"');
        RETURN v_response;
    END IF;

    -------------------------------------------------------------------------
    -- 4. Balance Check
    -------------------------------------------------------------------------
    -- Retrieve the vendor's canonical withdrawable balance (which is stored in paise)
    SELECT withdrawable_balance INTO v_vendor_withdrawable_balance
    FROM public.vendors
    WHERE id = v_order_item_vendor_id;

    IF v_vendor_withdrawable_balance IS NULL THEN
        v_response := jsonb_set(v_response, '{errorCode}', '"VENDOR_NOT_FOUND"');
        RETURN v_response;
    END IF;

    -- Compute the projected post-reversal balance without writing to the database
    v_projected_balance_paise := v_vendor_withdrawable_balance - v_vendor_reversal_paise;
    
    -- Set the escalation flag based strictly on the projected balance
    v_requires_escalation := v_projected_balance_paise < 0;

    -------------------------------------------------------------------------
    -- 5. Atomic State Transition
    -------------------------------------------------------------------------
    -- 1. Generate canonical operation key (hoisted for reuse across branches)
    v_operation_key := 'rtn_' || gen_random_uuid()::text;

    IF NOT v_requires_escalation THEN
        -- 2. Transition order item
        -- Row lock was exclusively acquired in Section 2, but we defensively 
        -- verify the state hasn't been corrupted before mutation.
        UPDATE public.order_items
        SET return_status = 'reversing'
        WHERE id = p_order_item_id
          AND return_status = v_order_item_status;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'state_transition_conflict';
        END IF;

        -- 3. Create pending reversal ledger entry
        -- Insertion natively reserves funds via the ledger projection trigger
        INSERT INTO public.ledger_entries (
            vendor_id,
            order_id,
            order_item_id,
            type,
            status,
            amount_paise,
            operation_key
        ) VALUES (
            v_order_item_vendor_id,
            v_order.id,
            p_order_item_id,
            'reversal'::ledger_entry_type,
            'pending'::ledger_entry_status,
            v_vendor_reversal_paise,
            v_operation_key
        );
    ELSE
        -- 2. Transition the order item into the canonical escalation state
        -- The existing return workflow canonically uses 'approved' when processing
        -- a return that forces an overdraft/escalation scenario.
        UPDATE public.order_items
        SET return_status = 'approved'
        WHERE id = p_order_item_id
          AND return_status = v_order_item_status;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'state_transition_conflict';
        END IF;

        -- 3 & 4. Create the payment escalation preserving canonical financial context
        -- We deliberately do NOT reserve funds or write to the ledger here.
        -- Instead, we natively link back to the exact initial credit ledger entry.
        INSERT INTO public.payment_escalations (
            ledger_entry_id,
            vendor_id,
            reason,
            status
        ) VALUES (
            v_ledger_entry_id,
            v_order_item_vendor_id,
            'insufficient_balance'::escalation_reason,
            'open'::escalation_status
        ) RETURNING * INTO v_escalation;
    END IF;

    -------------------------------------------------------------------------
    -- 6. Response Construction
    -------------------------------------------------------------------------
    -- TODO: Construct successful response object.

    RETURN v_response;

    -------------------------------------------------------------------------
    -- 7. Error Handling
    -------------------------------------------------------------------------
EXCEPTION
    -- TODO: SERIALIZATION_FAILURE
    -- TODO: UNIQUE_VIOLATION
    -- TODO: CHECK_VIOLATION
    -- TODO: Others
    WHEN OTHERS THEN
        -- TODO: Normalize errors. Log SQLSTATE and SQLERRM without leaking to API.
        
        v_response := jsonb_set(v_response, '{errorCode}', '"INTERNAL_ERROR"');
        RETURN v_response;
END;
$$;

REVOKE ALL
ON FUNCTION public.approve_return_intent(UUID, UUID, UUID)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION public.approve_return_intent(UUID, UUID, UUID)
TO service_role;

COMMENT ON FUNCTION public.approve_return_intent(UUID, UUID, UUID)
IS 'Skeleton implementation for the canonical return approval intent RPC. Business logic is intentionally deferred to Phase 4 Task 2.';

-- Migration: Drop on_payment_success trigger and function
--
-- Purpose:
-- Remove the legacy implicit database trigger and function previously responsible 
-- for applying financial side effects upon payment success.
--
-- Architectural Rationale:
-- Financial state transitions and vendor ledger mutability have been exclusively
-- delegated to the canonical `create_payment_confirm` RPC. Relying on implicit 
-- database triggers for side-effect balance changes is an obsolete anti-pattern.
--
-- Operational Caveat:
-- Production deployment should occur only after operational verification confirms 
-- the trigger is no longer required. Do not deploy unless static codebase analysis 
-- confirms all success paths strictly route to the canonical RPC.

-- Drop all triggers that depend on on_payment_success() before dropping the function.
-- Discovered via db reset: three triggers reference this function.
DROP TRIGGER IF EXISTS trigger_on_payment_success ON public.payments;
DROP TRIGGER IF EXISTS trg_payment_success ON public.payments;
DROP TRIGGER IF EXISTS trg_payment_success_insert ON public.payments;
DROP FUNCTION IF EXISTS public.on_payment_success();

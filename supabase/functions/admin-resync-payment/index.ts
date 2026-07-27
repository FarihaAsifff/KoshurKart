// Admin tool: re-fetches a payment from Razorpay and reconciles status server-side.
import { ERROR_CODES } from "../../../src/shared/errorCodes.ts";
import { PaymentError, respondWithError } from "../../../src/shared/errorResponse.ts";
import { ErrorCategory } from "../../../src/shared/statusCodeMap.ts";
// Admin-only via has_role check.
import { createClient } from "npm:@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return respondWithError(new PaymentError(ErrorCategory.AUTHENTICATION, ERROR_CODES.INTERNAL_ERROR, "Unauthorized", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const anon = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: userError } = await anon.auth.getUser();
    if (userError || !user) {
      return respondWithError(new PaymentError(ErrorCategory.AUTHENTICATION, ERROR_CODES.INTERNAL_ERROR, "Unauthorized", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const service = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: isAdmin } = await service.rpc("has_role", { _user_id: user.id, _role: "admin" });
    if (!isAdmin) {
      return respondWithError(new PaymentError(ErrorCategory.AUTHORIZATION, ERROR_CODES.INTERNAL_ERROR, "Forbidden", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const { paymentId } = await req.json();
    if (!paymentId) {
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INTERNAL_ERROR, "paymentId is required", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const keyId = Deno.env.get("RAZORPAY_KEY_ID");
    const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET");
    if (!keyId || !keySecret) {
      return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Razorpay credentials not configured", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const { data: payment, error: payErr } = await service
      .from("payments")
      .select("id, order_id, user_id, amount, payment_status, razorpay_order_id, razorpay_payment_id")
      .eq("id", paymentId)
      .maybeSingle();

    if (payErr) {
      console.error("[admin-resync-payment] payment DB lookup error", payErr.code, payErr.message);
      return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Internal server error", false), { ...corsHeaders, "Content-Type": "application/json" });
    }
    if (!payment) {
      return respondWithError(new PaymentError(ErrorCategory.NOT_FOUND, ERROR_CODES.INTERNAL_ERROR, "Payment not found", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    if (!payment.razorpay_order_id) {
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INTERNAL_ERROR, "Payment has no Razorpay order id", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const auth = "Basic " + btoa(`${keyId}:${keySecret}`);

    let rpRes;
    try {
      rpRes = await fetch(
        `https://api.razorpay.com/v1/orders/${payment.razorpay_order_id}/payments`,
        { headers: { Authorization: auth } },
      );
      if (!rpRes.ok) {
        const t = await rpRes.text();
        let errorCode = "UNKNOWN";
        try {
          const parsed = JSON.parse(t);
          errorCode = parsed?.error?.code || errorCode;
        } catch { /* keep default */ }
        throw new Error(`Razorpay API error: ${rpRes.status} ${errorCode} ${t}`);
      }
    } catch (err) {
      const msg = (err as Error).message.toLowerCase();
      console.error("Razorpay fetch failed:", msg);
      if (msg.includes("rate") || msg.includes("throttle") || msg.includes("429")) {
        return respondWithError(new PaymentError(ErrorCategory.RATE_LIMIT, ERROR_CODES.INTERNAL_ERROR, "Gateway rate limited. Please try again later.", true), { ...corsHeaders, "Content-Type": "application/json" });
      }
      return respondWithError(new PaymentError(ErrorCategory.GATEWAY_ERROR, ERROR_CODES.INTERNAL_ERROR, "Razorpay fetch failed", false), { ...corsHeaders, "Content-Type": "application/json" });
    }
    const rpBody = await rpRes.json();
    const rpPayments: any[] = rpBody?.items ?? [];
    const captured = rpPayments.find((p) => p.status === "captured");
    const expectedPaise = Math.round(Number(payment.amount) * 100);

    let newStatus = payment.payment_status;
    let updateFields: Record<string, unknown> = {};

    if (captured) {
      if (captured.amount !== expectedPaise || captured.currency !== "INR") {
        await service.rpc("log_payment_event", {
          p_payment_id: payment.id,
          p_event_type: "admin_resync_mismatch",
          p_message: "Admin re-sync found amount/currency mismatch",
          p_metadata: { expected_paise: expectedPaise, actual_paise: captured.amount, currency: captured.currency },
        });
        return new Response(JSON.stringify({ ok: false, mismatch: true }), {
          status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      newStatus = "success";
      updateFields = {
        payment_status: "success",
        razorpay_payment_id: captured.id,
        transaction_id: captured.id,
      };
    } else if (rpPayments.some((p) => p.status === "failed")) {
      newStatus = "failed";
      updateFields = { payment_status: "failed" };
    } else {
      await service.rpc("log_payment_event", {
        p_payment_id: payment.id,
        p_event_type: "admin_resync_no_change",
        p_message: "Razorpay reports no terminal status yet",
        p_metadata: { gateway_payments: rpPayments.length },
      });
      return new Response(JSON.stringify({ ok: true, changed: false, status: payment.payment_status }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (newStatus !== payment.payment_status) {
      if (newStatus === "success") {
        const { data: confirmResult, error: confirmError } = await service.rpc("create_payment_confirm", {
          p_payment_id: payment.id,
          p_order_id: payment.order_id,
          p_customer_id: payment.user_id,
          p_razorpay_payment_id: captured.id,
          p_razorpay_signature: null,
          p_is_admin: true,
          p_transaction_id: captured.id,
        });

        if (confirmError) {
          console.error("create_payment_confirm failed", confirmError);
          return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Confirmation failed", false), { ...corsHeaders, "Content-Type": "application/json" });
        }

        if (!confirmResult || typeof confirmResult !== 'object' || Array.isArray(confirmResult) || typeof confirmResult.success !== 'boolean') {
          console.error("RPC contract violation: Malformed payload");
          return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Internal server error", false), { ...corsHeaders, "Content-Type": "application/json" });
        }

        if (confirmResult.success !== true) {
          console.error("Payment confirmation rejected:", confirmResult.error || confirmResult.message || "Unknown error");
          return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Payment confirmation failed", false), { ...corsHeaders, "Content-Type": "application/json" });
        }
      } else {
        const { error: upErr } = await service.from("payments").update(updateFields).eq("id", payment.id);
        if (upErr) {
          console.error("Update failed", upErr);
          return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Update failed", false), { ...corsHeaders, "Content-Type": "application/json" });
        }
        if (newStatus === "failed") {
          await service.from("orders").update({ payment_status: "failed" }).eq("id", payment.order_id);
        }
      }
    }

    await service.rpc("log_payment_event", {
      p_payment_id: payment.id,
      p_event_type: "admin_resync",
      p_message: `Admin re-synced payment; new status: ${newStatus}`,
      p_metadata: { previous: payment.payment_status, new: newStatus, actor: user.id },
    });

    return new Response(JSON.stringify({ ok: true, status: newStatus, changed: true }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("admin-resync-payment error:", (err as Error).message);
    return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Internal server error", false), { ...corsHeaders, "Content-Type": "application/json" });
  }
});

import { createClient } from "npm:@supabase/supabase-js@2.45.0";
import { ERROR_CODES } from "../../../src/shared/errorCodes.ts";
import { PaymentError, respondWithError } from "../../../src/shared/errorResponse.ts";
import { ErrorCategory } from "../../../src/shared/statusCodeMap.ts";

// Simple RFC-4122 UUID v4 regex for request-level validation.
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

function redact(s: string | null | undefined): string {
  if (!s) return "";
  if (s.length <= 8) return "***";
  return `${s.slice(0, 4)}***${s.slice(-2)}`;
}

async function verifySignature(
  orderId: string,
  paymentId: string,
  signature: string,
  secret: string,
): Promise<boolean> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const data = encoder.encode(`${orderId}|${paymentId}`);
  const sig = await crypto.subtle.sign("HMAC", key, data);
  const expected = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  // Constant-time compare
  if (expected.length !== signature.length) return false;
  let mismatch = 0;
  for (let i = 0; i < expected.length; i++) {
    mismatch |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return mismatch === 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return respondWithError(new PaymentError(ErrorCategory.AUTHENTICATION, ERROR_CODES.INTERNAL_ERROR, "Unauthorized", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const anonClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: userError } = await anonClient.auth.getUser();
    if (userError || !user) {
      return respondWithError(new PaymentError(ErrorCategory.AUTHENTICATION, ERROR_CODES.INTERNAL_ERROR, "Unauthorized", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const { razorpayOrderId, razorpayPaymentId, razorpaySignature, paymentId, orderId } =
      await req.json();

    if (!razorpayOrderId || !razorpayPaymentId || !razorpaySignature || !paymentId || !orderId) {
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INTERNAL_ERROR, "Missing required fields", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    if (!UUID_REGEX.test(orderId)) {
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INVALID_ORDER_ID_FORMAT, `Invalid order ID format. Expected UUID, got: "${orderId}"`, false), { ...corsHeaders, "Content-Type": "application/json" });
    }
    if (!UUID_REGEX.test(paymentId)) {
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INVALID_PAYMENT_ID_FORMAT, `Invalid payment ID format. Expected UUID, got: "${paymentId}"`, false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const keyId = Deno.env.get("RAZORPAY_KEY_ID");
    const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET");
    if (!keyId || !keySecret) {
      return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Razorpay credentials not configured", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const isValid = await verifySignature(razorpayOrderId, razorpayPaymentId, razorpaySignature, keySecret);
    if (!isValid) {
      console.error("Signature verification failed for order", redact(razorpayOrderId));
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INTERNAL_ERROR, "Payment verification failed: invalid signature", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const service = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: paymentRow, error: payFetchErr } = await service
      .from("payments")
      .select("id, order_id, user_id, amount, payment_status, razorpay_payment_id")
      .eq("id", paymentId)
      .maybeSingle();

    if (payFetchErr) {
      console.error("[verify-razorpay-payment] payment DB lookup error", payFetchErr.code, payFetchErr.message);
      return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Internal server error", false), { ...corsHeaders, "Content-Type": "application/json" });
    }
    if (!paymentRow) {
      return respondWithError(new PaymentError(ErrorCategory.NOT_FOUND, ERROR_CODES.INTERNAL_ERROR, "Payment not found", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    if (paymentRow.user_id !== user.id) {
      return respondWithError(new PaymentError(ErrorCategory.AUTHORIZATION, ERROR_CODES.INTERNAL_ERROR, "Forbidden", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    if (paymentRow.order_id !== orderId) {
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INTERNAL_ERROR, "Order mismatch", false), { ...corsHeaders, "Content-Type": "application/json" });
    }



    let rpRes;
    try {
      rpRes = await fetch(`https://api.razorpay.com/v1/orders/${razorpayOrderId}`, {
        headers: { Authorization: "Basic " + btoa(`${keyId}:${keySecret}`) },
      });
      if (!rpRes.ok) {
        const errBody = await rpRes.text();
        throw new Error(`Razorpay API error: ${rpRes.status} ${errBody}`);
      }
    } catch (err) {
      const msg = (err as Error).message.toLowerCase();
      console.error("Razorpay order fetch failed:", msg);
      if (msg.includes("rate") || msg.includes("throttle") || msg.includes("429")) {
        return respondWithError(new PaymentError(ErrorCategory.RATE_LIMIT, ERROR_CODES.INTERNAL_ERROR, "Gateway rate limited. Please try again later.", true), { ...corsHeaders, "Content-Type": "application/json" });
      }
      
      const match = msg.match(/razorpay api error: (\d+)/);
      const gwStatus = match ? parseInt(match[1], 10) : 500;

      if (gwStatus >= 400 && gwStatus < 500) {
        return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.RAZORPAY_CLIENT_ERROR, "Invalid Razorpay order reference", false), { ...corsHeaders, "Content-Type": "application/json" });
      }
      return respondWithError(new PaymentError(ErrorCategory.GATEWAY_ERROR, ERROR_CODES.RAZORPAY_SERVER_ERROR, "Payment gateway error. Status pending verification.", false), { ...corsHeaders, "Content-Type": "application/json" });
    }
    const rpOrder = await rpRes.json();

    if (rpOrder.status !== "paid") {
      console.error("Razorpay order not paid", { rpOrderId: razorpayOrderId, status: rpOrder.status });
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INTERNAL_ERROR, "Payment not captured by gateway", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const expectedPaise = Math.round(Number(paymentRow.amount) * 100);
    if (rpOrder.amount !== expectedPaise || rpOrder.currency !== "INR") {
      console.error("Amount/currency mismatch", { expectedPaise, got: rpOrder.amount });
      await service.from("analytics_events").insert({
        event_type: "payment_amount_mismatch",
        user_id: user.id,
        metadata: {
          payment_id: paymentId,
          expected_paise: expectedPaise,
          actual_paise: rpOrder.amount,
          currency: rpOrder.currency,
        },
      });
      return respondWithError(new PaymentError(ErrorCategory.VALIDATION, ERROR_CODES.INTERNAL_ERROR, "Payment amount mismatch", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    const { data: confirmResult, error: confirmError } = await service.rpc("create_payment_confirm", {
      p_payment_id: paymentRow.id,
      p_order_id: paymentRow.order_id,
      p_customer_id: user.id,
      p_razorpay_payment_id: razorpayPaymentId,
      p_razorpay_signature: razorpaySignature,
      p_transaction_id: razorpayPaymentId
    });

    if (confirmError) {
      console.error("RPC transport/DB failure:", confirmError);
      return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Internal server error", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    if (!confirmResult || typeof confirmResult !== "object") {
      console.error("RPC contract violation: Malformed payload");
      return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Internal server error", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    if (confirmResult.success !== true) {
      console.error("RPC logical failure:", confirmResult.errorCode);
      let mappedCategory = ErrorCategory.INTERNAL_ERROR;
      let mappedCode = ERROR_CODES.INTERNAL_ERROR;

      if (confirmResult.errorCode === 'FORBIDDEN') {
        mappedCategory = ErrorCategory.AUTHORIZATION;
        mappedCode = ERROR_CODES.FORBIDDEN;
      } else if (confirmResult.errorCode === 'NOT_FOUND') {
        mappedCategory = ErrorCategory.NOT_FOUND;
        mappedCode = ERROR_CODES.NOT_FOUND;
      } else if (confirmResult.errorCode === 'CONFLICT') {
        mappedCategory = ErrorCategory.VALIDATION;
        mappedCode = ERROR_CODES.CONFLICT;
      } else if (typeof confirmResult.errorCode === 'string' && confirmResult.errorCode.startsWith('VALIDATION')) {
        mappedCategory = ErrorCategory.VALIDATION;
        mappedCode = ERROR_CODES.VALIDATION_ERROR;
      }
      
      return respondWithError(new PaymentError(mappedCategory, mappedCode, "Payment confirmation failed", false), { ...corsHeaders, "Content-Type": "application/json" });
    }

    await service.rpc("log_payment_event", {
      p_payment_id: paymentId,
      p_event_type: "verify_success",
      p_message: "Client-side verify completed and signature validated",
      p_metadata: { razorpay_payment_id: razorpayPaymentId, razorpay_order_id: razorpayOrderId },
    });

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: "Payment verified and confirmed",
        idempotent: confirmResult.isIdempotentReplay === true
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("verify-razorpay-payment error:", (err as Error).message);
    return respondWithError(new PaymentError(ErrorCategory.INTERNAL_ERROR, ERROR_CODES.INTERNAL_ERROR, "Internal server error", false), { ...corsHeaders, "Content-Type": "application/json" });
  }
});

import test from "node:test";
import assert from "node:assert/strict";

process.env.NODE_ENV = "test";
process.env.APP_BEARER_TOKEN = "test";
process.env.MISTRAL_API_KEY = "test";

const {
  extractFallbackBankTransactionsFromOcrText,
  hashIdentifier,
  normalizeAnalyticsFailureReason,
  reconcileReceipt,
  resolveFinancialContradictions,
  sanitizeAnalyticsProperties,
  safeString,
  summarizeAnalytics,
} = await import("../server.js");

test("sanitizeAnalyticsProperties redacts raw upload and OCR payloads", () => {
  const sanitized = sanitizeAnalyticsProperties({
    imageBase64: "data:image/png;base64,abc123",
    fileBase64: "data:application/pdf;base64,abc123",
    ocrText: "TOTAL 12.34",
    nested: {
      sourceText: "Private bank row",
      safeCount: 3,
    },
  });

  assert.equal(sanitized.imageBase64, "[REDACTED]");
  assert.equal(sanitized.fileBase64, "[REDACTED]");
  assert.equal(sanitized.ocrText, "[REDACTED]");
  assert.equal(sanitized.nested.sourceText, "[REDACTED]");
  assert.equal(sanitized.nested.safeCount, 3);
});

test("safeString redacts common sensitive values", () => {
  const output = safeString("Bearer secret-token account number 1234567890123456 email test@example.com phone +1 217 974 6228");

  assert.match(output, /Bearer \[REDACTED\]/);
  assert.match(output, /\[REDACTED_CARD_OR_ACCOUNT\]|\[REDACTED_PHONE_OR_ACCOUNT\]/);
  assert.match(output, /\[REDACTED_EMAIL\]/);
  assert.doesNotMatch(output, /test@example\.com/);
});

test("normalizeAnalyticsFailureReason maps unknown provider errors safely", () => {
  assert.equal(normalizeAnalyticsFailureReason("receipt", "MISTRAL_TIMEOUT"), "backend_timeout");
  assert.equal(normalizeAnalyticsFailureReason("receipt", "UNSUPPORTED_FILE_TYPE"), "unsupported_file_type");
  assert.equal(normalizeAnalyticsFailureReason("statement", "SCHEMA_VALIDATION_FAILED"), "parse_failed");
  assert.equal(normalizeAnalyticsFailureReason("statement", "something surprising"), "unknown_error");
});

test("hashIdentifier is stable and does not expose source identifier", () => {
  const first = hashIdentifier("invite-123");
  const second = hashIdentifier("invite-123");

  assert.equal(first, second);
  assert.notEqual(first, "invite-123");
  assert.equal(first.length, 24);
});

test("summarizeAnalytics reports success rates and common errors", () => {
  const events = [
    { event_name: "receipt_upload_started", user_id: "u1", session_id: "s1", properties: {}, created_at: new Date().toISOString() },
    { event_name: "receipt_ocr_started", user_id: "u1", session_id: "s1", properties: {}, created_at: new Date().toISOString() },
    { event_name: "receipt_ocr_completed", user_id: "u1", session_id: "s1", properties: { processing_time_ms: 100 }, created_at: new Date().toISOString() },
    { event_name: "receipt_parse_completed", user_id: "u1", session_id: "s1", properties: { processing_time_ms: 150 }, created_at: new Date().toISOString() },
    { event_name: "receipt_upload_rejected", user_id: "u2", session_id: "s2", properties: { failure_reason: "invalid_document" }, created_at: new Date().toISOString() },
  ];

  const summary = summarizeAnalytics(events);

  assert.equal(summary.total_events, 5);
  assert.equal(summary.unique_users, 2);
  assert.equal(summary.receipt_success_rate, 100);
  assert.equal(summary.ocr_success_rate, 100);
  assert.deepEqual(summary.most_common_errors[0], { reason: "invalid_document", count: 1 });
});

test("resolveFinancialContradictions applies item discounts when item amount is pre-discount", () => {
  const receipt = {
    merchant: "COSTCO",
    currency: "USD",
    items: [
      {
        name: "WAREHOUSE ITEM",
        printedAmount: 10,
        discountAmount: 2,
        discountLabel: "INSTANT SAVINGS",
      },
    ],
    subtotal: 8,
    tax: 0,
    tip: 0,
    fees: 0,
    orderLevelDiscount: 0,
    grandTotal: 8,
    confidence: "medium",
    notes: null,
  };

  const resolved = resolveFinancialContradictions(receipt, "test_discount_apply");

  assert.equal(resolved.selectedCandidate, "printed_before_discount");
  assert.equal(resolved.receipt.items[0].amount, 8);
  assert.equal(resolved.receipt.items[0].originalAmount, 10);
  assert.equal(resolved.receipt.items[0].itemDiscount, 2);
  assert.equal(reconcileReceipt(resolved.receipt).mathCheckPassed, true);
});

test("resolveFinancialContradictions preserves item discounts when amount is already post-discount", () => {
  const receipt = {
    merchant: "GROCERY",
    currency: "USD",
    items: [
      {
        name: "SALE ITEM",
        printedAmount: 8,
        discountAmount: 2,
        discountLabel: "COUPON",
      },
    ],
    subtotal: 8,
    tax: 0,
    tip: 0,
    fees: 0,
    orderLevelDiscount: 0,
    grandTotal: 8,
    confidence: "high",
    notes: null,
  };

  const resolved = resolveFinancialContradictions(receipt, "test_discount_preserve");

  assert.equal(resolved.selectedCandidate, "printed_after_discount");
  assert.equal(resolved.receipt.items[0].amount, 8);
  assert.equal(resolved.receipt.items[0].originalAmount, 10);
  assert.equal(resolved.receipt.items[0].itemDiscount, 2);
  assert.equal(reconcileReceipt(resolved.receipt).mathCheckPassed, true);
});

test("resolveFinancialContradictions keeps weighted NET WT item rows", () => {
  const receipt = {
    merchant: "GROCERY",
    currency: "USD",
    items: [
      {
        name: "NET WT 1.5 LB APPLES",
        printedAmount: 3.99,
        discountAmount: null,
        discountLabel: null,
        weightLbs: 1.5,
      },
    ],
    subtotal: 3.99,
    tax: 0,
    tip: 0,
    fees: 0,
    orderLevelDiscount: 0,
    grandTotal: 3.99,
    confidence: "high",
    notes: null,
  };

  const resolved = resolveFinancialContradictions(receipt, "test_net_wt");

  assert.equal(resolved.receipt.items.length, 1);
  assert.equal(resolved.receipt.items[0].name, "NET WT 1.5 LB APPLES");
  assert.equal(resolved.receipt.items[0].amount, 3.99);
  assert.equal(reconcileReceipt(resolved.receipt).mathCheckPassed, true);
});

test("resolveFinancialContradictions folds same-name stray discount rows", () => {
  const receipt = {
    merchant: "COSTCO",
    currency: "USD",
    items: [
      {
        name: "WAREHOUSE ITEM",
        printedAmount: 10,
        discountAmount: null,
        discountLabel: null,
      },
      {
        name: "WAREHOUSE ITEM",
        printedAmount: 2,
        discountAmount: null,
        discountLabel: null,
      },
    ],
    subtotal: 8,
    tax: 0,
    tip: 0,
    fees: 0,
    orderLevelDiscount: 0,
    grandTotal: 8,
    confidence: "medium",
    notes: null,
  };

  const resolved = resolveFinancialContradictions(receipt, "test_duplicate_discount");

  assert.equal(resolved.receipt.items.length, 1);
  assert.equal(resolved.receipt.items[0].amount, 8);
  assert.equal(resolved.receipt.items[0].originalAmount, 10);
  assert.equal(resolved.receipt.items[0].itemDiscount, 2);
  assert.equal(reconcileReceipt(resolved.receipt).mathCheckPassed, true);
});

test("extractFallbackBankTransactionsFromOcrText parses Chase mobile account activity blocks", () => {
  const ocrText = `
Jun 8, 2026
Zelle payment to woorim(chase) 29526561124
$5,706.02
-$10.00
Zelle payment to 7632688198 29526388943
$5,716.02
-$5.00
Jun 5, 2026
Zelle payment from SIHYUN THOMPSON 29511828825
$5,833.38
$10.00
`;

  const transactions = extractFallbackBankTransactionsFromOcrText(ocrText, "account_activity_screenshot");

  assert.equal(transactions.length, 3);
  assert.equal(transactions[0].transactionDate, "06/08/2026");
  assert.equal(transactions[0].description, "Zelle payment to woorim(chase) 29526561124");
  assert.equal(transactions[0].amount, 10);
  assert.equal(transactions[0].direction, "debit");
  assert.equal(transactions[0].balanceAfterTransaction, 5706.02);
  assert.equal(transactions[2].direction, "credit");
});

test("extractFallbackBankTransactionsFromOcrText parses statement table rows", () => {
  const ocrText = `
ACCOUNT ACTIVITY
PURCHASE
04/28 & SNACK* TIGER SUGAR 186-68682146 CA 8.16
05/27 ALAMO RENT-A-CAR INGLEWOOD CA 531.90
PAYMENTS AND OTHER CREDITS
05/13 Payment Thank You-Mobile -1,200.88
`;

  const transactions = extractFallbackBankTransactionsFromOcrText(ocrText, "credit_card_activity_screenshot");

  assert.equal(transactions.length, 3);
  assert.equal(transactions[0].description, "SNACK* TIGER SUGAR 186-68682146 CA");
  assert.equal(transactions[0].amount, 8.16);
  assert.equal(transactions[0].direction, "debit");
  assert.equal(transactions[2].description, "Payment Thank You-Mobile");
  assert.equal(transactions[2].amount, 1200.88);
  assert.equal(transactions[2].direction, "credit");
});

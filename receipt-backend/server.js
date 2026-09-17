import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { Mistral } from "@mistralai/mistralai";
import { z } from "zod";
import { responseFormatFromZodObject } from "@mistralai/mistralai/extra/structChat.js";

dotenv.config();

const app = express();
app.use(cors());

const PORT = Number(process.env.PORT || 3001);
const APP_BEARER_TOKEN = process.env.APP_BEARER_TOKEN || "";
const MISTRAL_API_KEY = process.env.MISTRAL_API_KEY || "";
const TEMP_DIR = path.resolve(process.cwd(), "tmp_receipts");
const DATA_DIR = path.resolve(process.cwd(), "data");
const SAVE_TEMP_RECEIPTS = process.env.SAVE_TEMP_RECEIPTS === "true";
const RECOMMENDED_IMAGE_MAX_BYTES = 2 * 1024 * 1024;
const MISTRAL_OCR_MODEL = process.env.MISTRAL_OCR_MODEL || "mistral-ocr-4-1";
const ADMIN_BEARER_TOKEN = process.env.ADMIN_BEARER_TOKEN || "";
const ANALYTICS_EVENTS_FILE = process.env.ANALYTICS_EVENTS_FILE || path.join(DATA_DIR, "analytics_events.jsonl");
const ANALYTICS_RETENTION_DAYS = Number(process.env.ANALYTICS_RETENTION_DAYS || 90);
const ANALYTICS_MAX_EVENT_BYTES = Number(process.env.ANALYTICS_MAX_EVENT_BYTES || 16 * 1024);
const ENABLE_DEBUG_RESPONSE =
  process.env.ENABLE_DEBUG_RESPONSE === "true" &&
  process.env.NODE_ENV !== "production";
const JSON_BODY_LIMIT = process.env.JSON_BODY_LIMIT || "12mb";
app.use(express.json({ limit: JSON_BODY_LIMIT }));

const MAX_UPLOAD_BYTES = Number(process.env.MAX_UPLOAD_BYTES || 8 * 1024 * 1024);
const MAX_PDF_PAGES = Number(process.env.MAX_PDF_PAGES || 12);
const OCR_LOW_CONFIDENCE_THRESHOLD = Number(process.env.OCR_LOW_CONFIDENCE_THRESHOLD || 0.75);
const ALLOWED_MIME_TYPES = new Set([
  "application/pdf",
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
]);
const parseCache = new Map();
const CACHE_TTL_MS = Number(process.env.CACHE_TTL_MS || 10 * 60 * 1000);
const MAX_PARSE_CACHE_ENTRIES = Number(process.env.MAX_PARSE_CACHE_ENTRIES || 250);
// The client gives /parse-receipt 30s. Budget so OCR can finish and the item
// name pass (6s) still fits inside that, leaving the server room to answer with
// a real error instead of the client timing out on its own.
//
// The old 10s ceiling was below what Mistral needs to OCR a photographed
// receipt and annotate it, so slower pages were abandoned mid-flight and came
// back as 504s — a timeout budget that expired before the provider could
// answer, not a provider that was too slow.
const MISTRAL_OCR_TIMEOUT_MS = Number(
  process.env.MISTRAL_OCR_TIMEOUT_MS || process.env.RECEIPT_OCR_TIMEOUT_MS || 22000
);
const QUICK_TOTAL_TIMEOUT_MS = Number(process.env.QUICK_TOTAL_TIMEOUT_MS || 5000);
const ENABLE_STAGED_QUICK_TOTAL = process.env.ENABLE_STAGED_QUICK_TOTAL === "true";
const RECEIPT_STAGED_TARGET_MS = Number(process.env.RECEIPT_STAGED_TARGET_MS || 5000);
const STAGED_FIRST_RESPONSE_TIMEOUT_MS = Number(
  process.env.STAGED_FIRST_RESPONSE_TIMEOUT_MS || Math.max(250, RECEIPT_STAGED_TARGET_MS - 500)
);
const ENABLE_MISTRAL_WORD_CONFIDENCE = process.env.ENABLE_MISTRAL_WORD_CONFIDENCE === "true";
const ENABLE_MISTRAL_OCR_DEBUG =
  process.env.ENABLE_MISTRAL_OCR_DEBUG === "true" || ENABLE_DEBUG_RESPONSE;
const APPLE_OCR_CONTEXT_MAX_CHARS = Number(process.env.APPLE_OCR_CONTEXT_MAX_CHARS || 6000);
const LOCAL_PARSE_CONTEXT_MAX_ITEMS = Number(process.env.LOCAL_PARSE_CONTEXT_MAX_ITEMS || 40);
const RECEIPT_ARBITRATION_DEBUG =
  process.env.RECEIPT_ARBITRATION_DEBUG === "true" || ENABLE_DEBUG_RESPONSE;
const stagedReceiptJobs = new Map();
const stagedReceiptHashIndex = new Map();
const STAGED_RECEIPT_JOB_TTL_MS = Number(process.env.STAGED_RECEIPT_JOB_TTL_MS || 15 * 60 * 1000);
const MAX_STAGED_RECEIPT_JOBS = Number(process.env.MAX_STAGED_RECEIPT_JOBS || 250);

// ============================================================
// ENVIRONMENT VALIDATION
// ============================================================

if (!APP_BEARER_TOKEN) {
  console.error("❌ Missing APP_BEARER_TOKEN in environment");
  process.exit(1);
}

if (!MISTRAL_API_KEY) {
  console.error("❌ Missing MISTRAL_API_KEY in environment");
  process.exit(1);
}

fs.mkdirSync(DATA_DIR, { recursive: true });
if (SAVE_TEMP_RECEIPTS) fs.mkdirSync(TEMP_DIR, { recursive: true });

const client = new Mistral({ apiKey: MISTRAL_API_KEY });

console.log("\n" + "=".repeat(80));
console.log("  PRODUCTION RECEIPT PARSER - MISTRAL OCR SINGLE PASS");
console.log("=".repeat(80));
console.log(`  Port: ${PORT}`);
console.log(`  Environment: ${process.env.NODE_ENV || "development"}`);
console.log(`  Auth: ${APP_BEARER_TOKEN ? "✓" : "✗"}`);
console.log(`  Mistral API: ${MISTRAL_API_KEY ? "✓" : "✗"}`);
console.log("=".repeat(80) + "\n");

// ============================================================
// ZOD SCHEMAS - PRODUCTION GRADE
// ============================================================

const ConfidenceEnum = z.enum(["high", "medium", "low"]);
const StatusEnum = z.enum(["success", "partial", "needs_review"]);
const ItemCategoryEnum = z.enum([
  "produce",
  "meat_seafood",
  "dairy_eggs",
  "bakery",
  "pantry",
  "frozen",
  "beverages",
  "snacks",
  "prepared_food",
  "household",
  "personal_care",
  "health_wellness",
  "pet",
  "baby",
  "alcohol",
  "restaurant",
  "general_merchandise",
  "other",
]);

const MoneyStringSchema = z.preprocess(
  value => value == null ? null : String(value),
  z.string().nullable()
).describe("Decimal money value as text, e.g. 42.17. Do not include currency symbols; use null when not visible.");

const ReceiptItemSchema = z.object({
  itemName: z.string().describe("Exact purchased item name or description as printed. Never return subtotal, tax, tip, fees, total, payment, change, or savings summary text."),
  itemValue: MoneyStringSchema.describe("Final effective purchased-item amount that participates in receipt math after item-specific discounts. Never include tax, tip, fees, subtotal, or total."),
  discountLabel: z.string().nullable().optional().describe("Optional visible discount label tied to this item. Display metadata only."),
});

const AdditionalFeeSchema = z.object({
  feeName: z.string().describe("Visible label for one positive charge that is neither tax nor tip."),
  feeValue: MoneyStringSchema.describe("Actual charged amount. Must be positive."),
});

const MistralReceiptSchema = z.object({
  merchantName: z.string().describe("Merchant, store, or restaurant name exactly as shown. Never return address, card company, bank, payment processor, or terminal name."),
  items: z.array(ReceiptItemSchema).describe("Purchased merchandise, food, drinks, products, or services only. Never include subtotal, tax, tip, fees, total, payment, change, or savings summaries."),
  tax: MoneyStringSchema.describe("Total tax actually charged. Return 0 when no tax was charged. Tax must never appear in items[]."),
  tip: MoneyStringSchema.describe("Final tip/gratuity actually charged. Return 0 when none was charged. Suggested tips must never appear here or in items[]."),
  additionalFees: z.array(AdditionalFeeSchema).describe("Every additional charged fee that contributes to the final total but is not a purchased item, tax, or tip."),
  total: MoneyStringSchema.describe("Final grand total, amount due, balance due, or amount actually charged. Never return subtotal."),
});

const QuickReceiptTotalSchema = z.object({
  merchant: z.string().nullable().optional().describe("Merchant name from top of receipt"),
  receiptDate: z.string().nullable().optional().describe("Receipt date YYYY-MM-DD format"),
  currency: z.string().nullable().optional().describe("Currency code, usually USD"),
  subtotal: MoneyStringSchema.optional().describe("Subtotal if explicitly shown"),
  tax: MoneyStringSchema.optional().describe("Sales tax amount"),
  tip: MoneyStringSchema.optional().describe("Tip or gratuity amount"),
  fees: MoneyStringSchema.optional().describe("Service, delivery, bag, or other fees"),
  orderLevelDiscount: MoneyStringSchema.optional().describe("Order-wide discount if clearly shown"),
  grandTotal: MoneyStringSchema.optional().describe("Final amount due, balance due, grand total, or total charged"),
  confidence: ConfidenceEnum.describe("Overall confidence in totals extraction"),
  totalLabel: z.string().nullable().optional().describe("Visible label used for the selected final total"),
  notes: z.string().nullable().optional().describe("Short warning if totals are ambiguous"),
});

const NormalizedItemNameSchema = z.object({
  index: z.number().int(),
  original: z.string(),
  normalizedName: z.string(),
  confidence: z.number().min(0).max(1),
  ambiguous: z.boolean(),
  needsVerification: z.boolean(),
  possibleAlternatives: z.array(z.string()),
  reason: z.string(),
  category: ItemCategoryEnum,
  categoryConfidence: z.number().min(0).max(1),
  categoryReason: z.string(),
});

const ItemNameNormalizationResponseSchema = z.object({
  items: z.array(NormalizedItemNameSchema),
});

const BankTransactionSchema = z.object({
  transactionDate: z.string().nullable(),
  postedDate: z.string().nullable(),
  description: z.string(),
  amount: z.number(),
  direction: z.enum(["debit", "credit", "unknown"]),
  status: z.enum(["posted", "pending", "unknown"]),
  balanceAfterTransaction: z.number().nullable(),
  sourceText: z.string(),
  confidence: z.number().nullable(),
});

const BankDocumentSchema = z.object({
  documentType: z.enum([
    "bank_statement",
    "account_activity_screenshot",
    "credit_card_activity_screenshot",
  ]),
  institutionName: z.string().nullable(),
  accountName: z.string().nullable(),
  accountLast4: z.string().nullable(),
  currency: z.string().nullable(),
  statementPeriod: z.object({
    startDate: z.string().nullable(),
    endDate: z.string().nullable(),
  }),
  balances: z.object({
    openingBalance: z.number().nullable(),
    closingBalance: z.number().nullable(),
    availableBalance: z.number().nullable(),
    currentBalance: z.number().nullable(),
  }),
  transactions: z.array(BankTransactionSchema),
  partialDocument: z.boolean(),
  warnings: z.array(z.string()),
});

const SAFE_ITEM_ABBREVIATIONS = {
  KS: "Kirkland Signature",
  ORG: "Organic",
  CKN: "Chicken",
  GUAC: "Guacamole",
  SNGL: "Single-Serve",
  FR: "Free-Range",
  ABF: "Antibiotic-Free",
  ROT: "Rotisserie",
  LB: "lb",
  OZ: "oz",
  PK: "Pack",
  CT: "Count",
  ZIPLC: "Ziploc",
  TOV: "Tomatoes on the Vine",
  SLCD: "Sliced",
  EVOO: "Extra Virgin Olive Oil",
  BROCC: "Broccoli",
  PTTO: "Potato",
  YLW: "Yellow",
};

const SAFE_OCR_REPLACEMENTS = [
  [/\bBANANASS\b/gi, "Bananas"],
  [/\bTENDERION\b/gi, "Tenderloin"],
  [/\bORGSPRINGMIX\b/gi, "Organic Spring Mix"],
  [/\bSPAGHTTI\b/gi, "Spaghetti"],
  [/\bCHOPONION\b/gi, "Chopped Onion"],
  [/\bCHIPTLE\b/gi, "Chipotle"],
];

// ============================================================
// FINANCIAL DOCUMENT HELPERS
// ============================================================

function toMinorUnits(value, currency = "USD") {
  if (value == null || Number.isNaN(Number(value))) return null;
  const decimals = ["JPY", "KRW"].includes(String(currency).toUpperCase()) ? 0 : 2;
  return Math.round(Number(value) * Math.pow(10, decimals));
}

function fromMinorUnits(value, currency = "USD") {
  if (value == null) return null;
  const decimals = ["JPY", "KRW"].includes(String(currency).toUpperCase()) ? 0 : 2;
  return Number((value / Math.pow(10, decimals)).toFixed(decimals));
}

function moneyEqualWithinTolerance(a, b, toleranceMinorUnits = 1) {
  if (a == null || b == null) return false;
  return Math.abs(a - b) <= toleranceMinorUnits;
}

function detectMimeType(buffer, claimedMimeType = "") {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) return null;
  if (buffer.subarray(0, 4).toString("latin1") === "%PDF") return "application/pdf";
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return "image/jpeg";
  if (buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (buffer.subarray(0, 4).toString("latin1") === "RIFF" && buffer.subarray(8, 12).toString("latin1") === "WEBP") return "image/webp";
  const brand = buffer.subarray(4, 12).toString("latin1");
  if (brand.includes("ftypheic") || brand.includes("ftypheix") || brand.includes("ftyphevc") || brand.includes("ftypmif1")) return "image/heic";
  return ALLOWED_MIME_TYPES.has(claimedMimeType) ? claimedMimeType : null;
}

function validateUploadBuffer(buffer, claimedMimeType) {
  if (!buffer || buffer.length < 128) {
    return { ok: false, status: 400, code: "UNSUPPORTED_FILE_TYPE", message: "File is too small or corrupt." };
  }
  if (buffer.length > MAX_UPLOAD_BYTES) {
    return { ok: false, status: 413, code: "FILE_TOO_LARGE", message: "This file is too large to parse." };
  }
  const actualMimeType = detectMimeType(buffer, claimedMimeType);
  if (!actualMimeType || !ALLOWED_MIME_TYPES.has(actualMimeType)) {
    return { ok: false, status: 415, code: "UNSUPPORTED_FILE_TYPE", message: "Unsupported file type. Upload a PDF, JPG, PNG, WEBP, or HEIC file." };
  }
  return { ok: true, mimeType: actualMimeType };
}

function getTempExtension(mimeType) {
  if (mimeType === "application/pdf") return ".pdf";
  if (mimeType === "image/png") return ".png";
  if (mimeType === "image/webp") return ".webp";
  if (mimeType === "image/heic") return ".heic";
  return ".jpg";
}

function buildMistralDocument(buffer, mimeType) {
  const base64 = buffer.toString("base64");
  const dataUrl = `data:${mimeType};base64,${base64}`;
  if (mimeType === "application/pdf") return { type: "document_url", documentUrl: dataUrl };
  return { type: "image_url", imageUrl: dataUrl };
}

function decodeBase64Payload(value) {
  let base64Data = String(value || "");
  const idx = base64Data.indexOf("base64,");
  if (idx >= 0) base64Data = base64Data.slice(idx + 7);
  return Buffer.from(base64Data, "base64");
}

function fileHash(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function parseJpegExifOrientation(segment) {
  if (!segment || segment.length < 14) return null;
  if (segment.subarray(0, 6).toString("latin1") !== "Exif\0\0") return null;
  const tiffOffset = 6;
  const endian = segment.subarray(tiffOffset, tiffOffset + 2).toString("latin1");
  const littleEndian = endian === "II";
  if (!littleEndian && endian !== "MM") return null;
  const readUInt16 = offset => littleEndian ? segment.readUInt16LE(offset) : segment.readUInt16BE(offset);
  const readUInt32 = offset => littleEndian ? segment.readUInt32LE(offset) : segment.readUInt32BE(offset);
  if (readUInt16(tiffOffset + 2) !== 42) return null;
  const ifdOffset = tiffOffset + readUInt32(tiffOffset + 4);
  if (ifdOffset + 2 > segment.length) return null;
  const entryCount = readUInt16(ifdOffset);
  for (let i = 0; i < entryCount; i += 1) {
    const entryOffset = ifdOffset + 2 + i * 12;
    if (entryOffset + 12 > segment.length) return null;
    const tag = readUInt16(entryOffset);
    if (tag === 0x0112) return readUInt16(entryOffset + 8);
  }
  return null;
}

function imageMetadataFromBuffer(buffer, mimeType) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) {
    return { width: null, height: null, orientation: null };
  }

  if (mimeType === "image/png" && buffer.subarray(12, 16).toString("latin1") === "IHDR") {
    return {
      width: buffer.readUInt32BE(16),
      height: buffer.readUInt32BE(20),
      orientation: null,
    };
  }

  if (mimeType === "image/jpeg" && buffer[0] === 0xff && buffer[1] === 0xd8) {
    let offset = 2;
    let orientation = null;
    while (offset + 4 < buffer.length) {
      if (buffer[offset] !== 0xff) {
        offset += 1;
        continue;
      }
      const marker = buffer[offset + 1];
      if (marker === 0xda || marker === 0xd9) break;
      const length = buffer.readUInt16BE(offset + 2);
      if (!length || offset + 2 + length > buffer.length) break;
      const payloadStart = offset + 4;
      const payloadEnd = offset + 2 + length;
      if (marker === 0xe1 && orientation == null) {
        orientation = parseJpegExifOrientation(buffer.subarray(payloadStart, payloadEnd));
      }
      if ((marker >= 0xc0 && marker <= 0xc3) || (marker >= 0xc5 && marker <= 0xc7) || (marker >= 0xc9 && marker <= 0xcb) || (marker >= 0xcd && marker <= 0xcf)) {
        return {
          width: buffer.readUInt16BE(payloadStart + 3),
          height: buffer.readUInt16BE(payloadStart + 1),
          orientation,
        };
      }
      offset += 2 + length;
    }
    return { width: null, height: null, orientation };
  }

  return { width: null, height: null, orientation: null };
}

function buildUploadDiagnostics(buffer, claimedMimeType, detectedMimeType, clientDiagnostics = null) {
  const serverImage = imageMetadataFromBuffer(buffer, detectedMimeType);
  return {
    client: clientDiagnostics || null,
    server: {
      byteCount: buffer?.length || 0,
      sha256: fileHash(buffer),
      mimeTypeClaimed: claimedMimeType || null,
      mimeTypeDetected: detectedMimeType || null,
      width: serverImage.width,
      height: serverImage.height,
      orientation: serverImage.orientation,
    },
  };
}

function uploadDiagnosticsSummary(diagnostics) {
  const server = diagnostics?.server || diagnostics;
  if (!server) return "unavailable";
  const dimensions = server.width && server.height ? `${server.width}x${server.height}` : "unknown_dims";
  const sha = server.sha256 ? String(server.sha256).slice(0, 16) : "no_sha";
  return `${server.mimeTypeDetected || server.mimeType || "unknown_mime"} ${dimensions} ${server.byteCount || 0}B sha256:${sha}`;
}

function logUploadDiagnostics(reqId, diagnostics) {
  console.log(`[${reqId}] Upload diagnostics server=${uploadDiagnosticsSummary(diagnostics)}`);
  if (diagnostics?.client) {
    const clientUpload = diagnostics.client.upload || diagnostics.client;
    console.log(`[${reqId}] Upload diagnostics client=${JSON.stringify({
      source: clientUpload.uploadSource || diagnostics.client.uploadSource || null,
      mimeType: clientUpload.mimeType || clientUpload.uploadedMimeType || null,
      byteCount: clientUpload.byteCount || clientUpload.uploadedByteCount || null,
      width: clientUpload.width || clientUpload.uploadedPixelWidth || null,
      height: clientUpload.height || clientUpload.uploadedPixelHeight || null,
      sha256: clientUpload.sha256 || clientUpload.uploadedSha256 || null,
      original: diagnostics.client.original || null,
    })}`);
  }
}

function getCachedParse(hash, namespace) {
  const key = `${namespace}:${hash}`;
  const cached = parseCache.get(key);
  if (!cached) return null;
  if (Date.now() - cached.createdAt > CACHE_TTL_MS) {
    parseCache.delete(key);
    return null;
  }
  return cached.value;
}

function setCachedParse(hash, namespace, value) {
  parseCache.set(`${namespace}:${hash}`, { createdAt: Date.now(), value });
  while (parseCache.size > MAX_PARSE_CACHE_ENTRIES) {
    const oldestKey = parseCache.keys().next().value;
    if (!oldestKey) break;
    parseCache.delete(oldestKey);
  }
}

function cleanupStagedReceiptJobs() {
  const cutoff = Date.now() - STAGED_RECEIPT_JOB_TTL_MS;
  for (const [requestId, job] of stagedReceiptJobs.entries()) {
    if (job.createdAt < cutoff) {
      stagedReceiptJobs.delete(requestId);
      if (job.hash) stagedReceiptHashIndex.delete(job.hash);
    }
  }
  while (stagedReceiptJobs.size > MAX_STAGED_RECEIPT_JOBS) {
    const oldestKey = stagedReceiptJobs.keys().next().value;
    if (!oldestKey) break;
    const job = stagedReceiptJobs.get(oldestKey);
    stagedReceiptJobs.delete(oldestKey);
    if (job?.hash) stagedReceiptHashIndex.delete(job.hash);
  }
}

function getQuickTotalFromFullReceipt(response) {
  if (!response) return null;
  return {
    merchant: response.merchant || null,
    receiptDate: response.receiptDate || null,
    currency: response.currency || "USD",
    subtotal: response.subtotal ?? null,
    tax: response.tax ?? null,
    tip: response.tip ?? null,
    fees: response.fees ?? null,
    grandTotal: response.grandTotal ?? null,
    confidence: response.confidence || "medium",
    totalLabel: response.grandTotal != null ? "grandTotal" : null,
    notes: response.notes || null,
  };
}

function parseAndValidateDocumentAnnotation(annotation, schema) {
  if (!annotation) {
    const error = new Error("No structured annotation returned by Mistral");
    error.code = "MALFORMED_ANNOTATION";
    throw error;
  }
  let raw;
  if (typeof annotation === "string") {
    try {
      raw = JSON.parse(annotation);
    } catch (err) {
      const error = new Error("Structured annotation JSON is malformed");
      error.code = "MALFORMED_ANNOTATION";
      error.cause = err;
      throw error;
    }
  } else if (typeof annotation === "object") {
    raw = annotation;
  } else {
    const error = new Error("Structured annotation has an unsupported type");
    error.code = "MALFORMED_ANNOTATION";
    throw error;
  }
  try {
    return schema.parse(raw);
  } catch (err) {
    const error = new Error("Structured annotation failed schema validation");
    error.code = "SCHEMA_VALIDATION_FAILED";
    error.cause = err;
    throw error;
  }
}

function redactSensitiveText(value) {
  return String(value || "")
    .replace(/\b(?:\d[ -]?){13,19}\b/g, "[REDACTED_CARD_OR_ACCOUNT]")
    .replace(/\b(account|acct|card)\s*(?:number|no|#)?\s*[:#]?\s*[A-Z0-9* -]{6,}/gi, "$1 [REDACTED]");
}

// ============================================================
// INTERNAL ANALYTICS - FILE-BACKED, NON-BLOCKING
// ============================================================

const BLOCKED_ANALYTICS_KEYS = [
  "imagebase64",
  "filebase64",
  "base64",
  "ocrtext",
  "rawocr",
  "rawtext",
  "receipttext",
  "statementtext",
  "transactiondescription",
  "description",
  "sourcetext",
  "apikey",
  "api_key",
  "authorization",
  "bearer",
  "token",
  "password",
  "secret",
  "mistral",
  "openai",
];

const ANALYTICS_FAILURE_REASONS = {
  receipt: new Set([
    "blurry_image",
    "invalid_document",
    "valid_receipt_incorrectly_rejected",
    "unsupported_file_type",
    "pdf_extraction_failed",
    "ocr_timeout",
    "ocr_provider_error",
    "parse_failed",
    "missing_total",
    "subtotal_selected_as_grand_total",
    "reconciliation_failed",
    "backend_timeout",
    "unknown_error",
  ]),
  statement: new Set([
    "blurry_statement",
    "invalid_statement",
    "valid_statement_incorrectly_rejected",
    "screenshot_classification_failed",
    "pdf_extraction_failed",
    "password_protected_pdf",
    "transaction_extraction_failed",
    "parse_failed",
    "backend_timeout",
    "unknown_error",
  ]),
};

function safeString(value, maxLength = 300) {
  return redactSensitiveText(value)
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [REDACTED]")
    .replace(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, "[REDACTED_EMAIL]")
    .replace(/\+?\d[\d .()\-]{8,}\d/g, "[REDACTED_PHONE_OR_ACCOUNT]")
    .slice(0, maxLength);
}

function isBlockedAnalyticsKey(key) {
  const normalized = String(key || "").replace(/[^a-zA-Z0-9_]/g, "").toLowerCase();
  return BLOCKED_ANALYTICS_KEYS.some(blocked => normalized.includes(blocked));
}

function sanitizeAnalyticsValue(value, depth = 0) {
  if (depth > 4) return "[MAX_DEPTH]";
  if (value == null) return value;
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "string") return safeString(value);
  if (Array.isArray(value)) {
    return value.slice(0, 25).map(item => sanitizeAnalyticsValue(item, depth + 1));
  }
  if (typeof value === "object") {
    const output = {};
    for (const [key, raw] of Object.entries(value).slice(0, 80)) {
      if (isBlockedAnalyticsKey(key)) {
        output[key] = "[REDACTED]";
      } else {
        output[key] = sanitizeAnalyticsValue(raw, depth + 1);
      }
    }
    return output;
  }
  return String(value);
}

function sanitizeAnalyticsProperties(properties = {}) {
  const sanitized = sanitizeAnalyticsValue(properties);
  const encoded = JSON.stringify(sanitized);
  if (Buffer.byteLength(encoded, "utf8") <= ANALYTICS_MAX_EVENT_BYTES) return sanitized;
  return {
    truncated: true,
    original_size_bytes: Buffer.byteLength(encoded, "utf8"),
  };
}

function normalizeAnalyticsFailureReason(kind, reason) {
  const normalized = String(reason || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  const allowed = ANALYTICS_FAILURE_REASONS[kind];
  if (allowed?.has(normalized)) return normalized;
  if (normalized.includes("timeout")) return "backend_timeout";
  if (normalized.includes("unsupported")) return "unsupported_file_type";
  if (normalized.includes("pdf")) return "pdf_extraction_failed";
  if (normalized.includes("ocr")) return kind === "receipt" ? "ocr_provider_error" : "transaction_extraction_failed";
  if (normalized.includes("parse") || normalized.includes("schema")) return "parse_failed";
  if (normalized.includes("statement")) return kind === "statement" ? "invalid_statement" : "invalid_document";
  return "unknown_error";
}

function requestIdFrom(req) {
  const provided =
    req.headers["x-request-id"] ||
    req.headers["x-dutchie-request-id"] ||
    req.body?.request_id ||
    req.body?.requestId;
  if (typeof provided === "string" && /^[A-Za-z0-9_.:-]{6,96}$/.test(provided)) {
    return provided;
  }
  return `req_${Date.now().toString(36)}_${crypto.randomBytes(4).toString("hex")}`;
}

function analyticsContextFromRequest(req, reqId) {
  return {
    user_id: req.body?.user_id || req.body?.userId || req.headers["x-user-id"] || null,
    anonymous_id: req.body?.anonymous_id || req.body?.anonymousId || req.headers["x-anonymous-id"] || null,
    session_id: req.body?.session_id || req.body?.sessionId || req.headers["x-session-id"] || "unknown",
    request_id: reqId,
    platform: req.body?.platform || req.headers["x-platform"] || "ios",
    app_version: req.body?.app_version || req.body?.appVersion || req.headers["x-app-version"] || null,
  };
}

function compactAnalyticsEvent(event) {
  return {
    id: event.id || `evt_${Date.now().toString(36)}_${crypto.randomBytes(6).toString("hex")}`,
    user_id: event.user_id ?? null,
    anonymous_id: event.anonymous_id ?? null,
    session_id: event.session_id || "unknown",
    request_id: event.request_id ?? null,
    event_name: event.event_name,
    platform: event.platform || "backend",
    app_version: event.app_version ?? null,
    properties: sanitizeAnalyticsProperties(event.properties || {}),
    created_at: event.created_at || new Date().toISOString(),
  };
}

function trackAnalyticsEvent(event) {
  if (!event?.event_name) return;
  try {
    const compacted = compactAnalyticsEvent(event);
    fs.promises
      .appendFile(ANALYTICS_EVENTS_FILE, JSON.stringify(compacted) + "\n", "utf8")
      .catch(error => {
        console.warn("[analytics] write failed:", error?.message || error);
      });
  } catch (error) {
    console.warn("[analytics] event dropped:", error?.message || error);
  }
}

async function readAnalyticsEvents({ limit = 5000, from, to } = {}) {
  try {
    const raw = await fs.promises.readFile(ANALYTICS_EVENTS_FILE, "utf8");
    const fromTime = from ? Date.parse(from) : null;
    const toTime = to ? Date.parse(to) : null;
    const rows = raw
      .split(/\n+/)
      .filter(Boolean)
      .map(line => {
        try { return JSON.parse(line); } catch { return null; }
      })
      .filter(Boolean)
      .filter(event => {
        const created = Date.parse(event.created_at);
        if (fromTime && created < fromTime) return false;
        if (toTime && created > toTime) return false;
        return true;
      });
    return rows.slice(-Math.max(1, Math.min(Number(limit) || 5000, 20000)));
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

async function cleanupAnalyticsEvents() {
  if (!Number.isFinite(ANALYTICS_RETENTION_DAYS) || ANALYTICS_RETENTION_DAYS <= 0) return;
  try {
    const cutoff = Date.now() - ANALYTICS_RETENTION_DAYS * 24 * 60 * 60 * 1000;
    const events = await readAnalyticsEvents({ limit: 200000 });
    const retained = events.filter(event => Date.parse(event.created_at) >= cutoff);
    if (retained.length !== events.length) {
      await fs.promises.writeFile(
        ANALYTICS_EVENTS_FILE,
        retained.map(event => JSON.stringify(event)).join("\n") + (retained.length ? "\n" : ""),
        "utf8"
      );
      console.log(`[analytics] Retention cleanup kept ${retained.length}/${events.length} events`);
    }
  } catch (error) {
    console.warn("[analytics] retention cleanup failed:", error?.message || error);
  }
}

function summarizeAnalytics(events) {
  const counts = {};
  const users = new Set();
  const sessions = new Set();
  const errors = {};
  const durations = [];
  for (const event of events) {
    counts[event.event_name] = (counts[event.event_name] || 0) + 1;
    if (event.user_id) users.add(event.user_id);
    if (event.session_id) sessions.add(event.session_id);
    const reason = event.properties?.failure_reason || event.properties?.error_code;
    if (reason) errors[reason] = (errors[reason] || 0) + 1;
    const ms = event.properties?.processing_time_ms ?? event.properties?.total_ms;
    if (Number.isFinite(ms)) durations.push(ms);
  }
  durations.sort((a, b) => a - b);
  const percentile = p => durations.length ? durations[Math.min(durations.length - 1, Math.floor(durations.length * p))] : 0;
  return {
    total_events: events.length,
    unique_users: users.size,
    unique_sessions: sessions.size,
    counts,
    receipt_success_rate: rate(counts.receipt_parse_completed, counts.receipt_upload_started),
    statement_success_rate: rate(counts.statement_parse_completed, counts.statement_upload_started),
    ocr_success_rate: rate(counts.receipt_ocr_completed, (counts.receipt_ocr_started || 0) + (counts.statement_extraction_started || 0)),
    most_common_errors: Object.entries(errors)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 12)
      .map(([reason, count]) => ({ reason, count })),
    response_time_ms: {
      average: durations.length ? Math.round(durations.reduce((sum, ms) => sum + ms, 0) / durations.length) : 0,
      p95: percentile(0.95),
      p99: percentile(0.99),
    },
  };
}

function rate(success = 0, total = 0) {
  return total > 0 ? Number(((success / total) * 100).toFixed(1)) : 0;
}

function hashIdentifier(value) {
  if (!value) return null;
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 24);
}

function classifyFinancialDocument({ ocrText, uploadIntent, sourceType, mimeType }) {
  const text = String(ocrText || "").toLowerCase();
  const hasReceiptSignals = /\b(receipt|subtotal|sales tax|tax|tip|gratuity|total due|balance due|items sold|cashier|merchant)\b/.test(text);
  const hasStatementSignals = /\b(statement period|opening balance|closing balance|account number|account summary|statement date|new balance)\b/.test(text);
  const hasActivitySignals = /\b(account activity|transaction history|pending|posted|available balance|current balance|deposit|withdrawal|transfer|merchant name|transaction description|payments and other credits|purchase)\b/.test(text);
  const hasCardSignals = /\b(credit card|card activity|minimum payment|payment due|statement balance|available credit|cash back|purchase apr|credit line|cardmember|freedom)\b/.test(text);
  const hasTransactionRows = (text.match(/\$?[-+]?\d{1,3}(?:,\d{3})*\.\d{2}/g) || []).length >= 2;
  const isPdf = sourceType === "pdf" || mimeType === "application/pdf";

  if (uploadIntent === "scan_statement" && hasCardSignals && hasTransactionRows) {
    return { documentType: "credit_card_activity_screenshot", confidence: 0.94, reason: "Credit-card statement/activity language and transaction rows were detected." };
  }
  if (uploadIntent === "scan_statement" && (hasStatementSignals || isPdf) && hasTransactionRows) {
    return { documentType: "bank_statement", confidence: 0.93, reason: "Statement-like document and transaction rows were detected." };
  }
  if (uploadIntent === "scan_statement" && hasActivitySignals && hasTransactionRows) {
    return { documentType: "account_activity_screenshot", confidence: 0.9, reason: "Account activity labels and visible transaction rows were detected." };
  }
  if (hasStatementSignals && hasTransactionRows) return { documentType: "bank_statement", confidence: 0.95, reason: "Statement period, balances, or account summary signals were detected with transaction amounts." };
  if (hasCardSignals && hasTransactionRows) return { documentType: "credit_card_activity_screenshot", confidence: 0.92, reason: "Credit-card activity language and transaction amounts were detected." };
  if (hasActivitySignals && hasTransactionRows) return { documentType: "account_activity_screenshot", confidence: 0.9, reason: "Account activity language and visible transaction rows were detected." };
  if (hasReceiptSignals && uploadIntent !== "scan_statement") return { documentType: "receipt", confidence: 0.86, reason: "Receipt-style totals and purchased-item signals were detected." };
  if (hasTransactionRows && uploadIntent === "scan_statement") return { documentType: isPdf ? "bank_statement" : "account_activity_screenshot", confidence: 0.72, reason: "Visible transaction-like rows were detected, but document labels are limited." };
  if (hasReceiptSignals && uploadIntent === "scan_statement") return { documentType: "ambiguous", confidence: 0.62, reason: "The upload was intended as a statement, but receipt-style fields were detected." };
  return { documentType: "unsupported", confidence: 0.25, reason: "No supported receipt, statement, or account-activity evidence was detected." };
}

function classifyReceiptUpload({ ocrText, parsed }) {
  const text = String(ocrText || "").toLowerCase();
  const words = text.match(/[a-z0-9$.,#-]+/g) || [];
  const amountCount = (text.match(/\$?[-+]?\d{1,3}(?:,\d{3})*\.\d{2}/g) || []).length;
  const receiptSignals = [
    /\breceipt\b/,
    /\bsubtotal\b/,
    /\bsales\s+tax\b/,
    /\btax\b/,
    /\btip\b/,
    /\bgratuity\b/,
    /\btotal\s+(?:due|paid|amount|sale|order)\b/,
    /\bbalance\s+due\b/,
    /\bitems?\s+sold\b/,
    /\bcashier\b/,
    /\btender\b/,
    /\bchange\b/,
    /\border\s*(?:#|number|no\.?|id)\b/,
    /\binvoice\b/,
    /\bmerchant\s+copy\b/,
    /\b(?:visa|mastercard|amex|discover)\b/,
    /\bauth\s*(?:code|#)\b/,
  ];
  const statementSignals = /\b(statement period|opening balance|closing balance|account number|account summary|statement date|new balance|minimum payment|payment due|available credit|transaction history|account activity)\b/.test(text);
  const receiptSignalCount = receiptSignals.reduce((count, regex) => count + (regex.test(text) ? 1 : 0), 0);
  const itemCount = Array.isArray(parsed?.items) ? parsed.items.length : 0;
  const hasVisibleTotal = parsed?.grandTotal != null || parsed?.subtotal != null || /\b(?:grand\s+total|total|amount\s+due|balance\s+due)\b/.test(text);
  const terminalAmountLineCount = String(ocrText || "")
    .split(/\r?\n/)
    .map(cleanOcrLine)
    .filter(line => lastAmountNearLineEnd(line) && !summaryRoleForLine(line) && !isReceiptMetadataLine(line))
    .length;

  if (statementSignals) {
    return {
      ok: false,
      code: "NOT_A_RECEIPT",
      confidence: 0.2,
      reason: "Statement or account-activity text was detected, not a receipt.",
    };
  }

  if (receiptSignalCount >= 1 && amountCount >= 1 && itemCount >= 1) {
    return { ok: true, confidence: Math.min(0.98, 0.75 + receiptSignalCount * 0.04), reason: "Receipt text, prices, and purchased items were detected." };
  }

  if (receiptSignalCount >= 2 && amountCount >= 1 && hasVisibleTotal) {
    return { ok: true, confidence: 0.84, reason: "Receipt totals and receipt-style labels were detected." };
  }

  if (itemCount >= 2 && amountCount >= 2 && hasVisibleTotal && receiptSignalCount >= 1) {
    return { ok: true, confidence: 0.82, reason: "Receipt-like item rows and totals were detected." };
  }

  if (itemCount >= 2 && terminalAmountLineCount >= 2 && amountCount >= 3) {
    return { ok: true, confidence: 0.78, reason: "Multiple purchased item-price rows were detected in receipt-like OCR text." };
  }

  if (terminalAmountLineCount >= 3 && amountCount >= 4 && hasVisibleTotal) {
    return { ok: true, confidence: 0.74, reason: "Receipt-like item-price rows and a visible total were detected without relying on a fixed template." };
  }

  if (hasVisibleTotal && amountCount >= 2 && words.length >= 8 && !statementSignals) {
    return {
      ok: true,
      confidence: 0.62,
      reason: "Weak but plausible receipt evidence was detected; parse as review-required instead of rejecting the upload.",
    };
  }

  if (words.length < 8 || (receiptSignalCount === 0 && terminalAmountLineCount < 3)) {
    return {
      ok: false,
      code: "NOT_A_RECEIPT",
      confidence: 0.18,
      reason: "No reliable receipt text was detected. A photo of food or an object should not be parsed as a receipt.",
    };
  }

  return {
    ok: false,
    code: "NOT_A_RECEIPT",
    confidence: 0.45,
    reason: "The upload did not contain enough receipt evidence to safely parse financial values.",
  };
}

const BANK_DOCUMENT_PROMPT = `You extract transaction rows from bank statements, credit-card statements, and banking activity screenshots.

Product goal:
- Treat statements like receipt itemization, but each extracted item is a transaction row.
- For PDFs, inspect all pages and find the pages or sections dedicated to transactions/account activity/purchases/payments.
- For screenshots, use the visible transaction page only.
- The document may not show a subtotal, statement total, or balance. That is normal. Do not require one.

Extract only transaction rows visibly supported by the document.
Ignore non-transaction content such as account messages, ads, summaries, year-to-date fee boxes, payment coupons, instructions, and headers.
Never invent a transaction, balance, account name, account number, date, status, or statement period.
Return null when a non-transaction field is absent or unclear.
If no transaction rows are visible, return an empty transactions array and explain in warnings.
If a screenshot is cropped or rows appear cut off, set partialDocument = true.

Transaction rules:
- description is the merchant/payee/transaction description exactly enough for a user to recognize it.
- amount is the visible transaction amount as a positive number.
- direction = debit for purchases, withdrawals, fees, charges, card purchases, or money spent.
- direction = credit for payments, deposits, refunds, credits, rewards, or money received.
- On credit-card statements, PURCHASE sections are debit/spending even if printed as positive amounts.
- On credit-card statements, PAYMENTS AND OTHER CREDITS sections are credit even if printed with a minus sign.
- status = pending only when visibly labeled pending; otherwise posted or unknown.
- Preserve the original visible transaction row in sourceText.

Privacy:
Do not return a full bank-account number or full credit-card number. Only return last four digits when visibly present.

Return JSON only.`;

function parseBankAmountText(value) {
  const raw = String(value || "").trim();
  if (!raw) return null;
  const isNegative = /^\s*[-(]/.test(raw) || /\)\s*$/.test(raw);
  const cleaned = raw.replace(/[$,()\s]/g, "").replace(/^\+/, "");
  const amount = Number(cleaned);
  if (!Number.isFinite(amount) || Math.abs(amount) < 0.01) return null;
  return { amount: round2(Math.abs(amount)), isNegative };
}

const MONTH_INDEX = {
  jan: 1,
  january: 1,
  feb: 2,
  february: 2,
  mar: 3,
  march: 3,
  apr: 4,
  april: 4,
  may: 5,
  jun: 6,
  june: 6,
  jul: 7,
  july: 7,
  aug: 8,
  august: 8,
  sep: 9,
  sept: 9,
  september: 9,
  oct: 10,
  october: 10,
  nov: 11,
  november: 11,
  dec: 12,
  december: 12,
};

function normalizeBankDate(value) {
  const raw = String(value || "").trim();
  const monthMatch = raw.match(/^([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})$/);
  if (monthMatch) {
    const month = MONTH_INDEX[monthMatch[1].toLowerCase()];
    if (!month) return raw;
    return `${String(month).padStart(2, "0")}/${String(monthMatch[2]).padStart(2, "0")}/${monthMatch[3]}`;
  }
  return raw;
}

function inferBankDirection({ description, parsedAmount, section, documentType }) {
  const text = String(description || "").toLowerCase();
  if (/\b(payment|deposit|refund|credit|cash back|reversal)\b/.test(text) && /\bfrom\b/.test(text)) return "credit";
  if (/\bpayment[- ]thank you\b|\bthank you[- ]mobile\b/.test(text)) return "credit";
  if (/\bpayment\s+to\b|\bzelle payment to\b|\bwithdrawal\b|\bpurchase\b|\bdebit\b|\bfee\b/.test(text)) return "debit";
  if (/\bzelle payment from\b|\bdeposit\b|\brefund\b|\bcredit\b/.test(text)) return "credit";

  if (section === "debit" || section === "credit") return section;

  if (documentType === "credit_card_activity_screenshot") {
    return parsedAmount?.isNegative ? "credit" : "debit";
  }

  if (documentType === "account_activity_screenshot" || documentType === "bank_statement") {
    return parsedAmount?.isNegative ? "debit" : "credit";
  }

  return parsedAmount?.isNegative ? "debit" : "unknown";
}

function isBankUiOrSummaryLine(line) {
  const lower = String(line || "").toLowerCase().trim();
  if (!lower) return true;
  if (/^(done|search|search or filter|transactions?|pending(?:\s*\(\d+\))?|downloaded documents)$/.test(lower)) return true;
  if (/^(see your chase offers|chase offers|activity since|account activity|\d+\s+of\s+\d+)$/.test(lower)) return true;
  if (/^(merchant name or transaction description|\$ amount|amount|purchase|payments? and other credits|credits?)$/.test(lower)) return true;
  if (/^(total fees charged|total interest charged|year-to-date|this statement is a facsimile|page \d+ of \d+)/i.test(lower)) return true;
  return false;
}

function isStandaloneDateLine(line) {
  return /^(?:\d{1,2}\/\d{1,2}(?:\/\d{2,4})?|[A-Za-z]+\s+\d{1,2},\s*\d{4})$/.test(String(line || "").trim());
}

function isStandaloneAmountLine(line) {
  return /^[-+]?\$?\(?\d{1,3}(?:,\d{3})*\.\d{2}\)?$/.test(String(line || "").trim());
}

function extractBankTransactionsFromOcrText(ocrText, documentType) {
  const transactions = [];
  let section = "unknown";
  const lines = String(ocrText || "")
    .split(/\r?\n/)
    .map(line => line.replace(/\|/g, " ").replace(/\s+/g, " ").trim())
    .filter(Boolean);

  for (const line of lines) {
    const upper = line.toUpperCase();
    const startsWithDate = /^\d{1,2}\/\d{1,2}/.test(line);
    if (!startsWithDate && /PAYMENTS?\s+AND\s+OTHER\s+CREDITS|CREDITS?/.test(upper) && !/PAYMENT\s+DUE/.test(upper)) {
      section = "credit";
      continue;
    }
    if (!startsWithDate && /PURCHASES?|TRANSACTIONS?|ACCOUNT\s+ACTIVITY|DEBITS?|WITHDRAWALS?/.test(upper)) {
      section = /ACCOUNT\s+ACTIVITY|TRANSACTIONS?/.test(upper) ? "unknown" : "debit";
      continue;
    }

    const match = line.match(/^(\d{1,2}\/\d{1,2}(?:\/\d{2,4})?)\s+(.+?)\s+([-+]?\$?\(?\d{1,3}(?:,\d{3})*\.\d{2}\)?)$/);
    if (!match) continue;

    const [, transactionDate, rawDescription, rawAmount] = match;
    const parsedAmount = parseBankAmountText(rawAmount);
    if (!parsedAmount) continue;

    const description = rawDescription
      .replace(/^&\s*/, "")
      .replace(/\s{2,}/g, " ")
      .trim();
    if (!description || /merchant name|transaction description|amount/i.test(description)) continue;

    const direction = inferBankDirection({ description, parsedAmount, section, documentType });

    transactions.push({
      transactionDate,
      postedDate: null,
      description: redactSensitiveText(description),
      amount: parsedAmount.amount,
      direction,
      status: "posted",
      balanceAfterTransaction: null,
      sourceText: redactSensitiveText(line),
      confidence: 0.74,
    });
  }

  return transactions;
}

function extractMobileBankingTransactionsFromOcrText(ocrText, documentType) {
  const transactions = [];
  const lines = String(ocrText || "")
    .split(/\r?\n/)
    .map(line => line.replace(/\|/g, " ").replace(/\s+/g, " ").trim())
    .filter(Boolean)
    .filter(line => !isBankUiOrSummaryLine(line));

  let currentDate = null;
  let descriptionParts = [];
  let pendingSlashDate = null;
  let pendingAmounts = [];

  function resetPending() {
    descriptionParts = [];
    pendingSlashDate = null;
    pendingAmounts = [];
  }

  function commitPending() {
    if (descriptionParts.length === 0 || pendingAmounts.length === 0) return false;
    const rawAmount = pendingAmounts[pendingAmounts.length - 1];
    const parsedAmount = parseBankAmountText(rawAmount);
    if (!parsedAmount) return false;
    const description = descriptionParts.join(" ").replace(/\s+/g, " ").trim();
    if (!description || /^(available|current)?\s*balance$/i.test(description)) return false;
    const date = pendingSlashDate || currentDate;
    if (!date) return false;

    transactions.push({
      transactionDate: normalizeBankDate(date),
      postedDate: null,
      description: redactSensitiveText(description),
      amount: parsedAmount.amount,
      direction: inferBankDirection({ description, parsedAmount, section: "unknown", documentType }),
      status: /pending/i.test(description) ? "pending" : "posted",
      balanceAfterTransaction: pendingAmounts.length > 1 ? parseBankAmountText(pendingAmounts[0])?.amount ?? null : null,
      sourceText: redactSensitiveText([...descriptionParts, ...pendingAmounts].join(" ")),
      confidence: 0.78,
    });
    resetPending();
    return true;
  }

  for (const line of lines) {
    if (isStandaloneDateLine(line)) {
      if (/^[A-Za-z]+/.test(line)) {
        commitPending();
        currentDate = line;
        resetPending();
      } else {
        pendingSlashDate = line;
      }
      continue;
    }

    if (isStandaloneAmountLine(line)) {
      pendingAmounts.push(line);
      const parsedAmount = parseBankAmountText(line);
      const looksLikeMobileBalanceThenAmount =
        currentDate && !pendingSlashDate && pendingAmounts.length === 1 && parsedAmount && !parsedAmount.isNegative;
      if (descriptionParts.length > 0 && !looksLikeMobileBalanceThenAmount) {
        commitPending();
      }
      continue;
    }

    const inlineMatch = line.match(/^(.+?)\s+(\d{1,2}\/\d{1,2}(?:\/\d{2,4})?)\s+([-+]?\$?\(?\d{1,3}(?:,\d{3})*\.\d{2}\)?)$/);
    if (inlineMatch) {
      commitPending();
      const [, rawDescription, transactionDate, rawAmount] = inlineMatch;
      const parsedAmount = parseBankAmountText(rawAmount);
      if (parsedAmount) {
        const description = rawDescription.trim();
        transactions.push({
          transactionDate,
          postedDate: null,
          description: redactSensitiveText(description),
          amount: parsedAmount.amount,
          direction: inferBankDirection({ description, parsedAmount, section: "unknown", documentType }),
          status: "posted",
          balanceAfterTransaction: null,
          sourceText: redactSensitiveText(line),
          confidence: 0.78,
        });
      }
      resetPending();
      continue;
    }

    if (descriptionParts.length > 0 && pendingAmounts.length > 0) {
      commitPending();
    }
    descriptionParts.push(line);
  }

  commitPending();
  return transactions;
}

function extractFallbackBankTransactionsFromOcrText(ocrText, documentType) {
  return mergeBankTransactions(
    extractBankTransactionsFromOcrText(ocrText, documentType),
    extractMobileBankingTransactionsFromOcrText(ocrText, documentType)
  );
}

function mergeBankTransactions(primaryTransactions, fallbackTransactions) {
  const merged = [...(primaryTransactions || [])];
  const seen = new Set(merged.map(tx => [tx.transactionDate || "", tx.postedDate || "", tx.description || "", Number(tx.amount || 0).toFixed(2)].join("|")));

  for (const tx of fallbackTransactions || []) {
    const key = [tx.transactionDate || "", tx.postedDate || "", tx.description || "", Number(tx.amount || 0).toFixed(2)].join("|");
    if (!seen.has(key)) {
      merged.push(tx);
      seen.add(key);
    }
  }
  return merged;
}

function normalizeBankDocument(doc, classifiedType) {
  const sanitizedLast4 = doc.accountLast4 ? String(doc.accountLast4).replace(/\D/g, "").slice(-4) : null;
  return {
    documentType: ["bank_statement", "account_activity_screenshot", "credit_card_activity_screenshot"].includes(classifiedType) ? classifiedType : doc.documentType,
    institutionName: doc.institutionName || null,
    accountName: doc.accountName || null,
    accountLast4: sanitizedLast4,
    currency: doc.currency || "USD",
    statementPeriod: {
      startDate: doc.statementPeriod?.startDate || null,
      endDate: doc.statementPeriod?.endDate || null,
    },
    balances: {
      openingBalance: toNumber(doc.balances?.openingBalance),
      closingBalance: toNumber(doc.balances?.closingBalance),
      availableBalance: toNumber(doc.balances?.availableBalance),
      currentBalance: toNumber(doc.balances?.currentBalance),
    },
    transactions: (doc.transactions || []).map(tx => ({
      transactionDate: tx.transactionDate || null,
      postedDate: tx.postedDate || null,
      description: redactSensitiveText(tx.description),
      amount: round2(Math.abs(Number(tx.amount || 0))),
      direction: tx.direction || "unknown",
      status: tx.status || "unknown",
      balanceAfterTransaction: toNumber(tx.balanceAfterTransaction),
      sourceText: redactSensitiveText(tx.sourceText || tx.description || ""),
      confidence: tx.confidence ?? null,
    })).filter(tx => tx.description && tx.amount > 0),
    partialDocument: !!doc.partialDocument,
    warnings: (doc.warnings || []).map(redactSensitiveText),
  };
}

function reconcileBankDocument(bankDocument) {
  const currency = bankDocument.currency || "USD";
  const posted = bankDocument.transactions.filter(tx => tx.status !== "pending");
  const pending = bankDocument.transactions.filter(tx => tx.status === "pending");
  const postedDebits = posted.filter(tx => tx.direction === "debit").reduce((sum, tx) => sum + (toMinorUnits(tx.amount, currency) || 0), 0);
  const postedCredits = posted.filter(tx => tx.direction === "credit").reduce((sum, tx) => sum + (toMinorUnits(tx.amount, currency) || 0), 0);
  const pendingTotal = pending.reduce((sum, tx) => sum + (toMinorUnits(tx.amount, currency) || 0), 0);
  const opening = toMinorUnits(bankDocument.balances.openingBalance, currency);
  const closing = toMinorUnits(bankDocument.balances.closingBalance, currency);
  if (opening != null && closing != null) {
    const calculatedClosing = opening + postedCredits - postedDebits;
    const verified = moneyEqualWithinTolerance(calculatedClosing, closing);
    return {
      status: verified ? "verified" : "ambiguous",
      reason: verified ? "Opening balance plus posted credits minus posted debits matches the closing balance." : "Visible balances do not reconcile with visible posted transactions; the document may be partial or OCR may need review.",
      visiblePostedDebitTotal: fromMinorUnits(postedDebits, currency),
      visiblePostedCreditTotal: fromMinorUnits(postedCredits, currency),
      pendingTransactionTotal: fromMinorUnits(pendingTotal, currency),
      calculatedClosingBalance: fromMinorUnits(calculatedClosing, currency),
      totalGap: fromMinorUnits(Math.abs(calculatedClosing - closing), currency),
    };
  }
  if (bankDocument.partialDocument) return { status: "partially_verified", reason: "This appears to be a partial screenshot. Only visible transactions were extracted.", visiblePostedDebitTotal: fromMinorUnits(postedDebits, currency), visiblePostedCreditTotal: fromMinorUnits(postedCredits, currency), pendingTransactionTotal: fromMinorUnits(pendingTotal, currency) };
  return { status: "not_applicable", reason: "No opening balance, closing balance, or running balance is visible.", visiblePostedDebitTotal: fromMinorUnits(postedDebits, currency), visiblePostedCreditTotal: fromMinorUnits(postedCredits, currency), pendingTransactionTotal: fromMinorUnits(pendingTotal, currency) };
}

// ============================================================
// MISTRAL EXTRACTION PROMPT
// ============================================================

const EXTRACTION_PROMPT = `Read this receipt for bill splitting.

Extract every purchased merchandise/product/service row exactly once.

PURCHASED ITEMS:
- itemName is the purchased item as visibly printed.
- itemValue is the FINAL effective amount that this item contributes to the receipt total.
- Do not put subtotal, tax, tip, gratuity, fees, payment, change, total, savings summaries, or discount-only rows in items.
- Keep duplicate purchased rows separate when the receipt shows separate purchases.

DISCOUNTS:
- Apply an item-specific discount exactly once.
- If a separate discount line is clearly linked to an item and must be deducted from its printed price, reflect that deduction in itemValue.
- If the printed item price already reflects the discount, keep that price unchanged.
- Never subtract the same discount twice.
- discountLabel is display metadata only. It never changes itemValue downstream.
- Never output a discount as its own purchased item.
- If an order-wide discount is visible, allocate it proportionally across purchased itemValue values in cents so the final item values include it. Never emit a discount row or fee.

TAX:
- Put only actual charged tax in tax.
- Combine multiple actual tax lines into the tax total when necessary.
- Tax must never appear in items or additionalFees.
- Return 0 when no tax was charged.

TIP:
- Put only the final tip/gratuity actually charged in tip.
- Ignore suggested tip percentages/options and blank tip lines.
- Tip must never appear in items or additionalFees.
- Return 0 when no tip was charged.

ADDITIONAL FEES:
- additionalFees contains only actual positive non-item charges that are NOT tax and NOT tip.
- Examples: service fee, bag fee, delivery fee, convenience fee, surcharge, deposit, recycling fee.
- Preserve each distinct fee separately.

TOTAL:
- total is the final grand total / amount due / amount actually charged.
- Never use subtotal as total.
- Preserve a visibly printed total even when extracted rows do not reconcile; downstream validation will request review.

RECONCILIATION:
The intended accounting relationship is:

SUM(items.itemValue)
+ tax
+ tip
+ SUM(additionalFees.feeValue)
= total

Use receipt math to resolve ambiguous OCR readings only when the image visually supports that interpretation.
Never invent an item, fee, tax, tip, or price merely to force the equation to balance.
Return structured JSON only.`;

const QUICK_TOTAL_PROMPT = `You extract only receipt summary totals with extremely high financial accuracy.

Goal: return the fastest reliable merchant/date/totals summary. Do not itemize products.

Rules:
1. Never invent values not visible on the receipt.
2. Pick the final amount owed/charged using this priority:
   BALANCE DUE, GRAND TOTAL, TOTAL, AMOUNT DUE, TOTAL DUE.
3. Do not confuse SUBTOTAL, NET SALES, NET TOTAL, TAX, SAVINGS, CHANGE, CASH TENDERED, CARD AUTH, or payment processor metadata with grandTotal.
4. If multiple totals are visible, choose the amount closest to the final payable/charged amount and put the printed label in totalLabel.
5. Use null for uncertain fields, and lower confidence when the image is blurry or totals conflict.
6. Return JSON only.`;

function compactAppleOcrText(appleOcrText, maxChars = APPLE_OCR_CONTEXT_MAX_CHARS) {
  const rawLines = String(appleOcrText || "")
    .split(/\r?\n/)
    .map(line => line.replace(/\s+/g, " ").trim())
    .filter(Boolean);
  if (!rawLines.length) return "";

  const deduped = [];
  const seen = new Set();
  for (const line of rawLines) {
    const key = line.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(line);
  }

  const joined = deduped.join("\n");
  if (joined.length <= maxChars) return joined;

  const receiptLike = [];
  const context = [];
  for (const line of deduped) {
    if (
      amountMatchesInText(line).length ||
      summaryRoleForLine(line) ||
      /\b(?:receipt|cashier|server|order|invoice|merchant|visa|mastercard|amex|discover|auth|approval|subtotal|tax|total|balance|amount due|change|tip|fee|discount|coupon|savings?)\b/i.test(line)
    ) {
      receiptLike.push(line);
    } else if (context.length < 12) {
      context.push(line);
    }
  }

  const prioritized = [...context.slice(0, 6), ...receiptLike, ...context.slice(6)];
  let output = "";
  for (const line of prioritized) {
    const next = output ? `${output}\n${line}` : line;
    if (next.length > maxChars) break;
    output = next;
  }
  return output || joined.slice(0, maxChars);
}

function compactLocalParseResult(localParseResult) {
  if (!localParseResult || typeof localParseResult !== "object") return "";
  const lines = [];
  const merchant = safeString(localParseResult.merchant || "").slice(0, 120);
  if (merchant) lines.push(`merchant: ${merchant}`);
  if (localParseResult.receiptDate || localParseResult.date) {
    lines.push(`date: ${safeString(localParseResult.receiptDate || localParseResult.date).slice(0, 60)}`);
  }

  const items = Array.isArray(localParseResult.items) ? localParseResult.items : [];
  if (items.length) {
    lines.push(`items (${items.length}${items.length > LOCAL_PARSE_CONTEXT_MAX_ITEMS ? `, showing ${LOCAL_PARSE_CONTEXT_MAX_ITEMS}` : ""}):`);
    for (const item of items.slice(0, LOCAL_PARSE_CONTEXT_MAX_ITEMS)) {
      const name = safeString(item?.name || item?.rawName || "").slice(0, 100);
      const amount = item?.amount ?? item?.printedAmount ?? null;
      const qty = item?.qty ?? item?.quantity ?? null;
      const unitPrice = item?.unitPrice ?? null;
      const weightLbs = item?.weightLbs ?? null;
      const confidence = item?.confidence ?? item?.confidenceLabel ?? null;
      if (!name && amount == null) continue;
      lines.push(`- ${name || "unnamed"} = ${amount}${qty != null ? ` qty=${qty}` : ""}${unitPrice != null ? ` unit=${unitPrice}` : ""}${weightLbs != null ? ` weightLbs=${weightLbs}` : ""}${confidence ? ` confidence=${safeString(confidence).slice(0, 40)}` : ""}`);
    }
  }

  const summaryFields = [
    ["subtotal", localParseResult.subtotal],
    ["tax", localParseResult.tax],
    ["tip", localParseResult.tip],
    ["fees", localParseResult.fees],
    ["orderLevelDiscount", localParseResult.orderLevelDiscount ?? localParseResult.discount],
    ["grandTotal", localParseResult.grandTotal ?? localParseResult.total],
    ["confidence", localParseResult.confidence ?? localParseResult.confidenceLabel],
  ].filter(([, value]) => value != null && value !== "");
  if (summaryFields.length) {
    lines.push(`summary: ${summaryFields.map(([key, value]) => `${key}=${safeString(value).slice(0, 60)}`).join(" ")}`);
  }

  const summaryRows = localParseResult.candidateSummaryRows || localParseResult.summaryRows;
  if (Array.isArray(summaryRows) && summaryRows.length) {
    lines.push("candidate summary rows:");
    for (const row of summaryRows.slice(0, 12)) {
      lines.push(`- ${safeString(typeof row === "string" ? row : JSON.stringify(row)).slice(0, 180)}`);
    }
  }

  return lines.join("\n");
}

function formatLocalCandidateEvidence(localCandidates) {
  if (!Array.isArray(localCandidates) || !localCandidates.length) return [];
  return localCandidates.slice(0, 4).map((candidate, index) => {
    const source = safeString(candidate?.source || `candidate_${index + 1}`).slice(0, 80);
    const selected = candidate?.selected ? "selected" : "alternate";
    const trusted = candidate?.trusted ? "trusted" : "untrusted";
    const merchant = safeString(candidate?.merchant || "").slice(0, 100);
    const total = candidate?.grandTotal ?? null;
    const subtotal = candidate?.subtotal ?? null;
    const tax = candidate?.tax ?? null;
    const itemCount = Number.isFinite(candidate?.itemCount) ? candidate.itemCount : 0;
    const itemSum = candidate?.itemSum ?? null;
    const score = candidate?.selectionScore ?? null;
    const status = safeString(candidate?.verificationStatus || candidate?.validationStatus || "unknown").slice(0, 80);
    const items = Array.isArray(candidate?.items)
      ? candidate.items.slice(0, 16).map(item => {
          const name = safeString(item?.name || "").slice(0, 90);
          const amount = item?.amount ?? null;
          const discount = item?.discount ?? null;
          return `${name}=${amount}${discount ? ` discount=${discount}` : ""}`;
        }).filter(Boolean)
      : [];
    return [
      `${source} (${selected}, ${trusted}, status=${status}, score=${score})`,
      merchant ? `merchant=${merchant}` : null,
      `total=${total} subtotal=${subtotal} tax=${tax} itemCount=${itemCount} itemSum=${itemSum}`,
      items.length ? `items: ${items.join("; ")}` : null,
    ].filter(Boolean).join(" | ");
  });
}

function buildReceiptPromptWithLocalHints(localHints, appleOcrText, localParseResult, localCandidates) {
  const hintLines = [];
  if (localHints && typeof localHints === "object") {
    if (localHints.merchantCandidate) hintLines.push(`merchantCandidate: ${safeString(localHints.merchantCandidate).slice(0, 120)}`);
    if (localHints.grandTotalCandidate != null) hintLines.push(`grandTotalCandidate: ${localHints.grandTotalCandidate}`);
    if (localHints.grandTotalConfidence) hintLines.push(`grandTotalConfidence: ${safeString(localHints.grandTotalConfidence).slice(0, 60)}`);
    if (localHints.subtotalCandidate != null) hintLines.push(`subtotalCandidate: ${localHints.subtotalCandidate}`);
    if (localHints.taxCandidate != null) hintLines.push(`taxCandidate: ${localHints.taxCandidate}`);
    if (localHints.tipCandidate != null) hintLines.push(`tipCandidate: ${localHints.tipCandidate}`);
    if (localHints.targetMerchandiseSubtotal != null) hintLines.push(`targetMerchandiseSubtotal: ${localHints.targetMerchandiseSubtotal}`);
    if (localHints.fallbackReason) hintLines.push(`localFallbackReason: ${safeString(localHints.fallbackReason).slice(0, 240)}`);
  }

  const candidateLines = formatLocalCandidateEvidence(localCandidates);
  const compactApple = compactAppleOcrText(appleOcrText);
  const compactLocal = compactLocalParseResult(localParseResult);

  if (!hintLines.length && !candidateLines.length && !compactApple && !compactLocal) return EXTRACTION_PROMPT;

  const sections = [];
  if (compactApple) {
    sections.push(`APPLE OCR TRANSCRIPTION
Independent OCR evidence from the device. It may contain recognition errors or broken lines. Compare it against the receipt image; do not blindly copy it.
${compactApple}`);
  }
  if (compactLocal) {
    sections.push(`LOCAL PARSER HYPOTHESIS
This is an independent hypothesis, not ground truth. Use it when supported by the receipt image or OCR evidence. Correct it when the visual receipt contradicts it.
${compactLocal}`);
  }
  if (hintLines.length) {
    sections.push(`LOCAL SUMMARY HINTS
${hintLines.map(line => `- ${line}`).join("\n")}`);
  }
  if (candidateLines.length) {
    sections.push(`LOCAL CANDIDATE PARSES
${candidateLines.map(line => `- ${line}`).join("\n")}`);
  }

  return `${EXTRACTION_PROMPT}

Optional local evidence from the device is provided below. Use it only when visibly supported by the receipt image. Treat all local data as competing evidence, not truth. Prefer totals/items that agree with the image and arithmetic. Do not copy dirty, duplicated, footer/payment, or unsupported local rows.

${sections.join("\n\n")}`;
}

const ITEM_NAME_NORMALIZATION_PROMPT = `
You conservatively clean OCR-extracted receipt item names.

Use only raw_name.
Do not use merchant, item_code, or price to invent product details.
Do not use web search or external knowledge.

Rules:
1. Expand only obvious retail abbreviations.
2. Correct only obvious OCR mistakes.
3. Preserve unclear tokens.
4. Never invent product type, animal type, flavor, size, count, weight, brand, or preparation method.
5. A short generic label is better than an unsupported guess.
6. Return exactly one item for every input index.
7. Return JSON only.

Safe examples:
KS ORG TOFU -> Kirkland Signature Organic Tofu
ORGSPRINGMIX -> Organic Spring Mix
ROT CHKN -> Rotisserie Chicken
ORG 4BRY 5LB -> Organic 4-Berry, 5 lb
TENDERLOIN -> Tenderloin
SKO 5X -> SKO 5X
TERRA DLYSSA -> Terra Dlyssa
AUSSIE BITES -> Aussie Bites
ZIPLC SLIDER -> Ziploc Slider
TIRE EXT. -> Tire Ext.

Confidence:
- 0.95 to 1.00: clear readable text or obvious expansion
- 0.85 to 0.94: safe OCR correction
- 0.60 to 0.84: partial interpretation
- 0.00 to 0.59: unclear; preserve raw text

If confidence < 0.85:
- needsVerification = true

Allowed categories:
produce, meat_seafood, dairy_eggs, bakery, pantry, frozen,
beverages, snacks, prepared_food, household, personal_care,
health_wellness, pet, baby, alcohol, restaurant,
general_merchandise, other

Return:
{
  "items": [
    {
      "index": 0,
      "original": "string",
      "normalizedName": "string",
      "confidence": 0.00,
      "ambiguous": true,
      "needsVerification": true,
      "possibleAlternatives": [],
      "reason": "short explanation",
      "category": "other",
      "categoryConfidence": 0.00,
      "categoryReason": "short explanation"
    }
  ]
}
`;

// ============================================================
// UTILITY FUNCTIONS
// ============================================================

function round2(value) {
  if (value == null) return null;
  return Math.round((Number(value) + Number.EPSILON) * 100) / 100;
}

function toNumber(value) {
  if (value == null) return null;
  let text = String(value).trim();
  if (!text || /^null$/i.test(text) || /^n\/?a$/i.test(text)) return null;
  const negative = /^\s*\(/.test(text) || /^\s*-/.test(text);
  text = text
    .replace(/[$€£¥,\s]/g, "")
    .replace(/^\(/, "")
    .replace(/\)$/, "")
    .replace(/^\+/, "")
    .replace(/^-/, "");
  const num = Number(text);
  return Number.isFinite(num) ? round2(negative ? -num : num) : null;
}

function receiptGrandTotal(receipt) {
  return toNumber(receipt?.total) ?? toNumber(receipt?.grandTotal);
}

function salvageMistralReceiptAnnotation(annotation) {
  const raw = rawDocumentAnnotationObject(annotation);
  if (!raw || Array.isArray(raw) || typeof raw !== "object") return null;

  const items = Array.isArray(raw.items)
    ? raw.items.filter(item => item && typeof item === "object" && !Array.isArray(item))
    : [];
  const additionalFees = Array.isArray(raw.additionalFees)
    ? raw.additionalFees.filter(fee => fee && typeof fee === "object" && !Array.isArray(fee))
    : [];
  const merchantName = typeof raw.merchantName === "string"
    ? raw.merchantName
    : typeof raw.merchant === "string"
      ? raw.merchant
      : "";
  const grandTotal = receiptGrandTotal(raw);

  if (!merchantName && items.length === 0 && grandTotal == null) return null;

  return {
    ...raw,
    merchantName,
    items,
    additionalFees,
    total: grandTotal,
    grandTotal,
    confidence: ["high", "medium", "low"].includes(raw.confidence) ? raw.confidence : "medium",
    notes: [
      typeof raw.notes === "string" ? raw.notes : null,
      "Recovered valid fields from a partially schema-invalid Mistral annotation.",
    ].filter(Boolean).join(" "),
    annotationValidation: "salvaged",
  };
}

function preserveAnnotationGrandTotal(receipt, annotation, reqId = null) {
  if (!receipt || receiptGrandTotal(receipt) != null) return receipt;
  const annotationTotal = annotationGrandTotalValue(rawDocumentAnnotationObject(annotation));
  if (!(annotationTotal > 0)) return receipt;

  if (reqId) {
    console.log(`[${reqId}] Restored Mistral annotation total $${annotationTotal.toFixed(2)} after downstream normalization dropped it`);
  }
  return {
    ...receipt,
    total: annotationTotal,
    grandTotal: annotationTotal,
    notes: [
      receipt.notes,
      "Preserved the Mistral annotation total through downstream normalization.",
    ].filter(Boolean).join(" "),
  };
}

function normalizeMerchant(merchant) {
  if (!merchant) return "";
  return merchant
    .toUpperCase()
    .trim()
    .replace(/\s+/g, " ")
    .substring(0, 100);
}

/// Tax flags no product name ends in. Multi-letter, so stripping them is
/// unambiguous.
const UNAMBIGUOUS_TAX_FLAG = /\s+(?:NF|N\s+F|TX|TF|FT|TAXABLE)$/i;

/// Single-letter flags, restricted to letters a product name does not end on.
/// Case-sensitive: a lone capital trailing a row is a flag, a lowercase letter
/// is a word the OCR broke apart.
const SINGLE_LETTER_TAX_FLAG = /\s+[TFXON]$/;

/// Strip the tax flag receipts print after an item, without taking the last
/// word of the product with it.
///
/// The previous set included A, B and E — which is also how real products end.
/// "Vitamin B" became "Vitamin", "Plan B" became "Plan", "Coca Cola A" became
/// "Coca Cola". A name carrying a stray flag is a cosmetic blemish; a name
/// missing its last word is wrong, and the user is the one who has to
/// recognise the item when splitting the bill. So ambiguous letters stay.
function normalizeItemName(name) {
  if (!name) return "Unknown Item";

  let normalized = name.trim();
  normalized = normalized.replace(/^[O*\-•]\s+/, "");
  normalized = normalized.replace(UNAMBIGUOUS_TAX_FLAG, "");

  // Never strip a name down to nothing, or to a single letter.
  const withoutFlag = normalized.replace(SINGLE_LETTER_TAX_FLAG, "").trim();
  if (withoutFlag.length >= 2) normalized = withoutFlag;

  normalized = normalized.replace(/\s+/g, " ");

  return normalized.substring(0, 200);
}

function inferFallbackItemCategory(name) {
  const lower = (name || "").toLowerCase();

  if (/\b(lettuce|spring mix|tomato|tomatoes|banana|apple|avocado|berry|berries|kiwi|onion|potato|broccoli|produce|fruit|vegetable)\b/.test(lower)) {
    return "produce";
  }
  if (/\b(chicken|beef|pork|belly|steak|tenderloin|fish|salmon|shrimp|seafood|meat)\b/.test(lower)) {
    return "meat_seafood";
  }
  if (/\b(egg|eggs|milk|cheese|yogurt|butter|cream|dairy)\b/.test(lower)) {
    return "dairy_eggs";
  }
  if (/\b(bread|bagel|muffin|cake|bakery|croissant|bun|roll)\b/.test(lower)) {
    return "bakery";
  }
  if (/\b(rao|pasta|sauce|rice|flour|oil|spaghetti|pantry|cereal|beans)\b/.test(lower)) {
    return "pantry";
  }
  if (/\b(frozen|ice cream)\b/.test(lower)) {
    return "frozen";
  }
  if (/\b(water|juice|soda|coffee|tea|drink|beverage)\b/.test(lower)) {
    return "beverages";
  }
  if (/\b(chip|chips|cookie|cookies|cracker|crackers|snack|candy|chocolate)\b/.test(lower)) {
    return "snacks";
  }
  if (/\b(prepared|rotisserie|deli|meal|salad|soup|guac|guacamole|mash)\b/.test(lower)) {
    return "prepared_food";
  }
  if (/\b(ziploc|trash|paper|towel|detergent|cleaner|soap|household)\b/.test(lower)) {
    return "household";
  }
  if (/\b(shampoo|toothpaste|lotion|deodorant|personal care)\b/.test(lower)) {
    return "personal_care";
  }
  if (/\b(probiotic|vitamin|medicine|supplement|culturelle|health|wellness)\b/.test(lower)) {
    return "health_wellness";
  }
  if (/\b(dog|cat|pet)\b/.test(lower)) {
    return "pet";
  }
  if (/\b(baby|diaper|formula)\b/.test(lower)) {
    return "baby";
  }
  if (/\b(beer|wine|vodka|alcohol|liquor)\b/.test(lower)) {
    return "alcohol";
  }

  return "other";
}

function toReadableTitleToken(token) {
  if (!token) return token;
  if (/^[A-Z0-9]+$/.test(token)) return token;
  return token
    .split(/([-'./])/)
    .map(part => {
      if (/^[-'./]$/.test(part) || !part) return part;
      if (/^[A-Z0-9]+$/.test(part)) return part;
      return part.charAt(0).toUpperCase() + part.slice(1).toLowerCase();
    })
    .join("");
}

function applySafeLocalItemNameCleanup(name) {
  if (!name) return "Unknown Item";

  let normalized = String(name).trim().replace(/\s+/g, " ");

  for (const [pattern, replacement] of SAFE_OCR_REPLACEMENTS) {
    normalized = normalized.replace(pattern, replacement);
  }

  normalized = normalized
    .split(/\s+/)
    .flatMap(token => {
      const exactToken = token.replace(/^[^\w]+|[^\w]+$/g, "");
      const prefix = token.match(/^[^\w]+/)?.[0] || "";
      const suffix = token.match(/[^\w]+$/)?.[0] || "";
      const expansion = SAFE_ITEM_ABBREVIATIONS[exactToken];

      if (!expansion) {
        return [`${prefix}${toReadableTitleToken(exactToken || token)}${suffix}`];
      }

      const expandedTokens = expansion.split(/\s+/);
      if (expandedTokens.length === 1) {
        return [`${prefix}${expandedTokens[0]}${suffix}`];
      }
      return [`${prefix}${expandedTokens[0]}`, ...expandedTokens.slice(1, -1), `${expandedTokens.at(-1)}${suffix}`];
    })
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();

  return normalized || name;
}

function containsLikelyUnknownAbbreviation(name) {
  const tokens = String(name || "").match(/[A-Za-z0-9.]+/g) || [];
  const ordinaryReadableWords = new Set([
    "kirkland", "signature", "organic", "chicken", "guacamole", "single", "serve",
    "free", "range", "antibiotic", "rotisserie", "pack", "count", "ziploc",
    "tomatoes", "on", "the", "vine", "sliced", "extra", "virgin", "olive",
    "oil", "broccoli", "potato", "yellow", "bananas", "banana", "tenderloin",
    "spring", "mix", "spaghetti", "chopped", "onion", "chipotle", "lb", "oz",
    "aussie", "bites", "terra", "dlyssa", "slider", "tire",
  ]);

  return tokens.some(token => {
    if (/^EXT\.?$/i.test(token)) return true;
    if (/^MEDITERR$/i.test(token)) return true;
    if (/^(?=.*[A-Za-z])(?=.*\d)[A-Za-z0-9]+$/.test(token)) return true;
    if (/^[A-Z]{2,}$/.test(token) && !ordinaryReadableWords.has(token.toLowerCase())) return true;
    return false;
  });
}

function applyFastLocalNormalization(receipt) {
  if (!receipt?.items?.length) {
    return receipt;
  }

  return {
    ...receipt,
    items: receipt.items.map(item => {
      const rawName = item.name;
      const locallyNormalizedName = applySafeLocalItemNameCleanup(rawName);
      const containsUnknownAbbreviation = containsLikelyUnknownAbbreviation(locallyNormalizedName);

      return {
        ...item,
        rawName,
        normalizedName: locallyNormalizedName,
        normalizationSource: "local",
        normalizationConfidence: locallyNormalizedName === item.name ? 0.5 : 0.85,
        normalizationAmbiguous: containsUnknownAbbreviation,
        needsNameVerification: containsUnknownAbbreviation,
        possibleNameAlternatives: [],
        normalizationReason: containsUnknownAbbreviation
          ? "Applied safe local cleanup and preserved unclear tokens."
          : "Applied safe local normalization.",
        category: inferFallbackItemCategory(locallyNormalizedName),
        categoryConfidence: 0.5,
        categoryReason: "Category inferred locally from normalized receipt text.",
      };
    }),
  };
}

function hasRefundIndicators(text) {
  const lower = text.toLowerCase();
  return /\b(refund|return|returned|void|credit)\b/.test(lower);
}

// ============================================================
// MISTRAL OCR MARKDOWN FALLBACK ITEMIZER
// ============================================================

function cleanOcrLine(line) {
  return String(line || "")
    .replace(/!\[[^\]]*]\([^)]*\)/g, " ")
    // Mistral emphasises the total line often enough that leaving the markers
    // in place cost us the total outright: the amount matcher needs whitespace
    // in front of a number, and "**26.93**" gives it an asterisk.
    .replace(/\*\*|__/g, " ")
    .replace(/^#+\s*/, "")
    .replace(/^\s*[-*•]\s*/, "")
    .replace(/\|/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function amountMatchesInText(text) {
  const matches = [];
  const regex = /(?:^|[\s(])(-?\$?\s*\d{1,4}(?:,\d{3})*(?:[.,]\d{2})|\(\s*\$?\s*\d{1,4}(?:,\d{3})*(?:[.,]\d{2})\s*\))(?!\d)/g;
  for (const match of String(text || "").matchAll(regex)) {
    const raw = (match[1] || match[0]).trim();
    const normalized = raw
      .replace(/[()$,\s]/g, "")
      .replace(/(\d),(\d{2})$/, "$1.$2");
    const value = Number(normalized);
    if (!Number.isFinite(value)) continue;
    const signed = /^\(|-\s*\$?/.test(raw) ? -Math.abs(value) : value;
    matches.push({
      raw,
      value: round2(signed),
      index: match.index + match[0].indexOf(raw),
    });
  }
  return matches;
}

function lastAmountNearLineEnd(line) {
  const amounts = amountMatchesInText(line);
  if (!amounts.length) return null;
  const last = amounts[amounts.length - 1];
  const tail = line.slice(last.index + last.raw.length).trim();
  if (tail && !/^(?:[A-Z]{1,3}|[NFTX*]+)$/i.test(tail)) return null;
  return last;
}

function amountMagnitude(value) {
  return round2(Math.abs(Number(value || 0)));
}

const ADDITIONAL_FEE_TYPE_VALUES = new Set([
  "sales_tax",
  "state_tax",
  "local_tax",
  "city_tax",
  "county_tax",
  "district_tax",
  "vat",
  "gst",
  "hst",
  "pst",
  "qst",
  "occupancy_tax",
  "tourism_tax",
  "alcohol_tax",
  "other_tax",
  "tip",
  "gratuity",
  "automatic_gratuity",
  "service_charge",
  "delivery_fee",
  "convenience_fee",
  "processing_fee",
  "platform_fee",
  "booking_fee",
  "facility_fee",
  "resort_fee",
  "fuel_surcharge",
  "surcharge",
  "bag_fee",
  "bottle_deposit",
  "recycling_fee",
  "environmental_fee",
  "regulatory_fee",
  "other",
]);

function isTaxFeeType(feeType) {
  return [
    "sales_tax",
    "state_tax",
    "local_tax",
    "city_tax",
    "county_tax",
    "district_tax",
    "vat",
    "gst",
    "hst",
    "pst",
    "qst",
    "occupancy_tax",
    "tourism_tax",
    "alcohol_tax",
    "other_tax",
  ].includes(feeType);
}

function isTipOrGratuityFeeType(feeType) {
  return ["tip", "gratuity", "automatic_gratuity"].includes(feeType);
}

function inferAdditionalFeeType(label, role = null, explicitType = null) {
  const type = String(explicitType || "").trim().toLowerCase();
  if (ADDITIONAL_FEE_TYPE_VALUES.has(type)) return type;

  const lower = cleanOcrLine(label).toLowerCase();
  if (/\bvat\b/.test(lower)) return "vat";
  if (/\bgst\b/.test(lower)) return "gst";
  if (/\bhst\b/.test(lower)) return "hst";
  if (/\bpst\b/.test(lower)) return "pst";
  if (/\bqst\b/.test(lower)) return "qst";
  if (/\boccupancy|hotel|room\s+tax\b/.test(lower)) return "occupancy_tax";
  if (/\btourism|tourist\b/.test(lower)) return "tourism_tax";
  if (/\balcohol|liquor\b/.test(lower) && /\btax\b/.test(lower)) return "alcohol_tax";
  if (/\bstate\b.*\btax\b|\btax\b.*\bstate\b/.test(lower)) return "state_tax";
  if (/\bcity\b.*\btax\b|\btax\b.*\bcity\b/.test(lower)) return "city_tax";
  if (/\bcounty\b.*\btax\b|\btax\b.*\bcounty\b/.test(lower)) return "county_tax";
  if (/\bdistrict\b.*\btax\b|\btax\b.*\bdistrict\b/.test(lower)) return "district_tax";
  if (/\blocal\b.*\btax\b|\btax\b.*\blocal\b/.test(lower)) return "local_tax";
  if (/\bsales?\b.*\btax\b|\btax\b/.test(lower) || role === "tax") return lower.includes("sales") ? "sales_tax" : "other_tax";
  if (/\bautomatic\b.*\bgratuity\b|\bauto\b.*\bgrat\b/.test(lower)) return "automatic_gratuity";
  if (/\bgratuity|grat\b/.test(lower)) return "gratuity";
  if (/\btip\b/.test(lower) || role === "tip") return "tip";
  if (/\bservice\b.*\b(?:charge|fee)?\b/.test(lower)) return "service_charge";
  if (/\bdelivery\b/.test(lower)) return "delivery_fee";
  if (/\bconvenience\b/.test(lower)) return "convenience_fee";
  if (/\bprocessing\b/.test(lower)) return "processing_fee";
  if (/\bplatform\b/.test(lower)) return "platform_fee";
  if (/\bbooking\b/.test(lower)) return "booking_fee";
  if (/\bfacility\b/.test(lower)) return "facility_fee";
  if (/\bresort\b/.test(lower)) return "resort_fee";
  if (/\bfuel\b.*\bsurcharge\b/.test(lower)) return "fuel_surcharge";
  if (/\bbag\b/.test(lower)) return "bag_fee";
  if (/\bbottle\b.*\bdeposit\b/.test(lower)) return "bottle_deposit";
  if (/\brecycl/.test(lower)) return "recycling_fee";
  if (/\benvironment/.test(lower)) return "environmental_fee";
  if (/\bregulatory|regulation\b/.test(lower)) return "regulatory_fee";
  if (/\bsurcharge\b/.test(lower)) return "surcharge";
  if (role === "fees") return "other";
  return "other";
}

function extractRateFromLine(line) {
  const match = cleanOcrLine(line).match(/(?<![\d.])(\d{1,2}(?:\.\d{1,4})?)\s*%(?!\d)/);
  return match ? toNumber(match[1]) : null;
}

function additionalFeeLabelFromLine(line, amount) {
  return removeAmountText(line, amount)
    .replace(/(?<![\d.])\d{1,2}(?:\.\d{1,4})?\s*%(?!\d)/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isExcludedAdditionalFeeLabel(label) {
  const lower = cleanOcrLine(label).toLowerCase();
  if (!lower) return true;
  if (isLikelySuggestedTipRowText(lower)) return true;
  if (/\b(?:suggested|suggestion|optional|select|choose)\b.*\b(?:tip|gratuity)\b/.test(lower)) return true;
  if (/^\s*(?:[1-4]?\d|50)\s*%/.test(lower)) return true;
  const role = summaryRoleForLabel(lower);
  return ["subtotal", "grandTotal", "orderLevelDiscount", "payment"].includes(role);
}

function normalizeAdditionalFeeEntry(raw, fallbackRole = null) {
  if (!raw || typeof raw !== "object") return null;
  const label = cleanOcrLine(raw.feeName ?? raw.feeLabel ?? raw.label ?? raw.name ?? "");
  const amount = toNumber(raw.feeValue ?? raw.amount ?? raw.value);
  if (amount == null || amount <= 0) return null;
  if (isExcludedAdditionalFeeLabel(label)) return null;

  const feeType = inferAdditionalFeeType(label, fallbackRole, raw.feeType ?? raw.kind);
  const isTax = raw.isTax != null ? Boolean(raw.isTax) : isTaxFeeType(feeType);
  const isTipOrGratuity = raw.isTipOrGratuity != null
    ? Boolean(raw.isTipOrGratuity)
    : isTipOrGratuityFeeType(feeType);

  return {
    feeName: label || (isTax ? "Tax" : isTipOrGratuity ? "Tip" : "Fee"),
    feeValue: round2(amount),
    feeLabel: label || (isTax ? "Tax" : isTipOrGratuity ? "Tip" : "Fee"),
    feeType,
    amount: round2(amount),
    rate: toNumber(raw.rate),
    isTax,
    isTipOrGratuity,
  };
}

function dedupeAdditionalFees(fees) {
  return (fees || []).filter(Boolean);
}

function normalizeAdditionalFees(fees) {
  if (!Array.isArray(fees)) return [];
  return dedupeAdditionalFees(fees.map(fee => normalizeAdditionalFeeEntry(fee)).filter(Boolean));
}

function legacyAdditionalFeesFromScalars(parsed) {
  const result = [];
  const tax = toNumber(parsed?.tax);
  const tip = toNumber(parsed?.tip);
  const fees = toNumber(parsed?.fees);
  if (tax != null && tax > 0) {
    result.push(normalizeAdditionalFeeEntry({ feeLabel: "Tax", feeType: "other_tax", amount: tax, isTax: true, isTipOrGratuity: false }, "tax"));
  }
  if (tip != null && tip > 0) {
    result.push(normalizeAdditionalFeeEntry({ feeLabel: "Tip", feeType: "tip", amount: tip, isTax: false, isTipOrGratuity: true }, "tip"));
  }
  if (fees != null && fees > 0) {
    result.push(normalizeAdditionalFeeEntry({ feeLabel: "Fee", feeType: "other", amount: fees, isTax: false, isTipOrGratuity: false }, "fees"));
  }
  return dedupeAdditionalFees(result);
}

function summarizeAdditionalFees(additionalFees) {
  return (additionalFees || []).reduce((summary, fee) => {
    if (!fee?.amount) return summary;
    if (fee.isTax || isTaxFeeType(fee.feeType)) {
      summary.tax = round2((summary.tax || 0) + fee.amount);
    } else if (fee.isTipOrGratuity || isTipOrGratuityFeeType(fee.feeType)) {
      summary.tip = round2((summary.tip || 0) + fee.amount);
    } else {
      summary.fees = round2((summary.fees || 0) + fee.amount);
    }
    summary.additionalFeesTotal = round2((summary.additionalFeesTotal || 0) + fee.amount);
    return summary;
  }, { tax: null, tip: null, fees: null, additionalFeesTotal: null });
}

function pushAdditionalFeeFromSummaryLine(summary, role, line, amount) {
  if (!["tax", "tip", "fees"].includes(role) || !amount) return;
  const value = amountMagnitude(amount.value);
  if (!(value > 0)) return;
  const fee = normalizeAdditionalFeeEntry({
    feeLabel: additionalFeeLabelFromLine(line, amount),
    feeType: inferAdditionalFeeType(line, role),
    amount: value,
    rate: extractRateFromLine(line),
  }, role);
  if (!fee) return;
  summary.additionalFees = dedupeAdditionalFees([...(summary.additionalFees || []), fee]);
}

function removeTipAdditionalFees(additionalFees) {
  return (additionalFees || []).filter(fee => !(fee.isTipOrGratuity || isTipOrGratuityFeeType(fee.feeType)));
}

function moneyToCents(value) {
  const normalized = toNumber(value);
  if (normalized == null) return null;
  return Math.round(normalized * 100);
}

function centsToMoney(value) {
  if (value == null || !Number.isFinite(Number(value))) return null;
  return round2(Number(value) / 100);
}

function moneyGapCents(a, b) {
  const aCents = moneyToCents(a);
  const bCents = moneyToCents(b);
  if (aCents == null || bCents == null) return null;
  return aCents - bCents;
}

function comparableText(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function itemNameTokens(value) {
  const tokens = comparableText(value)
    .split(/\s+/)
    .filter(token => token.length >= 2 && !SUMMARY_FILLER_TOKENS.has(token));
  return new Set(tokens);
}

function tokenOverlapRatio(a, b) {
  const left = itemNameTokens(a);
  const right = itemNameTokens(b);
  if (!left.size || !right.size) return 0;
  let overlap = 0;
  for (const token of left) {
    if (right.has(token)) overlap += 1;
  }
  return overlap / Math.min(left.size, right.size);
}

function receiptItemSignature(item) {
  return `${comparableText(item?.name || item?.rawName)}|${moneyToCents(item?.amount ?? item?.printedAmount) ?? "na"}`;
}

function itemMatchesEvidence(item, evidence) {
  const itemCents = moneyToCents(item?.amount ?? item?.printedAmount);
  if (itemCents == null || evidence?.cents == null || itemCents !== evidence.cents) return false;
  return tokenOverlapRatio(item?.name || item?.rawName, evidence.name || evidence.line) >= 0.5;
}

function receiptHasEquivalentItem(receipt, name, amount) {
  const cents = moneyToCents(amount);
  return (receipt?.items || []).some(item => {
    const itemCents = moneyToCents(item.amount ?? item.printedAmount);
    return itemCents === cents && tokenOverlapRatio(item.name || item.rawName, name) >= 0.5;
  });
}

function extractReceiptMoneyEvidence({ ocrText = "", appleOcrText = "" } = {}) {
  const sources = [
    ["mistral", ocrText],
    ["apple", appleOcrText],
  ];
  const evidence = [];
  const seen = new Set();

  for (const [source, text] of sources) {
    const lines = String(text || "")
      .split(/\r?\n/)
      .map(cleanOcrLine)
      .filter(Boolean);

    for (const line of lines) {
      const amount = lastAmountNearLineEnd(line);
      if (!amount) continue;
      const cents = moneyToCents(amountMagnitude(amount.value));
      if (cents == null || cents <= 0) continue;

      const role = summaryRoleForLine(line);
      const metadata = isReceiptMetadataLine(line);
      const discount = isDiscountLine(line);
      const name = role || metadata || discount ? "" : normalizeFallbackItemName(line, amount);
      const itemLike = Boolean(
        !role &&
        !metadata &&
        !discount &&
        isLikelyReceiptItemName(name) &&
        comparableText(name).length >= 2
      );
      const key = `${source}|${comparableText(line)}|${cents}`;
      if (seen.has(key)) continue;
      seen.add(key);

      evidence.push({
        source,
        line,
        amount: centsToMoney(cents),
        cents,
        role: role || null,
        metadata,
        discount,
        itemLike,
        name,
        netSalesLike: /^net\s+sales?\b/i.test(cleanOcrLine(line)),
        netTotalLike: /^net\s+total\b/i.test(cleanOcrLine(line)),
      });
    }
  }

  return evidence;
}

function rawDocumentAnnotationObject(annotation) {
  if (!annotation) return null;
  if (typeof annotation === "object") return annotation;
  if (typeof annotation !== "string") return null;
  try {
    return JSON.parse(annotation);
  } catch {
    return null;
  }
}

function annotationGrandTotalValue(rawAnnotation) {
  if (!rawAnnotation || typeof rawAnnotation !== "object") return null;
  return receiptGrandTotal(rawAnnotation);
}

function visibleGrandTotalCandidatesFromOcr(ocrText) {
  return extractReceiptMoneyEvidence({ ocrText })
    .filter(evidence => evidence.source === "mistral" && evidence.role === "grandTotal")
    .map(evidence => ({
      amount: evidence.amount,
      line: evidence.line,
    }))
    .slice(0, 5);
}

function buildExtractionDiagnostics({ ocrText = "", result = null, parsed = null, reconciliation = null, uploadDiagnostics = null } = {}) {
  const rawAnnotation = rawDocumentAnnotationObject(result?.documentAnnotation);
  const annotationGrandTotal = annotationGrandTotalValue(rawAnnotation);
  const normalizedGrandTotal = toNumber(parsed?.grandTotal);
  const ocrGrandTotalCandidates = visibleGrandTotalCandidatesFromOcr(ocrText);
  const mismatchReasons = reconciliation?.mismatchReasons || [];
  const missingGrandTotal = normalizedGrandTotal == null || mismatchReasons.includes("no_grand_total");

  let totalLossLayer = "none";
  if (missingGrandTotal) {
    if (ocrGrandTotalCandidates.length && annotationGrandTotal == null) {
      totalLossLayer = "annotation_missing_total_visible_in_ocr";
    } else if (annotationGrandTotal != null && normalizedGrandTotal == null) {
      totalLossLayer = "normalization_lost_annotation_total";
    } else if (!ocrGrandTotalCandidates.length && annotationGrandTotal == null) {
      totalLossLayer = "ocr_and_annotation_missing_total";
    } else {
      totalLossLayer = "reconciliation_missing_total";
    }
  }

  return {
    modelRequested: MISTRAL_OCR_MODEL,
    modelReturned: result?.model || null,
    ocrTextLength: String(ocrText || "").length,
    ocrGrandTotalCandidates,
    annotationPresent: rawAnnotation != null,
    annotationGrandTotal,
    normalizedGrandTotal,
    totalLossLayer,
    upload: uploadDiagnostics,
  };
}

function localEvidenceItems(localParseResult, localCandidates) {
  const items = [];
  const pushItem = (item, source) => {
    const name = safeString(item?.name || item?.rawName || "").slice(0, 140);
    const amount = toNumber(item?.amount ?? item?.printedAmount);
    if (!name || amount == null || amount < 0.01 || isLikelyNonItemRow(name)) return;
    items.push({
      source,
      name: normalizeItemName(name),
      amount,
      cents: moneyToCents(amount),
      confidence: item?.confidence ?? item?.confidenceLabel ?? null,
    });
  };

  for (const item of Array.isArray(localParseResult?.items) ? localParseResult.items : []) {
    pushItem(item, "localParseResult");
  }
  for (const candidate of Array.isArray(localCandidates) ? localCandidates : []) {
    for (const item of Array.isArray(candidate?.items) ? candidate.items : []) {
      pushItem(item, `localCandidate:${safeString(candidate?.source || "unknown").slice(0, 60)}`);
    }
  }
  return items;
}

function buildParsedReceiptFromLocalParse(localParseResult) {
  if (!localParseResult || typeof localParseResult !== "object") return null;
  const rawItems = Array.isArray(localParseResult.items) ? localParseResult.items : [];
  if (!rawItems.length && localParseResult.grandTotal == null && localParseResult.total == null) return null;

  return {
    merchant: localParseResult.merchant || "",
    receiptDate: localParseResult.receiptDate || localParseResult.date || null,
    currency: localParseResult.currency || "USD",
    items: rawItems.map(item => ({
      name: item?.name || item?.rawName || "Unknown Item",
      printedAmount: item?.amount ?? item?.printedAmount,
      discountAmount: item?.discountAmount ?? null,
      discountLabel: item?.discountLabel ?? null,
      itemCode: item?.itemCode ?? null,
      qty: item?.qty ?? item?.quantity ?? null,
      unitPrice: item?.unitPrice ?? null,
      weightLbs: item?.weightLbs ?? null,
      sourceText: item?.sourceText ?? null,
    })),
    subtotal: localParseResult.subtotal ?? null,
    tax: localParseResult.tax ?? null,
    tip: localParseResult.tip ?? null,
    fees: localParseResult.fees ?? null,
    orderLevelDiscount: localParseResult.orderLevelDiscount ?? localParseResult.discount ?? null,
    grandTotal: localParseResult.grandTotal ?? localParseResult.total ?? null,
    confidence: localParseResult.confidence || "medium",
    notes: "Local parser hypothesis selected by backend arbitration.",
  };
}

function cleanReceiptForCandidate(normalized, reqId) {
  const stripped = stripNonItemRows(normalized?.items || [], reqId);
  const items = stripped.kept.map(item => {
    const printedAmount = round2(item.printedAmount ?? item.amount);
    const discount = item.discountAmount ?? item.itemDiscount ?? 0;
    const discountApplication = item.discountApplication || (discount > 0 ? "already_reflected" : "none");
    const originalAmount = item.originalAmount != null
      ? round2(item.originalAmount)
      : (discount > 0 && discountApplication !== "informational" ? round2(printedAmount + discount) : null);
    return {
      ...item,
      printedAmount,
      amount: round2(printedAmount),
      originalAmount,
      itemDiscount: discount > 0 ? round2(discount) : item.itemDiscount ?? null,
      itemDiscountLabel: discount > 0 ? item.discountLabel || item.itemDiscountLabel || null : item.itemDiscountLabel ?? null,
      discountApplication,
    };
  });
  const withItems = { ...normalized, items };
  const suggestedTipSuppression = suppressUnchargedSuggestedTip(withItems, reqId);
  return {
    receipt: suggestedTipSuppression.receipt,
    changes: [
      ...stripped.dropped.map(item => `Removed non-item row: "${item.name}"`),
      suggestedTipSuppression.reason,
    ].filter(Boolean),
    suspicious: stripped.dropped.map((item, index) => ({ index, item, flags: ["non_item_row"] })),
  };
}

function summaryFieldsFromLocalEvidence(localHints, localParseResult) {
  const summary = {};
  const assign = (key, value) => {
    const number = toNumber(value);
    if (number != null) summary[key] = number;
  };
  assign("subtotal", localParseResult?.subtotal ?? localHints?.subtotalCandidate);
  assign("tax", localParseResult?.tax ?? localHints?.taxCandidate);
  assign("tip", localParseResult?.tip ?? localHints?.tipCandidate);
  assign("fees", localParseResult?.fees);
  assign("orderLevelDiscount", localParseResult?.orderLevelDiscount ?? localParseResult?.discount);
  assign("grandTotal", localParseResult?.grandTotal ?? localParseResult?.total ?? localHints?.grandTotalCandidate);
  return summary;
}

function merchandiseTargetFromEvidence(receipt, localHints) {
  const subtotalCents = moneyToCents(receipt?.subtotal);
  if (subtotalCents != null) return { cents: subtotalCents, source: "subtotal" };
  const target = moneyToCents(localHints?.targetMerchandiseSubtotal);
  if (target != null) return { cents: target, source: "local_target_merchandise_subtotal" };
  return null;
}

function removeAmountText(line, amount) {
  if (!amount) return cleanOcrLine(line);
  const escaped = amount.raw.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return cleanOcrLine(String(line || "").replace(new RegExp(escaped, "g"), " "));
}

function isLikelyReceiptItemName(text) {
  const cleaned = cleanOcrLine(text);
  if (cleaned.length < 2) return false;
  if (!/[A-Za-z]/.test(cleaned)) return false;
  if (/^\d+[.)]?$/.test(cleaned)) return false;
  return true;
}

/// A printed suggested-gratuity table, which must not be read as a charged tip.
///
/// The percent heuristic below is deliberately narrow, because the wide version
/// of it swallowed sales tax. "SALES TAX 10.25% 3.36" has a percent and two
/// numbers on it, and that was enough to file the line under "payment" and drop
/// the tax outright — a silent hole in every receipt that prints its tax rate.
/// Two things keep that from happening now: a rate written with decimals is not
/// a tip percent, and a line that names a tax is never a tip table.
function isLikelySuggestedTipRowText(text) {
  const lower = cleanOcrLine(text).toLowerCase();
  if (!lower) return false;
  if (/\bsuggest(?:ed|ions?)?\b.*\b(?:tip|gratuity)\b/.test(lower)) return true;
  if (/\b(?:tip|gratuity)\b.*\bsuggest(?:ed|ions?)?\b/.test(lower)) return true;
  if (/\b(?:tip|gratuity)\b.*\bamount\b.*\btotal\b/.test(lower)) return true;

  // A tax, subtotal or fee line is a summary row with a rate on it, not a
  // gratuity option. Checked after the explicit rules above so that a genuine
  // "suggested tip (pre-tax)" header is still recognised.
  if (/\b(?:tax|taxes|hst|gst|pst|qst|vat|subtotal|sub total)\b/.test(lower)) return false;

  // Tip tables print whole percents (15%, 18%, 20%). The lookbehind stops the
  // fractional half of a decimal rate — the "25" of "10.25%" — from passing as
  // one.
  const hasTipTablePercent = /(?<![\d.])(?:[1-4]?\d|50)\s*%(?!\d)/.test(lower);
  if (!hasTipTablePercent) return false;

  // A tip table row carries the tip and the resulting total side by side. A
  // tip that was actually charged carries one amount, so requiring two is what
  // separates "20% 11.80 76.11" from "TIP 20% 8.00".
  const amountCount = amountMatchesInText(lower).length;
  return amountCount >= 2 || /^\s*(?:[1-4]?\d|50)\s*%/.test(lower);
}

function isReceiptMetadataLine(line) {
  const lower = cleanOcrLine(line).toLowerCase();
  if (!lower) return true;
  if (isLikelySuggestedTipRowText(lower)) return true;
  if (/^[-=_]{2,}$/.test(lower)) return true;
  if (/^(qty|quantity|item|description|price|amount|total)\b(?:\s+\w+)*$/.test(lower)) return true;
  if (/\b(?:tel|phone|address|street|avenue|road|blvd|suite|www\.|http|email)\b/.test(lower)) return true;
  if (/\b(?:cashier|server|table|guest|check|order|invoice|transaction|terminal|register|store)\s*(?:#|no|number|id)?\b/.test(lower)) return true;
  if (/\b(?:auth|approval|aid|tvr|tsi|ref|trace|batch)\b/.test(lower)) return true;
  if (/\b(?:visa|mastercard|amex|discover|debit|credit card|card\b|contactless|chip read|swiped)\b/.test(lower)) return true;
  if (/\b(?:thank you|thanks|survey|returns?|exchange|policy|reward|points|member id)\b/.test(lower)) return true;
  return false;
}

/// Which summary field a label opens, in priority order.
///
/// Every pattern is anchored, because a summary label is what a row *starts*
/// with. Searching for these words anywhere in the line is what deleted
/// "COLGATE TOTAL TP" off a CVS receipt and filed "VAT 69 WHISKY" under sales
/// tax. Order matters twice over: the discount rows must be tested before the
/// bare `total`, or "TOTAL SAVINGS" reads as the amount due; and the total rows
/// must be tested before the fee rows, or "TOTAL CHARGE" reads as a service fee
/// and the receipt ends up with no total at all.
const SUMMARY_ROLE_PATTERNS = [
  ["subtotal", /^sub[\s-]?total\b/],
  ["subtotal", /^merchandise\s+(?:sub)?total\b/],
  ["subtotal", /^net\s+sales?\b/],
  ["subtotal", /^net\s+total\b/],
  ["tax", /^(?:sales|state|local|city|county|food|liquor|meals?|room|use)?\s*tax(?:es)?\s*\d*\b/],
  ["tax", /^(?:hst|gst|pst|qst|vat)\b/],
  // Delivery apps name the tip after whoever earns it. Without the qualifier
  // "Dasher Tip" reads as an item and gets split across the table like food.
  ["tip", /^(?:dasher|driver|courier|shopper|server|delivery|suggested|added)?\s*(?:tip|gratuity)\b/],
  ["orderLevelDiscount", /^(?:you\s+saved|total\s+savings?|member\s+savings?|instant\s+savings?)\b/],
  ["orderLevelDiscount", /^(?:order|member|instant|promo(?:tion)?|coupon|total)\s+(?:discount|savings?)\b/],
  ["orderLevelDiscount", /^(?:discount|savings?|coupon|promo(?:tion)?|markdown|rewards?|loyalty)\b/],
  ["grandTotal", /^(?:grand|order|sale|transaction|trans|check|final|store)\s+total\b/],
  ["grandTotal", /^(?:total|balance|amount|payment)\s+(?:due|paid|payable|charged?|tendered?|owed)\b/],
  ["grandTotal", /^total\b/],
  ["fees", /^(?:service|delivery|convenience|processing|bag|carryout|to[\s-]?go|pickup|surcharge)\s*(?:charge|fee)s?\b/],
  ["fees", /^(?:fee|surcharge)s?\b/],
  ["fees", /^(?:service|delivery|convenience|processing|bag|carryout|pickup)\b/],
  ["payment", /^(?:cash|credit|debit|change|tender(?:ed)?|payment|paid|refund)\b/],
  ["payment", /^(?:card|bank\s*card)\s*(?:payment|tender(?:ed)?|paid|charge(?:d)?)?\b/],
  ["payment", /^(?:visa|mastercard|master card|amex|american express|discover|diners|jcb|unionpay)\b/],
  ["payment", /^(?:auth|approval|aid|tvr|tsi|rrn|arqc|ref|trace|batch|seq|invoice|terminal|merchant)\b/],
  ["payment", /^(?:number\s+of\s+items|items?\s+sold|item\s+count)\b/],
];

/// Words allowed to trail a summary label without turning the row into a
/// product: qualifiers, rates, counts, payment metadata. Anything outside this
/// set — "cabernet", "whisky", "burger" — means the label was part of a real
/// item name and the row must be kept.
const SUMMARY_FILLER_TOKENS = new Set([
  "a", "an", "the", "and", "of", "on", "at", "for", "to", "in", "per",
  "due", "paid", "payable", "owed", "charge", "charged", "charges",
  "tender", "tendered", "amount", "amt", "balance", "total", "subtotal", "sub",
  "sales", "sale", "tax", "taxes", "taxable", "rate", "incl", "included",
  "including", "excl", "excluding", "item", "items", "count", "qty", "quantity",
  "number", "num", "no", "sold", "line", "lines", "usd", "ea", "each",
  "net", "gross", "order", "check", "transaction", "trans", "visit", "purchase",
  "savings", "saved", "discount", "discounts", "coupon", "coupons", "promo",
  "tip", "gratuity", "cash", "credit", "debit", "card", "change", "payment",
  "grand", "final", "new", "prior", "previous", "current", "before", "after",
  "percent", "pct", "approx", "est", "estimated", "code", "id", "ref",
  "seq", "batch", "trace", "terminal", "term", "reg", "register", "store",
  "merchant", "acct", "account", "auth", "approval", "chip", "swiped",
  "contactless", "entry", "method", "type", "name", "holder", "signature",
  "service", "fee", "fees", "surcharge", "today", "you", "your", "we",
]);

/// The role a label carries, or null when the text is a purchased item.
///
/// A summary row is its label and nothing else. Match the label at the start,
/// then require whatever follows to be filler; if a substantive word survives,
/// this is a product that happens to share a word with a summary label.
function summaryRoleForLabel(text) {
  // Receipts arrive with the label dressed up — "**** TOTAL" on Costco,
  // "**TOTAL**" wherever Mistral decides the line was bold. Anchoring has to
  // happen past that, not before it.
  const lower = String(text || "").toLowerCase().trim().replace(/^[^a-z0-9]+/, "");
  if (!lower) return null;

  for (const [role, pattern] of SUMMARY_ROLE_PATTERNS) {
    if (!pattern.test(lower)) continue;
    const residue = lower.replace(pattern, " ");
    const words = residue.match(/[a-z]+/g) || [];
    if (words.every(word => SUMMARY_FILLER_TOKENS.has(word))) return role;
  }
  return null;
}

function summaryRoleForLine(line) {
  const lower = cleanOcrLine(line).toLowerCase();
  if (isLikelySuggestedTipRowText(lower)) return "payment";
  return summaryRoleForLabel(lower);
}

function isDiscountLine(line) {
  const lower = cleanOcrLine(line).toLowerCase();
  return /\b(?:discount|coupon|savings?|promo|promotion|markdown|member price|instant|void)\b/.test(lower);
}

function inferQuantityFields(line) {
  const text = cleanOcrLine(line);
  const weighted = text.match(/\b(\d+(?:\.\d+)?)\s*(?:lb|lbs|pound|pounds)\b.*?(?:@|x)\s*\$?\s*(\d+(?:\.\d{2})?)/i);
  if (weighted) {
    const weight = toNumber(weighted[1]);
    return { qty: weight, weightLbs: weight, unitPrice: toNumber(weighted[2]) };
  }
  const each = text.match(/\b(\d+(?:\.\d+)?)\s*(?:@|x)\s*\$?\s*(\d+(?:\.\d{2})?)\b/i);
  if (each) {
    return { qty: toNumber(each[1]), weightLbs: null, unitPrice: toNumber(each[2]) };
  }
  const leadingQty = text.match(/^\s*(\d+(?:\.\d+)?)\s+(?=[A-Za-z])/);
  if (leadingQty) {
    const qty = toNumber(leadingQty[1]);
    return qty && qty > 1 ? { qty, weightLbs: null, unitPrice: null } : { qty: null, weightLbs: null, unitPrice: null };
  }
  return { qty: null, weightLbs: null, unitPrice: null };
}

function inferItemCode(line, name) {
  const text = `${line || ""} ${name || ""}`;
  const match = text.match(/\b\d{5,14}\b/);
  return match?.[0] || null;
}

/// True when nothing is left of a row but pricing scaffolding — "lb", "ea",
/// "@". Such a row is the continuation of the item named on the line above, so
/// its remains must never be mistaken for a name of its own.
function isUnitNoiseOnly(text) {
  const words = String(text || "").toLowerCase().match(/[a-z]+/g);
  if (!words) return true;
  return words.every(word =>
    ["lb", "lbs", "pound", "pounds", "ea", "each", "oz", "kg", "g", "ml", "l", "x", "at", "per"].includes(word)
  );
}

/// Order matters here, and getting it wrong cost every by-weight grocery row
/// its name. Stripping the leading quantity first consumed the "0.98" that the
/// weighted-price pattern needs to anchor on, so "0.98 lb @ $0.79/lb" survived
/// as "lb @ $0.79" — long enough and letter-y enough to pass for a name, which
/// suppressed the merge with "ORGANIC BANANAS" on the line above. Produce, meat
/// and deli are most of a grocery run, so this was most of the receipt. The
/// price patterns now run while their anchors are still present, and the
/// leading quantity goes last.
function normalizeFallbackItemName(line, amount, pendingName = "") {
  let name = removeAmountText(line, amount)
    .replace(/\b\d+(?:\.\d+)?\s*(?:lb|lbs|pound|pounds)\b.*?(?:@|x)\s*\$?\s*\d+(?:\.\d{2})?/ig, " ")
    .replace(/\b\d+(?:\.\d+)?\s*(?:@|x)\s*\$?\s*\d+\.\d{2}\b/ig, " ")
    .replace(/\/\s*(?:lb|lbs|pound|pounds|ea|each)\b/ig, " ")
    .replace(/^\s*\d+(?:\.\d+)?\s+(?=[A-Za-z])/, "")
    // Single-letter flags are left to normalizeItemName, which knows which
    // letters are safe to remove.
    .replace(/\b(?:NF|TX|TAXABLE)\b$/i, "")
    .replace(/\s+/g, " ")
    .trim();
  if (pendingName) {
    if (isUnitNoiseOnly(name)) {
      name = pendingName;
    } else if (!isLikelyReceiptItemName(name) || name.length < 4) {
      name = `${pendingName} ${name}`.trim();
    }
  }
  return normalizeItemName(name);
}

function updateSummaryFromLine(summary, line, amount) {
  const role = summaryRoleForLine(line);
  if (!role || !amount) return;
  const value = amountMagnitude(amount.value);
  if (role === "subtotal") summary.subtotal = value;
  if (role === "tax") {
    summary.tax = round2((summary.tax || 0) + value);
    pushAdditionalFeeFromSummaryLine(summary, role, line, amount);
  }
  if (role === "tip") {
    summary.tip = round2((summary.tip || 0) + value);
    pushAdditionalFeeFromSummaryLine(summary, role, line, amount);
  }
  if (role === "fees") {
    summary.fees = round2((summary.fees || 0) + value);
    pushAdditionalFeeFromSummaryLine(summary, role, line, amount);
  }
  if (role === "orderLevelDiscount") summary.orderLevelDiscount = round2((summary.orderLevelDiscount || 0) + value);
  if (role === "grandTotal") {
    const lower = cleanOcrLine(line).toLowerCase();
    const priority = lower.includes("balance due") || lower.includes("amount due") ? 4
      : lower.includes("grand total") || lower.includes("total due") || lower.includes("order total") ? 3
      : /\btotal\b/.test(lower) ? 2
      : 1;
    if (priority >= (summary.grandTotalPriority || 0)) {
      summary.grandTotal = value;
      summary.grandTotalPriority = priority;
    }
  }
}

function likelyMerchantFromOcrLines(lines) {
  for (const line of lines.slice(0, 10)) {
    const cleaned = cleanOcrLine(line);
    if (!cleaned) continue;
    if (isReceiptMetadataLine(cleaned)) continue;
    if (amountMatchesInText(cleaned).length) continue;
    if (cleaned.length < 3 || cleaned.length > 80) continue;
    return normalizeMerchant(cleaned);
  }
  return "";
}

function buildReceiptFromMistralOcrText(ocrText, reqId = "ocr_text_fallback") {
  const lines = String(ocrText || "")
    .split(/\r?\n/)
    .map(cleanOcrLine)
    .filter(Boolean)
    .filter(line => !/^:?-{3,}:?$/.test(line));

  if (!lines.length) return null;
  const merchant = likelyMerchantFromOcrLines(lines);

  const items = [];
  const summary = {
    subtotal: null,
    tax: null,
    tip: null,
    fees: null,
    additionalFees: [],
    additionalFeesTotal: null,
    orderLevelDiscount: null,
    grandTotal: null,
    grandTotalPriority: 0,
  };
  let pendingName = "";

  for (const line of lines) {
    if (merchant && normalizeMerchant(line) === merchant) {
      pendingName = "";
      continue;
    }
    if (isLikelySuggestedTipRowText(line)) {
      pendingName = "";
      continue;
    }
    const amount = lastAmountNearLineEnd(line);
    if (amount) updateSummaryFromLine(summary, line, amount);

    if (amount && isDiscountLine(line)) {
      const value = amountMagnitude(amount.value);
      const lastItem = items[items.length - 1];
      const lowerDiscountLine = cleanOcrLine(line).toLowerCase();
      const orderWideDiscount = /\b(?:total|order|basket|cart|you saved)\b/.test(lowerDiscountLine);
      if (lastItem && !orderWideDiscount && value > 0 && value <= Math.max(lastItem.printedAmount, 1) * 1.25) {
        lastItem.discountAmount = round2((lastItem.discountAmount || 0) + value);
        lastItem.discountLabel = [lastItem.discountLabel, removeAmountText(line, amount)].filter(Boolean).join(" + ") || "Discount";
        lastItem.sourceText = [lastItem.sourceText, line].filter(Boolean).join("\n");
      } else {
        summary.orderLevelDiscount = round2((summary.orderLevelDiscount || 0) + value);
      }
      pendingName = "";
      continue;
    }

    const role = summaryRoleForLine(line);
    if (role && role !== "payment") {
      pendingName = "";
      continue;
    }
    if (role === "payment" || isReceiptMetadataLine(line)) {
      pendingName = "";
      continue;
    }

    if (!amount) {
      if (!isDiscountLine(line) && isLikelyReceiptItemName(line)) {
        pendingName = pendingName ? `${pendingName} ${line}` : line;
      }
      continue;
    }

    const price = amountMagnitude(amount.value);
    if (price <= 0) {
      pendingName = "";
      continue;
    }

    const name = normalizeFallbackItemName(line, amount, pendingName);
    if (!isLikelyReceiptItemName(name)) {
      pendingName = "";
      continue;
    }
    const quantity = inferQuantityFields(line);
    const sourceText = pendingName ? `${pendingName}\n${line}` : line;
    items.push({
      name,
      printedAmount: price,
      discountAmount: null,
      discountLabel: null,
      itemCode: inferItemCode(line, name),
      qty: quantity.qty,
      unitPrice: quantity.unitPrice,
      weightLbs: quantity.weightLbs,
      sourceText,
      modifiers: null,
    });
    pendingName = "";
  }

  const uniqueItems = [];
  const seenConsecutive = new Set();
  for (const item of items) {
    const key = `${item.name.toLowerCase()}|${item.printedAmount}|${item.sourceText}`;
    if (seenConsecutive.has(key)) continue;
    seenConsecutive.add(key);
    uniqueItems.push(item);
  }

  if (!uniqueItems.length && summary.grandTotal == null && summary.subtotal == null) return null;
  const amountLineCount = lines.filter(line => lastAmountNearLineEnd(line)).length;
  const confidence = amountLineCount >= Math.max(3, uniqueItems.length) && uniqueItems.length >= 2 ? "medium" : "low";
  const additionalFees = dedupeAdditionalFees(summary.additionalFees || []);
  const additionalFeeSummary = summarizeAdditionalFees(additionalFees);
  const receipt = {
    merchant,
    receiptDate: null,
    currency: "USD",
    items: uniqueItems,
    subtotal: summary.subtotal,
    tax: additionalFeeSummary.tax ?? summary.tax,
    tip: additionalFeeSummary.tip ?? summary.tip,
    fees: additionalFeeSummary.fees ?? summary.fees,
    additionalFees,
    additionalFeesTotal: additionalFeeSummary.additionalFeesTotal,
    orderLevelDiscount: summary.orderLevelDiscount,
    grandTotal: summary.grandTotal,
    confidence,
    notes: `Structured annotation fallback: itemized from Mistral OCR markdown (${uniqueItems.length} item rows).`,
  };
  if (reqId) {
    console.log(`[${reqId}] Mistral OCR text fallback built ${uniqueItems.length} item(s), total=${receipt.grandTotal ?? "null"}`);
  }
  return receipt;
}

/// Does a candidate's own arithmetic hold up? Rows that sum to the printed
/// subtotal — or to the total once tax, tip and fees are accounted for — are
/// evidence the itemization is real rather than merely long.
function receiptItemsReconcile(receipt, tolerance = 0.02) {
  if (!receipt) return false;
  const normalized = normalizeParsedReceipt(receipt);
  if (!normalized) return false;
  const reconciliation = reconcileReceipt(normalized);
  const toleranceCents = Math.max(1, Math.round(tolerance * 100));
  return reconciliation.total != null
    && normalized.items.length > 0
    && Math.abs(reconciliation.gapCents) <= toleranceCents;
}

/// Whether the markdown scrape is better evidence than the model's own
/// structured read.
///
/// Row count alone used to decide this, and row count is exactly what the
/// scraper inflates: it reads any line ending in a number as an item, so
/// "Earn 5% every day  1.00" and "Rate us online  5.00" became purchases. A
/// three-item receipt scraped into six then beat the correct parse on count
/// and replaced it. Extra rows now have to add up before they count as detail.
function shouldPreferOcrTextFallback(parsed, fallback) {
  if (!fallback) return false;
  if (!parsed) return true;
  const parsedItemCount = Array.isArray(parsed.items) ? parsed.items.length : 0;
  const fallbackItemCount = Array.isArray(fallback.items) ? fallback.items.length : 0;
  if (fallbackItemCount === 0) return false;
  if (parsedItemCount === 0) return true;

  // A structured parse whose own math closes is never worth trading for a
  // regex scrape of the same page.
  if (receiptItemsReconcile(parsed)) return false;

  if (parsedItemCount <= 1 && fallbackItemCount >= 2) return true;
  if (receiptGrandTotal(parsed) == null && receiptGrandTotal(fallback) != null) return true;
  if (fallbackItemCount >= parsedItemCount + 3 && receiptItemsReconcile(fallback)) return true;
  return false;
}

function mergeStructuredSummaryIntoFallback(parsed, fallback) {
  if (!parsed || !fallback) return fallback;
  const structuredTotal = receiptGrandTotal(parsed);
  const fallbackTotal = receiptGrandTotal(fallback);
  const structuredFees = Array.isArray(parsed.additionalFees) ? parsed.additionalFees : [];

  return {
    ...fallback,
    merchantName: parsed.merchantName ?? parsed.merchant ?? fallback.merchantName ?? fallback.merchant,
    merchant: parsed.merchantName ?? parsed.merchant ?? fallback.merchant ?? "",
    receiptDate: parsed.receiptDate ?? fallback.receiptDate ?? null,
    currency: parsed.currency ?? fallback.currency ?? "USD",
    subtotal: parsed.subtotal ?? fallback.subtotal ?? null,
    tax: parsed.tax ?? fallback.tax ?? null,
    tip: parsed.tip ?? fallback.tip ?? null,
    fees: parsed.fees ?? fallback.fees ?? null,
    additionalFees: structuredFees.length ? structuredFees : (fallback.additionalFees || []),
    additionalFeesTotal: parsed.additionalFeesTotal ?? fallback.additionalFeesTotal ?? null,
    itemDiscountTotal: parsed.itemDiscountTotal ?? fallback.itemDiscountTotal ?? null,
    discount: parsed.discount ?? fallback.discount ?? null,
    orderLevelDiscount: parsed.orderLevelDiscount ?? fallback.orderLevelDiscount ?? null,
    total: structuredTotal ?? fallbackTotal,
    grandTotal: structuredTotal ?? fallbackTotal,
    confidence: parsed.confidence ?? fallback.confidence ?? "medium",
    notes: [
      parsed.notes,
      fallback.notes,
      "Used Mistral OCR text for item rows while preserving the structured annotation summary.",
    ].filter(Boolean).join(" "),
  };
}

function selectMistralReceiptCandidate(parsed, ocrText, reqId) {
  const fallback = buildReceiptFromMistralOcrText(ocrText, reqId);
  if (shouldPreferOcrTextFallback(parsed, fallback)) {
    return {
      parsed: mergeStructuredSummaryIntoFallback(parsed, fallback),
      extractionSource: parsed ? "mistral_ocr_text_fallback_preferred" : "mistral_ocr_text_fallback",
      fallback,
    };
  }
  return {
    parsed,
    extractionSource: parsed ? "mistral_structured_annotation" : "none",
    fallback,
  };
}

// ============================================================
// STAGE 2: PRIMARY OCR / STRUCTURED PARSE
// ============================================================

async function runMistralOcr({
  buffer,
  mimeType,
  reqId,
  documentAnnotationFormat,
  documentAnnotationPrompt,
  timeoutMs = MISTRAL_OCR_TIMEOUT_MS,
}) {
  console.log(`[${reqId}] Calling Mistral OCR (${mimeType})...`);

  const ocrRequest = {
    model: MISTRAL_OCR_MODEL,
    document: buildMistralDocument(buffer, mimeType),
    documentAnnotationFormat,
    documentAnnotationPrompt,
    includeBlocks: true,
  };
  if (ENABLE_MISTRAL_WORD_CONFIDENCE) {
    ocrRequest.confidenceScoresGranularity = "word";
  }

  // `timeoutMs` gives the SDK an AbortSignal, so an expired request actually
  // releases the socket. `withTimeout` alone could not do that — it raced a
  // promise and walked away, leaving the upload running against Mistral with
  // nobody waiting for it. The outer race stays as a backstop, set slightly
  // later so the abort is what normally fires.
  const result = await withTimeout(
    client.ocr.process(ocrRequest, { timeoutMs }),
    timeoutMs + 2000,
    "Mistral OCR"
  );
  console.log(`[${reqId}] Mistral OCR model requested=${MISTRAL_OCR_MODEL} returned=${result?.model || "unknown"}`);

  const pages = result.pages || [];
  const ocrText = pages.map(page => page.markdown || "").join("\n\n");
  const annotationPreview = typeof result.documentAnnotation === "string"
    ? result.documentAnnotation
    : result.documentAnnotation
      ? JSON.stringify(result.documentAnnotation)
      : "";
  console.log(`[${reqId}] Mistral OCR raw lengths: markdown=${ocrText.length} annotation=${annotationPreview.length}`);
  if (ENABLE_MISTRAL_OCR_DEBUG) {
    console.log(`[${reqId}] === RAW MISTRAL OCR MARKDOWN ===\n${ocrText}`);
    console.log(`[${reqId}] === RAW MISTRAL DOCUMENT ANNOTATION ===\n${annotationPreview || "(none)"}`);
  }

  return {
    ocrText,
    pages,
    pageCount: pages.length || 1,
    model: result?.model || MISTRAL_OCR_MODEL,
    wordConfidenceScores: ENABLE_MISTRAL_WORD_CONFIDENCE
      ? pages.flatMap(page => page.words || page.wordConfidenceScores || [])
      : [],
    lowConfidenceFields: [],
    documentAnnotation: result.documentAnnotation || null,
    result,
  };
}

async function callMistralOCR(imageBuffer, mimeType, reqId, options = {}) {
  const ocr = await runMistralOcr({
    buffer: imageBuffer,
    mimeType,
    reqId,
    documentAnnotationFormat: responseFormatFromZodObject(MistralReceiptSchema),
    documentAnnotationPrompt: EXTRACTION_PROMPT,
  });

  let parsed = null;
  try {
    parsed = parseAndValidateDocumentAnnotation(ocr.documentAnnotation, MistralReceiptSchema);
    console.log(`[${reqId}] ✓ Structured extraction successful`);
  } catch (err) {
    console.log(`[${reqId}] ⚠️ Structured extraction validation failed: ${err.message}`);
    parsed = salvageMistralReceiptAnnotation(ocr.documentAnnotation);
    if (parsed) {
      console.log(`[${reqId}] ✓ Salvaged Mistral annotation after schema validation failure (items=${parsed.items.length}, total=${parsed.grandTotal ?? "null"})`);
    }
  }

  return { parsed, ocrText: ocr.ocrText, result: ocr.result, ocr };
}

function normalizeQuickTotal(raw) {
  return {
    merchant: raw?.merchant || null,
    receiptDate: raw?.receiptDate || null,
    currency: raw?.currency || "USD",
    subtotal: toNumber(raw?.subtotal),
    tax: toNumber(raw?.tax),
    tip: toNumber(raw?.tip),
    fees: toNumber(raw?.fees),
    orderLevelDiscount: toNumber(raw?.orderLevelDiscount),
    grandTotal: toNumber(raw?.grandTotal),
    confidence: raw?.confidence || "medium",
    totalLabel: raw?.totalLabel || null,
    notes: raw?.notes || null,
  };
}

async function callMistralQuickTotal(imageBuffer, mimeType, reqId) {
  const ocr = await runMistralOcr({
    buffer: imageBuffer,
    mimeType,
    reqId,
    documentAnnotationFormat: responseFormatFromZodObject(QuickReceiptTotalSchema),
    documentAnnotationPrompt: QUICK_TOTAL_PROMPT,
    timeoutMs: QUICK_TOTAL_TIMEOUT_MS,
  });
  const parsed = parseAndValidateDocumentAnnotation(ocr.documentAnnotation, QuickReceiptTotalSchema);
  return {
    quickTotal: normalizeQuickTotal(parsed),
    ocrText: ocr.ocrText,
    result: ocr.result,
  };
}

async function parseFullReceiptResponse(buffer, mimeType, reqId, options = {}) {
  const startedAt = Date.now();
  const timings = {
    decode_ms: 0,
    temp_file_write_ms: 0,
    ocr_ms: 0,
    mistral_ocr_ms: 0,
    deterministic_cleanup_ms: 0,
    mistral_mapping_ms: 0,
    contradiction_resolution_ms: 0,
    reconciliation_ms: 0,
    total_ms: 0,
  };

  const ocrStart = Date.now();
  let { parsed, ocrText, result } = await callMistralOCR(buffer, mimeType, reqId, options);
  const candidateSelection = selectMistralReceiptCandidate(parsed, ocrText, reqId);
  parsed = candidateSelection.parsed;
  timings.ocr_ms = Date.now() - ocrStart;
  timings.mistral_ocr_ms = timings.ocr_ms;

  let normalized = null;
  let resolutionResult = {
    receipt: null,
    selectedCandidate: "not_run",
    candidatesTried: 0,
    suspicious: [],
    changes: [],
    allCandidates: [],
  };

  if (parsed) {
    const deterministicCleanupStart = Date.now();
    normalized = normalizeParsedReceipt(parsed);
    normalized.notes = [
      normalized.notes,
      candidateSelection.extractionSource === "mistral_ocr_text_fallback_preferred"
        ? "Structured annotation was under-itemized; used Mistral OCR markdown fallback itemization."
        : candidateSelection.extractionSource === "mistral_ocr_text_fallback"
          ? "Structured annotation unavailable; used Mistral OCR markdown fallback itemization."
          : null,
    ].filter(Boolean).join(" ") || normalized.notes;
    timings.deterministic_cleanup_ms = Date.now() - deterministicCleanupStart;
    timings.mistral_mapping_ms = timings.deterministic_cleanup_ms;
    resolutionResult.receipt = normalized;
    normalized = applyFastLocalNormalization(normalized);

    const contradictionStart = Date.now();
    resolutionResult = resolveFinancialContradictions(normalized, reqId, {
      ocrText,
    });
    normalized = preserveAnnotationGrandTotal(
      resolutionResult.receipt,
      result?.documentAnnotation,
      reqId
    );
    timings.contradiction_resolution_ms = Date.now() - contradictionStart;
    resolutionResult.receipt = normalized;
  }

  const reconciliationStart = Date.now();
  const reconciliation = normalized ? reconcileReceipt(normalized) : {
    itemSum: null,
    subtotalGap: null,
    totalGap: null,
    calculatedFromItems: null,
    calculatedFromSubtotal: null,
    mathCheckPassed: false,
    mismatchReasons: ["no_data_extracted"],
    itemBreakdown: [],
  };
  timings.reconciliation_ms = Date.now() - reconciliationStart;
  timings.total_ms = Date.now() - startedAt;

  return buildApiResponse(
    { parsed: normalized, ocrText, result, reconciliation, rejected: [], resolutionResult, uploadDiagnostics: options.uploadDiagnostics || null },
    timings,
    reqId
  );
}

// ============================================================
// STAGE 3: DETERMINISTIC RECEIPT NORMALIZATION
// ============================================================

function normalizeParsedReceipt(parsed) {
  if (!parsed) return null;
  const allCharges = normalizeAdditionalFees(parsed.additionalFees);
  const chargeSummary = summarizeAdditionalFees(allCharges);
  const additionalFees = allCharges
    .filter(fee => !fee.isTax && !isTaxFeeType(fee.feeType))
    .filter(fee => !fee.isTipOrGratuity && !isTipOrGratuityFeeType(fee.feeType))
    .map(fee => {
      const name = fee.feeName || fee.feeLabel || "Fee";
      const amount = centsToMoney(moneyToCents(fee.amount));
      return { name, amount, feeName: name, feeLabel: name, feeValue: amount };
    });
  const explicitTax = toNumber(parsed.tax);
  const explicitTip = toNumber(parsed.tip);
  const legacyFee = toNumber(parsed.fees);
  if (!additionalFees.length && legacyFee > 0) {
    const amount = centsToMoney(moneyToCents(legacyFee));
    additionalFees.push({ name: "Fee", amount, feeName: "Fee", feeLabel: "Fee", feeValue: amount });
  }

  let items = (parsed.items || [])
    .map(item => {
      const name = normalizeItemName(item.itemName ?? item.name);
      const hasFinalItemValue = item.itemValue != null;
      let amountCents = moneyToCents(item.itemValue ?? item.amount ?? item.printedAmount);
      const discountCents = moneyToCents(item.discountAmount);
      if (!hasFinalItemValue && amountCents != null && discountCents > 0) {
        amountCents = Math.max(0, amountCents - discountCents);
      }
      const amount = centsToMoney(amountCents);
      return {
        name,
        amount,
        printedAmount: amount,
        originalAmount: toNumber(item.originalItemValue ?? item.originalAmount),
        itemDiscount: toNumber(item.discountAmount ?? item.itemDiscount),
        discountLabel: item.discountLabel ?? item.itemDiscountLabel ?? null,
        sourceText: item.sourceText ?? null,
        itemCode: item.itemCode ?? null,
        qty: toNumber(item.qty),
        unitPrice: toNumber(item.unitPrice),
        weightLbs: toNumber(item.weightLbs),
        confidence: parsed.confidence || "medium",
      };
    })
    .filter(item => item.amount >= 0.01 && item.name && (item.name.length < 2 || !isLikelyNonItemRow(item.name)));

  const total = receiptGrandTotal(parsed);
  const tax = centsToMoney(moneyToCents(explicitTax > 0 ? explicitTax : chargeSummary.tax ?? explicitTax ?? 0));
  const tip = centsToMoney(moneyToCents(explicitTip > 0 ? explicitTip : chargeSummary.tip ?? explicitTip ?? 0));
  const orderDiscountCents = moneyToCents(parsed.orderLevelDiscount) || 0;
  let orderDiscountAllocation = null;
  if (orderDiscountCents > 0 && items.length > 0) {
    const itemCents = items.map(item => moneyToCents(item.amount) || 0);
    const feeCents = additionalFees.reduce((sum, fee) => sum + (moneyToCents(fee.amount) || 0), 0);
    const preDiscountCalculated = itemCents.reduce((sum, cents) => sum + cents, 0)
      + (moneyToCents(tax) || 0) + (moneyToCents(tip) || 0) + feeCents;
    const totalCents = moneyToCents(total);
    const needsAllocation = totalCents == null || preDiscountCalculated - orderDiscountCents === totalCents;
    const itemSumCents = itemCents.reduce((sum, cents) => sum + cents, 0);
    if (needsAllocation && orderDiscountCents < itemSumCents) {
      const shares = itemCents.map((cents, index) => {
        const exactNumerator = orderDiscountCents * cents;
        return { index, cents: Math.floor(exactNumerator / itemSumCents), remainder: exactNumerator % itemSumCents };
      });
      let remaining = orderDiscountCents - shares.reduce((sum, share) => sum + share.cents, 0);
      [...shares]
        .sort((a, b) => b.remainder - a.remainder || a.index - b.index)
        .forEach(share => {
          if (remaining > 0) {
            shares[share.index].cents += 1;
            remaining -= 1;
          }
        });
      items = items.map((item, index) => ({
        ...item,
        amount: centsToMoney(itemCents[index] - shares[index].cents),
        printedAmount: centsToMoney(itemCents[index] - shares[index].cents),
        discountLabel: [item.discountLabel, shares[index].cents > 0 ? "Order discount applied" : null]
          .filter(Boolean).join("; ") || null,
      }));
      orderDiscountAllocation = centsToMoney(orderDiscountCents);
    }
  }

  return {
    merchant: normalizeMerchant(parsed.merchantName ?? parsed.merchant),
    receiptDate: parsed.receiptDate || null,
    currency: parsed.currency || "USD",
    items,
    subtotal: toNumber(parsed.subtotal),
    tax,
    tip,
    additionalFees,
    fees: centsToMoney(additionalFees.reduce((sum, fee) => sum + (moneyToCents(fee.amount) || 0), 0)),
    additionalFeesTotal: centsToMoney(additionalFees.reduce((sum, fee) => sum + (moneyToCents(fee.amount) || 0), 0)),
    total,
    grandTotal: total,
    orderDiscountAllocation,
    confidence: parsed.confidence || "medium",
    notes: parsed.notes || null,
  };
}

// ============================================================
// STAGE 3B: NON-ITEM ROW GUARD + DISCOUNT MODE RESOLUTION
// ============================================================

/// Whether a row the model returned as an item is really a summary line.
///
/// Shares one anchored label table with `summaryRoleForLine`, so the guard on
/// the structured path and the guard on the markdown-scrape path cannot drift
/// apart — they were previously two separate keyword lists with two separate
/// versions of the same bug.
function isLikelyNonItemRow(name) {
  const lower = String(name || "").toLowerCase().trim();
  if (lower.length < 2) return true;

  if (isLikelySuggestedTipRowText(lower)) return true;
  if (/^\s*(?:[1-4]?\d|50)\s*%/.test(lower)) return true;
  return summaryRoleForLabel(lower) !== null;
}

function stripNonItemRows(items, reqId) {
  const kept = [];
  const dropped = [];
  for (const item of items || []) {
    if (isLikelyNonItemRow(item.name) || item.printedAmount == null || item.printedAmount < 0.01) {
      dropped.push(item);
    } else {
      kept.push(item);
    }
  }
  if (dropped.length && reqId) {
    console.log(`[${reqId}] Stripped ${dropped.length} non-item row(s): ${dropped.map(d => d.name).join(", ")}`);
  }
  return { kept, dropped };
}

function suppressUnchargedSuggestedTip(receipt, reqId) {
  const tip = receipt.tip ?? 0;
  const grandTotal = receipt.grandTotal;
  if (!(tip > 0) || grandTotal == null) {
    return { receipt, suppressed: false, reason: null };
  }

  const itemSum = round2((receipt.items || []).reduce((sum, item) => sum + (item.amount || item.printedAmount || 0), 0));
  const basis = receipt.subtotal != null ? receipt.subtotal : (itemSum > 0 ? itemSum : null);
  if (basis == null) {
    return { receipt, suppressed: false, reason: null };
  }

  const tax = receipt.tax ?? 0;
  const fees = receipt.fees ?? 0;
  const orderDiscount = receipt.orderLevelDiscount ?? 0;
  const totalWithoutTip = round2(basis + tax + fees - orderDiscount);
  const totalWithTip = round2(totalWithoutTip + tip);
  const withoutTipGap = round2(Math.abs(totalWithoutTip - grandTotal));
  const withTipGap = round2(Math.abs(totalWithTip - grandTotal));

  if (withoutTipGap <= 0.03 && withTipGap > 0.03) {
    const additionalFees = removeTipAdditionalFees(receipt.additionalFees);
    const additionalFeeSummary = summarizeAdditionalFees(additionalFees);
    const nextReceipt = {
      ...receipt,
      tip: 0,
      additionalFees,
      additionalFeesTotal: additionalFeeSummary.additionalFeesTotal,
      notes: [
        receipt.notes,
        `Ignored likely suggested tip $${tip.toFixed(2)} because the charged total already reconciles without tip.`,
      ].filter(Boolean).join(" "),
    };
    if (reqId) {
      console.log(`[${reqId}] Suppressed uncharged suggested tip $${tip.toFixed(2)}; total_without_tip=${totalWithoutTip.toFixed(2)} grand_total=${grandTotal.toFixed(2)}`);
    }
    return {
      receipt: nextReceipt,
      suppressed: true,
      reason: `Ignored likely suggested tip $${tip.toFixed(2)}; charged total reconciles without tip.`,
    };
  }

  return { receipt, suppressed: false, reason: null };
}

function mergeStrayDuplicateRows(items, reqId) {
  const groups = new Map();
  items.forEach((item, idx) => {
    const key = item.name.trim().toLowerCase();
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push({ item, idx });
  });

  const foldedAwayIdx = new Set();
  const extraDiscountByIdx = new Map();

  for (const group of groups.values()) {
    const foldable = group.filter(({ item }) =>
      item.weightLbs == null &&
      (item.qty == null || item.qty === 1) &&
      (item.discountAmount ?? 0) === 0 &&
      item.printedAmount > 0
    );
    if (foldable.length < 2) continue;

    foldable.sort((a, b) => b.item.printedAmount - a.item.printedAmount);
    const keeper = foldable[0];
    const foldedEvidence = new Set();
    for (const stray of foldable.slice(1)) {
      const evidenceKey = [
        stray.item.name.trim().toLowerCase(),
        round2(stray.item.printedAmount).toFixed(2),
        String(stray.item.sourceText || "").trim().toLowerCase(),
      ].join("|");
      if (foldedEvidence.has(evidenceKey)) {
        foldedAwayIdx.add(stray.idx);
        if (reqId) {
          console.log(`[${reqId}] Ignored duplicate stray discount evidence "${stray.item.name}" ($${stray.item.printedAmount})`);
        }
        continue;
      }
      foldedEvidence.add(evidenceKey);
      foldedAwayIdx.add(stray.idx);
      extraDiscountByIdx.set(keeper.idx, (extraDiscountByIdx.get(keeper.idx) || 0) + stray.item.printedAmount);
      if (reqId) {
        console.log(`[${reqId}] Folded stray row "${stray.item.name}" ($${stray.item.printedAmount}) into a discount on "${keeper.item.name}" ($${keeper.item.printedAmount})`);
      }
    }
  }

  if (foldedAwayIdx.size === 0) return { items, changes: [] };

  const changes = [];
  const result = [];
  items.forEach((item, idx) => {
    if (foldedAwayIdx.has(idx)) return;
    const extra = extraDiscountByIdx.get(idx);
    if (extra) {
      changes.push(`Merged duplicate ${item.name} row as $${round2(extra).toFixed(2)} item discount`);
      result.push({
        ...item,
        discountAmount: round2((item.discountAmount ?? 0) + extra),
        discountLabel: item.discountLabel || "Savings (merged duplicate line)",
      });
    } else {
      result.push(item);
    }
  });
  return { items: result, changes };
}

// ============================================================
// STAGE 4: RECONCILIATION ENGINE
// ============================================================

function reconcileReceipt(normalized) {
  const items = normalized.items || [];
  const itemCents = items.reduce((sum, item) => sum + (moneyToCents(item.amount) || 0), 0);
  const taxCents = moneyToCents(normalized.tax) || 0;
  const tipCents = moneyToCents(normalized.tip) || 0;
  const additionalFeeCents = (normalized.additionalFees || [])
    .reduce((sum, fee) => sum + (moneyToCents(fee.amount) || 0), 0);
  const calculatedCents = itemCents + taxCents + tipCents + additionalFeeCents;
  const totalCents = moneyToCents(normalized.total ?? normalized.grandTotal);
  const gapCents = totalCents == null ? null : totalCents - calculatedCents;
  const mathCheckPassed = totalCents > 0 && items.length > 0 && Math.abs(gapCents) <= 1;

  const mismatchReasons = [];
  if (gapCents != null && Math.abs(gapCents) > 1) {
    mismatchReasons.push(`total_gap_${gapCents}_cents`);
  }
  if (!(totalCents > 0)) {
    mismatchReasons.push("no_grand_total");
  }
  if (items.length === 0) {
    mismatchReasons.push("no_items_extracted");
  }

  const itemBreakdown = items.map((item, idx) => {
    const parts = [];
    parts.push(`${item.name}: $${Number(item.amount || 0).toFixed(2)}`);
    
    if (item.qty != null) parts.push(`qty=${item.qty}`);
    if (item.unitPrice != null) parts.push(`unit=$${item.unitPrice.toFixed(2)}`);
    if (item.weightLbs != null) parts.push(`weight=${item.weightLbs}lb`);
    if (item.originalAmount != null) parts.push(`original=$${item.originalAmount.toFixed(2)}`);
    if (item.itemDiscount != null && item.itemDiscount > 0) parts.push(`item_discount=$${item.itemDiscount.toFixed(2)}`);
    
    return `  ${idx + 1}. ${parts.join(", ")}`;
  });

  return {
    itemSum: centsToMoney(itemCents),
    tax: centsToMoney(taxCents),
    tip: centsToMoney(tipCents),
    additionalFeeSum: centsToMoney(additionalFeeCents),
    calculatedTotal: centsToMoney(calculatedCents),
    total: centsToMoney(totalCents),
    gapCents,
    subtotalGap: null,
    totalGap: gapCents == null ? null : centsToMoney(Math.abs(gapCents)),
    calculatedFromItems: centsToMoney(calculatedCents),
    calculatedFromSubtotal: null,
    mathCheckPassed,
    mismatchReasons,
    itemBreakdown,
  };
}

function applyDiscountMode(items, mode) {
  return items.map(item => {
    const discount = item.discountAmount ?? 0;
    if (discount <= 0) {
      return {
        ...item,
        amount: round2(item.printedAmount),
        originalAmount: null,
        itemDiscount: null,
        itemDiscountLabel: null,
      };
    }

    if (mode === "printed_before_discount") {
      return {
        ...item,
        amount: round2(Math.max(0, item.printedAmount - discount)),
        originalAmount: round2(item.printedAmount),
        itemDiscount: round2(discount),
        itemDiscountLabel: item.discountLabel || null,
      };
    }

    return {
      ...item,
      amount: round2(item.printedAmount),
      originalAmount: round2(item.printedAmount + discount),
      itemDiscount: round2(discount),
      itemDiscountLabel: item.discountLabel || null,
    };
  });
}

function buildDiscountModeCandidate(normalized, itemMode, orderDiscountMode = "order_discount_applied", changes = []) {
  const visibleOrderDiscount = normalized.orderLevelDiscount ?? 0;
  const orderDiscountAlreadyReflected = visibleOrderDiscount > 0 && orderDiscountMode === "order_discount_already_reflected";
  const receipt = {
    ...normalized,
    items: applyDiscountMode(normalized.items || [], itemMode),
    orderLevelDiscount: orderDiscountAlreadyReflected ? 0 : normalized.orderLevelDiscount,
  };
  const reconciliation = reconcileReceipt(receipt);
  const subtotalPenalty = reconciliation.subtotalGap ?? 0;
  const totalPenalty = reconciliation.totalGap ?? (normalized.grandTotal == null ? 0 : 999);
  const noGrandTotalPenalty = normalized.grandTotal == null ? 0.05 : 0;
  const score = round2(totalPenalty + subtotalPenalty * 0.5 + noGrandTotalPenalty - (reconciliation.mathCheckPassed ? 0.01 : 0));
  const label = visibleOrderDiscount > 0
    ? `${itemMode}__${orderDiscountMode}`
    : itemMode;

  return {
    label,
    itemMode,
    orderDiscountMode,
    visibleOrderDiscount,
    receipt,
    changes,
    reconciliation,
    score,
  };
}

function receiptCandidateSignature(receipt) {
  const summary = [
    receipt?.merchant || "",
    receipt?.subtotal ?? "",
    receipt?.tax ?? "",
    receipt?.tip ?? "",
    receipt?.fees ?? "",
    receipt?.orderLevelDiscount ?? "",
    receipt?.grandTotal ?? "",
  ].join("|");
  const items = (receipt?.items || []).map(receiptItemSignature).join(";");
  return `${summary}|${items}`;
}

function itemEvidenceSupport(item, evidenceLines, localItems) {
  let score = 0;
  const sources = new Set();
  for (const evidence of evidenceLines) {
    if (!evidence.itemLike || !itemMatchesEvidence(item, evidence)) continue;
    score += evidence.source === "apple" ? 3 : 3;
    sources.add(evidence.source);
  }
  for (const localItem of localItems) {
    if (moneyToCents(item.amount ?? item.printedAmount) !== localItem.cents) continue;
    if (tokenOverlapRatio(item.name || item.rawName, localItem.name) < 0.5) continue;
    score += 2;
    sources.add(localItem.source);
  }
  if (sources.size >= 2) score += 2;
  return score;
}

function summaryEvidenceSupport(receipt, evidenceLines) {
  let score = 0;
  const addSupport = (field, roles, strongRoles = roles) => {
    const cents = moneyToCents(receipt?.[field]);
    if (cents == null) return;
    const matches = evidenceLines.filter(line => line.cents === cents && roles.includes(line.role));
    if (!matches.length) return;
    score += strongRoles.some(role => matches.some(line => line.role === role)) ? 8 : 4;
  };
  addSupport("subtotal", ["subtotal"]);
  addSupport("tax", ["tax"]);
  addSupport("tip", ["tip"]);
  addSupport("fees", ["fees"]);
  addSupport("orderLevelDiscount", ["orderLevelDiscount"]);
  addSupport("grandTotal", ["grandTotal"]);

  const totalCents = moneyToCents(receipt?.grandTotal);
  if (totalCents != null) {
    const netOnly = evidenceLines.some(line => line.cents === totalCents && (line.netSalesLike || line.netTotalLike));
    const explicitTotal = evidenceLines.some(line => line.cents === totalCents && line.role === "grandTotal" && !line.netSalesLike && !line.netTotalLike);
    if (explicitTotal) score += 10;
    if (netOnly && !explicitTotal) score -= 35;
  }
  return score;
}

function duplicateItemPenalty(items) {
  const seen = new Map();
  let penalty = 0;
  for (const item of items || []) {
    const key = receiptItemSignature(item);
    seen.set(key, (seen.get(key) || 0) + 1);
  }
  for (const count of seen.values()) {
    if (count > 1) penalty += (count - 1) * 8;
  }
  return penalty;
}

function scoreReceiptCandidate(receipt, evidenceLines, localItems, label) {
  const reconciliation = reconcileReceipt(receipt);
  let score = 0;
  const reasons = [];
  const itemCount = receipt?.items?.length || 0;

  if (itemCount > 0) {
    score += 12 + Math.min(itemCount, 20) * 1.5;
    reasons.push(`items=${itemCount}`);
  } else {
    score -= 35;
    reasons.push("no_items");
  }

  if (reconciliation.subtotalGap != null) {
    const cents = moneyToCents(reconciliation.subtotalGap) ?? 99999;
    if (cents <= 1) {
      score += 55;
      reasons.push("item_sum_matches_subtotal");
    } else {
      score -= Math.min(55, cents / 20);
      reasons.push(`subtotal_gap=${centsToMoney(cents)}`);
    }
  }

  if (reconciliation.totalGap != null) {
    const cents = moneyToCents(reconciliation.totalGap) ?? 99999;
    if (cents <= 1) {
      score += 65;
      reasons.push("summary_math_matches_total");
    } else {
      score -= Math.min(70, cents / 15);
      reasons.push(`total_gap=${centsToMoney(cents)}`);
    }
  } else if (receipt?.grandTotal == null) {
    score -= 12;
    reasons.push("no_grand_total");
  }

  const supportedItemCount = (receipt?.items || []).reduce((count, item) => {
    const support = itemEvidenceSupport(item, evidenceLines, localItems);
    score += Math.min(8, support);
    return count + (support > 0 ? 1 : 0);
  }, 0);
  if (itemCount > 0 && supportedItemCount === 0) {
    score -= 20;
    reasons.push("no_item_ocr_support");
  } else if (supportedItemCount > 0) {
    reasons.push(`supported_items=${supportedItemCount}`);
  }

  score += summaryEvidenceSupport(receipt, evidenceLines);
  const nonItems = (receipt?.items || []).filter(item => isLikelyNonItemRow(item.name)).length;
  if (nonItems) {
    score -= nonItems * 20;
    reasons.push(`non_item_rows=${nonItems}`);
  }
  const dupPenalty = duplicateItemPenalty(receipt?.items || []);
  if (dupPenalty) {
    score -= dupPenalty;
    reasons.push(`duplicate_penalty=${dupPenalty}`);
  }

  if (reconciliation.mathCheckPassed) score += 20;
  return {
    label,
    score: round2(score),
    receipt,
    reconciliation,
    reasons,
  };
}

function findReplacementRepair(receipt, gapCents, evidenceLines, localItems) {
  if (!gapCents) return null;
  for (const [index, item] of (receipt.items || []).entries()) {
    const currentCents = moneyToCents(item.amount ?? item.printedAmount);
    if (currentCents == null) continue;
    const desiredCents = currentCents + gapCents;
    if (desiredCents <= 0 || desiredCents === currentCents) continue;

    const ocrEvidence = evidenceLines.find(line =>
      line.itemLike &&
      line.cents === desiredCents &&
      tokenOverlapRatio(item.name || item.rawName, line.name || line.line) >= 0.5
    );
    const localEvidence = localItems.find(localItem =>
      localItem.cents === desiredCents &&
      tokenOverlapRatio(item.name || item.rawName, localItem.name) >= 0.5
    );
    const evidence = ocrEvidence || localEvidence;
    if (!evidence) continue;

    const repairedItems = receipt.items.map((candidateItem, candidateIndex) => {
      if (candidateIndex !== index) return candidateItem;
      const nextAmount = centsToMoney(desiredCents);
      return {
        ...candidateItem,
        printedAmount: nextAmount,
        amount: nextAmount,
        sourceText: [candidateItem.sourceText, evidence.line || evidence.source].filter(Boolean).join("\n"),
      };
    });
    return {
      receipt: { ...receipt, items: repairedItems },
      change: `Corrected "${item.name}" from $${centsToMoney(currentCents).toFixed(2)} to $${centsToMoney(desiredCents).toFixed(2)} using ${evidence.source || "local"} evidence.`,
    };
  }
  return null;
}

function findMissingItemRepair(receipt, gapCents, evidenceLines, localItems) {
  if (!gapCents || gapCents <= 0) return null;

  const ocrEvidence = evidenceLines.find(line =>
    line.itemLike &&
    line.cents === gapCents &&
    !receiptHasEquivalentItem(receipt, line.name, line.amount)
  );
  const localEvidence = localItems.find(item =>
    item.cents === gapCents &&
    !receiptHasEquivalentItem(receipt, item.name, item.amount)
  );
  const evidence = ocrEvidence || localEvidence;
  if (!evidence) return null;

  const amount = centsToMoney(gapCents);
  const name = normalizeItemName(evidence.name || "Unknown Item");
  if (!name || isLikelyNonItemRow(name)) return null;

  return {
    receipt: {
      ...receipt,
      items: [
        ...(receipt.items || []),
        {
          name,
          rawName: name,
          normalizedName: applySafeLocalItemNameCleanup(name),
          normalizationSource: "local",
          normalizationConfidence: 0.75,
          normalizationAmbiguous: false,
          needsNameVerification: false,
          possibleNameAlternatives: [],
          normalizationReason: "Added from unused OCR/local evidence during arithmetic repair.",
          category: inferFallbackItemCategory(name),
          categoryConfidence: 0.45,
          categoryReason: "Category inferred locally from repaired item text.",
          printedAmount: amount,
          amount,
          originalAmount: null,
          itemDiscount: null,
          itemDiscountLabel: null,
          discountAmount: null,
          discountLabel: null,
          qty: null,
          unitPrice: null,
          weightLbs: null,
          confidence: "medium",
          sourceText: evidence.line || evidence.source || "local evidence",
        },
      ],
    },
    change: `Added missing item "${name}" for $${amount.toFixed(2)} using ${evidence.source || "local"} evidence.`,
  };
}

function buildTargetedRepairCandidates(receipt, evidenceOptions, evidenceLines, localItems) {
  const target = merchandiseTargetFromEvidence(receipt, evidenceOptions.localHints);
  if (!target) return [];
  const itemSumCents = moneyToCents((receipt.items || []).reduce((sum, item) => sum + (item.amount || 0), 0));
  if (itemSumCents == null) return [];
  const gapCents = target.cents - itemSumCents;
  if (!gapCents || Math.abs(gapCents) <= 1) return [];
  if (Math.abs(gapCents) > 50000) return [];

  const repairs = [];
  const replacement = findReplacementRepair(receipt, gapCents, evidenceLines, localItems);
  if (replacement) repairs.push({ ...replacement, kind: "amount_replacement", targetSource: target.source });

  const missing = findMissingItemRepair(receipt, gapCents, evidenceLines, localItems);
  if (missing) repairs.push({ ...missing, kind: "missing_item", targetSource: target.source });
  return repairs;
}

function arbitrateReceiptCandidates(baseReceipt, evidenceOptions, reqId, baseChanges = [], baseSuspicious = []) {
  const evidenceLines = extractReceiptMoneyEvidence({
    ocrText: evidenceOptions?.ocrText || "",
    appleOcrText: evidenceOptions?.appleOcrText || "",
  });
  const localItems = localEvidenceItems(evidenceOptions?.localParseResult, evidenceOptions?.localCandidates);
  const localSummary = summaryFieldsFromLocalEvidence(evidenceOptions?.localHints, evidenceOptions?.localParseResult);
  const candidates = [];
  const seen = new Set();

  const addCandidate = (label, receipt, changes = []) => {
    if (!receipt) return;
    const key = receiptCandidateSignature(receipt);
    if (seen.has(key)) return;
    seen.add(key);
    candidates.push({
      label,
      receipt,
      changes,
      score: scoreReceiptCandidate(receipt, evidenceLines, localItems, label),
    });
  };

  addCandidate("mistral_cleaned", baseReceipt, baseChanges);

  const localParsed = buildParsedReceiptFromLocalParse(evidenceOptions?.localParseResult);
  if (localParsed) {
    const normalizedLocal = applyFastLocalNormalization(normalizeParsedReceipt(localParsed));
    const cleanedLocal = cleanReceiptForCandidate(normalizedLocal, reqId);
    addCandidate("local_parser_hypothesis", cleanedLocal.receipt, cleanedLocal.changes);
  }

  if (Object.keys(localSummary).length) {
    addCandidate("mistral_items_local_summary", {
      ...baseReceipt,
      ...localSummary,
      notes: [baseReceipt.notes, "Trusted local summary fields considered by backend arbitration."].filter(Boolean).join(" "),
    }, ["Combined Mistral items with supported local summary fields."]);
  }

  if (localParsed) {
    const localItemsOnly = cleanReceiptForCandidate(applyFastLocalNormalization(normalizeParsedReceipt({
      ...localParsed,
      merchant: localParsed.merchant || baseReceipt.merchant,
      subtotal: baseReceipt.subtotal,
      tax: baseReceipt.tax,
      tip: baseReceipt.tip,
      fees: baseReceipt.fees,
      orderLevelDiscount: baseReceipt.orderLevelDiscount,
      grandTotal: baseReceipt.grandTotal,
      confidence: baseReceipt.confidence,
    })), reqId);
    addCandidate("local_items_mistral_summary", localItemsOnly.receipt, localItemsOnly.changes);
  }

  for (const repair of buildTargetedRepairCandidates(baseReceipt, evidenceOptions || {}, evidenceLines, localItems)) {
    addCandidate(`repaired_${repair.kind}`, {
      ...repair.receipt,
      notes: [repair.receipt.notes, repair.change].filter(Boolean).join(" "),
    }, [repair.change]);
  }

  if (!candidates.length) {
    return {
      receipt: baseReceipt,
      selectedCandidate: "mistral_cleaned",
      candidatesTried: 1,
      suspicious: baseSuspicious,
      changes: baseChanges,
      allCandidates: [],
    };
  }

  candidates.sort((a, b) => b.score.score - a.score.score);
  const selected = candidates[0];
  const selectedReconciliation = selected.score.reconciliation;
  if (RECEIPT_ARBITRATION_DEBUG && reqId) {
    console.log(`[${reqId}] Receipt arbitration candidates:`);
    for (const candidate of candidates) {
      console.log(`[${reqId}]   - ${candidate.label}: score=${candidate.score.score} math=${candidate.score.reconciliation.mathCheckPassed ? "pass" : "fail"} reasons=${candidate.score.reasons.join(",")}`);
    }
    console.log(`[${reqId}] Receipt arbitration selected: ${selected.label}`);
  }

  return {
    receipt: selected.receipt,
    selectedCandidate: selected.label,
    candidatesTried: candidates.length,
    suspicious: baseSuspicious,
    changes: selected.changes,
    selectedScore: selected.score.score,
    selectedReasons: selected.score.reasons,
    allCandidates: candidates.map(candidate => ({
      label: candidate.label,
      receipt: candidate.receipt,
      reconciliation: candidate.score.reconciliation,
      score: candidate.score.score,
      reasons: candidate.score.reasons,
    })),
    finalReconciliation: selectedReconciliation,
  };
}

function resolveFinancialContradictions(normalized, reqId, evidenceOptions = {}) {
  console.log(`[${reqId}] Preserving canonical Mistral accounting values...`);
  const requiresBoundaryNormalization = (normalized?.items || []).some(item => moneyToCents(item.amount) == null);
  const receipt = requiresBoundaryNormalization
    ? normalizeParsedReceipt({
        ...normalized,
        merchantName: normalized.merchantName ?? normalized.merchant,
        items: (normalized.items || []).map(item => ({
          ...item,
          itemName: item.itemName ?? item.name,
          itemValue: item.itemValue ?? item.amount ?? item.printedAmount,
        })),
        total: normalized.total ?? normalized.grandTotal,
      })
    : normalized;
  const changes = ["No post-normalization financial repairs were applied."];
  const reconciliation = reconcileReceipt(receipt);
  if (!reconciliation.mathCheckPassed && reconciliation.mismatchReasons.length > 0) {
    receipt.notes = [
      receipt.notes,
      "Canonical receipt math did not reconcile; manual review is required.",
    ].filter(Boolean).join(" ");
  }

  console.log(`[${reqId}] Canonical receipt kept ${receipt.items?.length || 0} item(s); math=${reconciliation.mathCheckPassed ? "✓" : "✗"}`);

  return {
    receipt,
    selectedCandidate: "simple_final_amounts",
    candidatesTried: 1,
    suspicious: [],
    changes,
    selectedScore: reconciliation.totalGap ?? 0,
    selectedReasons: reconciliation.mathCheckPassed ? ["canonical_receipt_reconciles"] : reconciliation.mismatchReasons,
    allCandidates: [{
      label: "simple_final_amounts",
      receipt,
      reconciliation,
      score: reconciliation.totalGap ?? 0,
    }],
  };
}

// ============================================================
// STAGE 9: ITEM NAME NORMALIZATION
// ============================================================

const ITEM_NAME_NORMALIZATION_MODEL = "ministral-14b-latest";
const ITEM_NAME_NORMALIZATION_TIMEOUT_MS = 6000;

function withTimeout(promise, timeoutMs, label) {
  let timeoutId;
  const timeout = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      const error = new Error(`${label} timed out after ${timeoutMs}ms`);
      error.code = label.toLowerCase().includes("ocr") ? "MISTRAL_TIMEOUT" : "TIMEOUT";
      reject(error);
    }, timeoutMs);
  });

  return Promise.race([promise, timeout]).finally(() => clearTimeout(timeoutId));
}

function delayMs(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function fallbackNameNormalization(receipt) {
  return {
    ...receipt,
    items: (receipt.items || []).map(item => {
      const fallbackName = item.normalizedName || item.name;
      return {
        ...item,
        rawName: item.rawName || item.name,
        normalizedName: fallbackName,
        normalizationSource: item.normalizationSource || "fallback",
        normalizationConfidence: item.normalizationConfidence ?? 0,
        normalizationAmbiguous: item.normalizationAmbiguous ?? true,
        needsNameVerification: item.needsNameVerification ?? true,
        possibleNameAlternatives: item.possibleNameAlternatives ?? [],
        normalizationReason: item.normalizationReason || "Normalization unavailable; preserved raw receipt text.",
        category: item.category || inferFallbackItemCategory(fallbackName),
        categoryConfidence: item.categoryConfidence ?? 0.35,
        categoryReason: item.categoryReason || "Fallback category inferred from raw receipt text.",
      };
    }),
  };
}

function validateItemNameNormalizationResponse(response, inputCount) {
  const parsed = ItemNameNormalizationResponseSchema.parse(response);

  if (parsed.items.length !== inputCount) {
    throw new Error(`Expected ${inputCount} normalized items, received ${parsed.items.length}`);
  }

  const seen = new Set();
  for (const item of parsed.items) {
    if (item.index < 0 || item.index >= inputCount) {
      throw new Error(`Unexpected normalized item index: ${item.index}`);
    }
    if (seen.has(item.index)) {
      throw new Error(`Duplicate normalized item index: ${item.index}`);
    }
    seen.add(item.index);
  }

  for (let i = 0; i < inputCount; i++) {
    if (!seen.has(i)) {
      throw new Error(`Missing normalized item index: ${i}`);
    }
  }

  return parsed;
}

async function normalizeItemNamesWithMistral(receipt, reqId) {
  if (!receipt?.items?.length) {
    return receipt;
  }

  const startedAt = Date.now();
  console.log(`[${reqId}] Starting item-name normalization pass...`);
  console.log(`[${reqId}]   - Model: ${ITEM_NAME_NORMALIZATION_MODEL}`);
  console.log(`[${reqId}]   - Items sent: ${receipt.items.length}`);

  const payload = {
    merchant: receipt.merchant,
    items: receipt.items.map((item, index) => ({
      index,
      raw_name: item.name,
      item_code: item.itemCode ?? null,
      price: item.amount,
    })),
  };

  try {
    const completion = await withTimeout(
      client.chat.parse({
        model: ITEM_NAME_NORMALIZATION_MODEL,
        messages: [
          { role: "system", content: ITEM_NAME_NORMALIZATION_PROMPT },
          { role: "user", content: JSON.stringify(payload) },
        ],
        temperature: 0,
        responseFormat: ItemNameNormalizationResponseSchema,
      }),
      ITEM_NAME_NORMALIZATION_TIMEOUT_MS,
      "Item-name normalization"
    );

    const message = completion.choices?.[0]?.message;
    const rawResponse = message?.parsed ?? JSON.parse(message?.content || "{}");
    const validated = validateItemNameNormalizationResponse(rawResponse, receipt.items.length);
    const byIndex = new Map(validated.items.map(item => [item.index, item]));

    const normalizedReceipt = {
      ...receipt,
      items: receipt.items.map((item, index) => {
        const aiResult = byIndex.get(index);
        return {
          ...item,
          rawName: item.name,
          normalizedName: aiResult.normalizedName,
          normalizationSource: "mistral",
          normalizationConfidence: aiResult.confidence,
          normalizationAmbiguous: aiResult.ambiguous,
          needsNameVerification: aiResult.needsVerification,
          possibleNameAlternatives: aiResult.possibleAlternatives,
          normalizationReason: aiResult.reason,
          category: aiResult.category,
          categoryConfidence: aiResult.categoryConfidence,
          categoryReason: aiResult.categoryReason,
        };
      }),
    };

    console.log(`[${reqId}] ✓ Item-name normalization complete in ${Date.now() - startedAt}ms (fallback=false)`);
    return normalizedReceipt;
  } catch (error) {
    console.log(`[${reqId}] ⚠️ Item-name normalization failed: ${error.message}`);
    console.log(`[${reqId}] ✓ Item-name normalization fallback complete in ${Date.now() - startedAt}ms (fallback=true)`);
    return fallbackNameNormalization(receipt);
  }
}

// ============================================================
// STAGE 10: CONFIDENCE + STATUS
// ============================================================

function determineParseStatus(reconciliation, normalized, hasRefund, resolutionResult) {
  let confidence = normalized.confidence || "medium";
  let status = "success";

  // Downgrade for refund indicators
  if (hasRefund) {
    confidence = "low";
    status = "needs_review";
  }

  // Status based on reconciliation
  if (reconciliation.mathCheckPassed && normalized.items.length > 0) {
    status = "success";
  } else if (reconciliation.mismatchReasons.length > 0 && normalized.items.length > 0) {
    status = "partial";
    confidence = confidence === "high" ? "medium" : "low";
  } else {
    status = "needs_review";
    confidence = "low";
  }

  // Adjust confidence only for cleanup that actually rewrites financial values.
  if (
    resolutionResult?.selectedCandidate &&
    !["original", "simple_final_amounts"].includes(resolutionResult.selectedCandidate) &&
    (resolutionResult?.changes || []).length > 0
  ) {
    // Applied a repair - slightly lower confidence
    confidence = confidence === "high" ? "medium" : confidence;
  }

  if (reconciliation.totalGap != null) {
    if (reconciliation.totalGap > 5.00) {
      confidence = "low";
    } else if (reconciliation.totalGap > 1.00) {
      confidence = confidence === "high" ? "medium" : "low";
    }
  }

  if (normalized.items.length === 0) {
    confidence = "low";
    status = "needs_review";
  }

  return { confidence, status };
}

function logCanonicalReceipt(receipt, reconciliation, reqId) {
  if (!ENABLE_MISTRAL_OCR_DEBUG || !receipt) return;
  console.log(`[${reqId}] === CANONICAL RECEIPT ===`);
  console.log(`[${reqId}] merchant: ${receipt.merchant || "(unknown)"}`);
  for (const item of receipt.items || []) {
    console.log(`[${reqId}] item: ${item.name} | $${Number(item.amount || 0).toFixed(2)} | ${item.discountLabel || "no discount"}`);
  }
  for (const fee of receipt.additionalFees || []) {
    console.log(`[${reqId}] additional fee: ${fee.name} | $${Number(fee.amount || 0).toFixed(2)}`);
  }
  console.log(`[${reqId}] itemSum=$${Number(reconciliation.itemSum || 0).toFixed(2)} tax=$${Number(reconciliation.tax || 0).toFixed(2)} tip=$${Number(reconciliation.tip || 0).toFixed(2)} additionalFeeSum=$${Number(reconciliation.additionalFeeSum || 0).toFixed(2)}`);
  console.log(`[${reqId}] calculatedTotal=$${Number(reconciliation.calculatedTotal || 0).toFixed(2)} scannedTotal=${reconciliation.total == null ? "null" : `$${Number(reconciliation.total).toFixed(2)}`} gapCents=${reconciliation.gapCents ?? "null"} status=${reconciliation.mathCheckPassed ? "trusted" : "needs_review"}`);
}

function buildApiResponse(parseResult, timings, reqId) {
  const { parsed, ocrText, result, reconciliation, rejected, resolutionResult, uploadDiagnostics } = parseResult;
  const extractionDiagnostics = buildExtractionDiagnostics({ ocrText, result, parsed, reconciliation, uploadDiagnostics });

  if (!parsed) {
    return {
      error: "No structured data could be extracted",
      merchant: "",
      items: [],
      confidence: "low",
      status: "needs_review",
      route: "extraction_failed",
      routeReason: "no_structured_output_from_mistral",
      extractionDiagnostics,
      nameNormalizationStatus: "local_complete",
      timings,
    };
  }

  const hasRefund = hasRefundIndicators(ocrText);
  const { confidence, status } = determineParseStatus(reconciliation, parsed, hasRefund, resolutionResult);
  logCanonicalReceipt(parsed, reconciliation, reqId);

  let route = "mistral_single_pass";
  let routeReason = "mistral_structured_receipt_parse";

  if (status === "success" && reconciliation.mathCheckPassed) {
    routeReason = reconciliation.mathCheckPassed ? "exact_reconciliation" : routeReason;
  } else if (status === "partial") {
    routeReason = reconciliation.mismatchReasons.join(", ") || "partial_extraction";
    if (reconciliation.mismatchReasons.includes("no_grand_total")) {
      routeReason = extractionDiagnostics.totalLossLayer === "annotation_missing_total_visible_in_ocr"
        ? `annotation_missing_total_visible_in_ocr:${extractionDiagnostics.ocrGrandTotalCandidates[0]?.amount ?? "unknown"}`
        : extractionDiagnostics.totalLossLayer === "normalization_lost_annotation_total"
          ? `normalization_lost_annotation_total:${extractionDiagnostics.annotationGrandTotal ?? "unknown"}`
          : routeReason;
    }
  } else if (status === "needs_review") {
    routeReason = "reconciliation_failed_or_no_items";
  }

  return {
    merchant: parsed.merchant || "",
    receiptDate: parsed.receiptDate,
    currency: parsed.currency || "USD",
    items: parsed.items.map(item => ({
      name: item.normalizedName || item.name,
      itemName: item.normalizedName || item.name,
      rawName: item.rawName || item.name,
      normalizedName: item.normalizedName || item.name,
      normalizationSource: item.normalizationSource || "local",
      itemCode: item.itemCode ?? null,
      amount: item.amount,
      itemValue: item.amount,
      discountLabel: item.discountLabel ?? null,
      itemDiscountLabel: item.discountLabel ?? null,
      discountDisplayLabel: item.discountLabel ?? null,
      qty: item.qty,
      unitPrice: item.unitPrice,
      weightLbs: item.weightLbs,
      confidence: item.confidence,
      category: item.category || "other",
      categoryConfidence: item.categoryConfidence ?? 0,
      categoryReason: item.categoryReason ?? "Category unavailable.",
      normalizationConfidence: item.normalizationConfidence ?? 0,
      normalizationAmbiguous: item.normalizationAmbiguous ?? true,
      needsNameVerification: item.needsNameVerification ?? true,
      possibleNameAlternatives: item.possibleNameAlternatives ?? [],
      normalizationReason:
        item.normalizationReason ??
        "Preserved raw receipt text.",
    })),
    subtotal: parsed.subtotal,
    tax: parsed.tax,
    tip: parsed.tip,
    fees: reconciliation.additionalFeeSum,
    additionalFees: (parsed.additionalFees || []).map(fee => ({
      name: fee.name,
      amount: fee.amount,
      feeName: fee.name,
      feeLabel: fee.name,
      feeValue: fee.amount,
      isTax: false,
      isTipOrGratuity: false,
    })),
    additionalFeesTotal: reconciliation.additionalFeeSum,
    itemDiscountTotal: null,
    discount: null,
    orderLevelDiscount: null,
    grandTotal: parsed.total,
    total: parsed.total,
    confidence,
    status,
    notes: parsed.notes,
    nameNormalizationStatus: "local_complete",
    reconciliation: {
      itemSum: reconciliation.itemSum,
      tax: reconciliation.tax,
      tip: reconciliation.tip,
      additionalFeeSum: reconciliation.additionalFeeSum,
      calculatedTotal: reconciliation.calculatedTotal,
      total: reconciliation.total,
      gapCents: reconciliation.gapCents,
      subtotalGap: reconciliation.subtotalGap,
      totalGap: reconciliation.totalGap,
      calculatedFromItems: reconciliation.calculatedFromItems,
      calculatedFromSubtotal: reconciliation.calculatedFromSubtotal,
      mathCheckPassed: reconciliation.mathCheckPassed,
      mismatchReasons: reconciliation.mismatchReasons,
    },
    extractionDiagnostics,
    route,
    routeReason,
    timings,
    debug: ENABLE_DEBUG_RESPONSE ? {
      parser_version: "production_v3_mistral_single_pass",
      model_used: result?.model || MISTRAL_OCR_MODEL,
      ocr_text_length: ocrText.length,
      ocr_text: ocrText,
      document_annotation: rawDocumentAnnotationObject(result?.documentAnnotation),
      rejected_items: rejected || [],
      has_refund_indicators: hasRefund,
      item_name_normalization: {
        model: null,
        enabled: true,
        status: "local_complete",
        items: parsed.items.map(item => ({
          rawName: item.rawName || item.name,
          normalizedName: item.normalizedName || item.name,
          source: item.normalizationSource || "local",
          confidence: item.normalizationConfidence ?? 0,
          ambiguous: item.normalizationAmbiguous ?? true,
          needsVerification: item.needsNameVerification ?? true,
          alternatives: item.possibleNameAlternatives ?? [],
          reason: item.normalizationReason ?? null,
          category: item.category || inferFallbackItemCategory(item.normalizedName || item.name),
          categoryConfidence: item.categoryConfidence ?? 0,
          categoryReason: item.categoryReason ?? null,
        })),
      },
      item_discounts: {
        enabled: true,
        items: parsed.items
          .filter(item => (item.itemDiscount ?? 0) > 0)
          .map(item => ({
            rawName: item.rawName || item.name,
            normalizedName: item.normalizedName || item.name,
            originalAmount: item.originalAmount ?? null,
            finalAmount: item.amount,
            itemDiscount: item.itemDiscount,
            itemDiscountLabel: item.itemDiscountLabel ?? null,
          })),
      },
      contradiction_resolution: {
        enabled: true,
        reason: "simple_cleanup_preserve_mistral_final_item_amounts",
        suspicious_items_detected: resolutionResult?.suspicious?.length || 0,
        suspicious_items: (resolutionResult?.suspicious || []).map(s => ({
          name: s.item.name,
          amount: s.item.amount ?? s.item.printedAmount ?? null,
          flags: s.flags,
          suspicion_score: s.suspicionScore,
        })),
        candidates_tried: resolutionResult?.candidatesTried || 0,
        selected_candidate: resolutionResult?.selectedCandidate || "not_run",
        selected_score: resolutionResult?.selectedScore ?? null,
        selected_reasons: resolutionResult?.selectedReasons || [],
        changes_applied: resolutionResult?.changes || [],
        candidates: (resolutionResult?.allCandidates || []).map(candidate => ({
          label: candidate.label,
          score: candidate.score ?? null,
          math_check_passed: Boolean(candidate.reconciliation?.mathCheckPassed),
          subtotal_gap: candidate.reconciliation?.subtotalGap ?? null,
          total_gap: candidate.reconciliation?.totalGap ?? null,
          item_count: candidate.receipt?.items?.length ?? 0,
          reasons: candidate.reasons || [],
        })),
      },
      arithmetic_breakdown: {
        items_detail: reconciliation.itemBreakdown,
        formula: `sum(items) + tax + tip + sum(additionalFees) = calculated`,
        calculation: `${reconciliation.itemSum} + ${reconciliation.tax} + ${reconciliation.tip} + ${reconciliation.additionalFeeSum} = ${reconciliation.calculatedTotal}`,
        vs_grand_total: `${reconciliation.calculatedTotal} vs ${parsed.total ?? "null"}`,
        gap: reconciliation.totalGap != null ? `$${reconciliation.totalGap.toFixed(2)}` : "N/A",
      },
    } : undefined
  };
}

// ============================================================
// API ENDPOINTS
// ============================================================

function requireAppAuth(req, res, next) {
  const authHeader = req.headers.authorization || "";
  if (authHeader !== `Bearer ${APP_BEARER_TOKEN}`) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
}

function requireAdminAuth(req, res, next) {
  const authHeader = req.headers.authorization || "";
  const token = ADMIN_BEARER_TOKEN || (process.env.NODE_ENV !== "production" ? APP_BEARER_TOKEN : "");
  if (!token || authHeader !== `Bearer ${token}`) {
    return res.status(401).json({ ok: false, error: "Admin authorization required" });
  }
  next();
}

function serializeStagedReceiptJob(job, reqId) {
  return {
    ok: job.status !== "failed",
    request_id: reqId || job.requestId,
    phase: job.status === "complete" ? "complete" : "quick_total",
    itemizationStatus: job.status,
    quickTotal: job.quickTotal || getQuickTotalFromFullReceipt(job.result),
    result: job.result || null,
    error: job.error || null,
    timings: {
      ...(job.timings || {}),
      elapsed_ms: Date.now() - job.createdAt,
    },
  };
}

app.post("/parse-receipt-staged", requireAppAuth, async (req, res) => {
  cleanupStagedReceiptJobs();
  const reqId = requestIdFrom(req);
  const startedAt = Date.now();
  const analyticsContext = analyticsContextFromRequest(req, reqId);

  try {
    const {
      imageBase64,
      mimeType = "image/jpeg",
      sourceType = "unknown",
      mode = "staged",
      appleOcrText = "",
      localHints = null,
      localParseResult = null,
      localCandidates = null,
      uploadDiagnostics: clientUploadDiagnostics = null,
    } = req.body || {};
    if (!imageBase64) {
      return res.status(400).json({ ok: false, request_id: reqId, error: { code: "MISSING_IMAGE", message: "Missing imageBase64 in request body" } });
    }

    const decodeStart = Date.now();
    const buffer = decodeBase64Payload(imageBase64);
    const uploadValidation = validateUploadBuffer(buffer, mimeType);
    if (!uploadValidation.ok) {
      return res.status(uploadValidation.status).json({
        ok: false,
        request_id: reqId,
        error: { code: uploadValidation.code, message: uploadValidation.message },
      });
    }

    const safeMimeType = uploadValidation.mimeType;
    const hash = fileHash(buffer);
    const uploadDiagnostics = buildUploadDiagnostics(buffer, mimeType, safeMimeType, clientUploadDiagnostics);
    logUploadDiagnostics(reqId, uploadDiagnostics);
    const decodeMs = Date.now() - decodeStart;
    const cached = getCachedParse(hash, "receipt");
    if (cached) {
      return res.json({
        ok: true,
        request_id: reqId,
        phase: "complete",
        itemizationStatus: "complete",
        quickTotal: getQuickTotalFromFullReceipt(cached),
        result: cached,
        timings: { decode_ms: decodeMs, total_ms: Date.now() - startedAt, cache_hit: true },
      });
    }

    const existingRequestId = stagedReceiptHashIndex.get(hash);
    const existingJob = existingRequestId ? stagedReceiptJobs.get(existingRequestId) : null;
    if (existingJob) {
      return res.status(existingJob.status === "complete" ? 200 : 202).json(
        serializeStagedReceiptJob(existingJob, existingRequestId)
      );
    }

    const job = {
      requestId: reqId,
      hash,
      uploadDiagnostics,
      status: "itemizing",
      createdAt: Date.now(),
      quickTotal: null,
      result: null,
      error: null,
      timings: {
        decode_ms: decodeMs,
        quick_total_ms: 0,
        itemization_ms: 0,
        cache_hit: false,
      },
    };
    stagedReceiptJobs.set(reqId, job);
    stagedReceiptHashIndex.set(hash, reqId);

    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_upload_validated",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: safeMimeType,
        image_size_bytes: buffer.length,
        mode,
        staged: true,
      },
    });

    const itemizationStartedAt = Date.now();
    const itemizationPromise = parseFullReceiptResponse(buffer, safeMimeType, `${reqId}_items`, {
      appleOcrText,
      localHints,
      localParseResult,
      localCandidates,
      uploadDiagnostics,
    })
      .then(result => {
        job.result = result;
        job.quickTotal = job.quickTotal || getQuickTotalFromFullReceipt(result);
        job.status = "complete";
        job.timings.itemization_ms = Date.now() - itemizationStartedAt;
        setCachedParse(hash, "receipt", result);
        trackAnalyticsEvent({
          ...analyticsContext,
          event_name: "receipt_parse_completed",
          properties: {
            request_id: reqId,
            staged: true,
            item_count: result?.items?.length || 0,
            processing_time_ms: job.timings.itemization_ms,
            status: result?.status,
            route: result?.route,
          },
        });
      })
      .catch(error => {
        job.status = "failed";
        job.error = {
          code: error?.code || "ITEMIZATION_FAILED",
          message: safeString(error?.message || "Receipt itemization failed."),
        };
        job.timings.itemization_ms = Date.now() - itemizationStartedAt;
        trackAnalyticsEvent({
          ...analyticsContext,
          event_name: "receipt_parse_failed",
          properties: {
            request_id: reqId,
            staged: true,
            error_code: job.error.code,
            failure_reason: normalizeAnalyticsFailureReason("receipt", job.error.code),
            processing_time_ms: job.timings.itemization_ms,
          },
        });
      });

    const firstResponseWaiters = [
      itemizationPromise.catch(() => undefined),
      delayMs(STAGED_FIRST_RESPONSE_TIMEOUT_MS),
    ];

    if (ENABLE_STAGED_QUICK_TOTAL) {
      const quickStartedAt = Date.now();
      const quickPromise = callMistralQuickTotal(buffer, safeMimeType, `${reqId}_total`)
        .then(quick => {
          job.quickTotal = quick.quickTotal;
          job.timings.quick_total_ms = Date.now() - quickStartedAt;
          trackAnalyticsEvent({
            ...analyticsContext,
            event_name: "receipt_quick_total_completed",
            properties: {
              request_id: reqId,
              processing_time_ms: job.timings.quick_total_ms,
              grand_total_found: job.quickTotal?.grandTotal != null,
              confidence: job.quickTotal?.confidence,
            },
          });
        })
        .catch(error => {
          job.timings.quick_total_ms = Date.now() - quickStartedAt;
          job.quickTotalError = {
            code: error?.code || "QUICK_TOTAL_FAILED",
            message: safeString(error?.message || "Quick total extraction failed."),
          };
          trackAnalyticsEvent({
            ...analyticsContext,
            event_name: "receipt_quick_total_failed",
            properties: {
              request_id: reqId,
              error_code: job.quickTotalError.code,
              processing_time_ms: job.timings.quick_total_ms,
            },
          });
        });
      firstResponseWaiters.push(quickPromise.catch(() => undefined));
    }

    await Promise.race(firstResponseWaiters);

    const payload = serializeStagedReceiptJob(job, reqId);
    payload.timings.total_ms = Date.now() - startedAt;
    if (job.status === "complete") return res.json(payload);
    if (job.status === "failed") return res.status(500).json(payload);
    return res.status(202).json(payload);
  } catch (error) {
    return res.status(500).json({
      ok: false,
      request_id: reqId,
      error: {
        code: error?.code || "STAGED_PARSE_ERROR",
        message: safeString(error?.message || "Failed to start staged receipt parse."),
      },
      timings: { total_ms: Date.now() - startedAt },
    });
  }
});

app.get("/parse-receipt-staged/:requestId", requireAppAuth, (req, res) => {
  cleanupStagedReceiptJobs();
  const job = stagedReceiptJobs.get(req.params.requestId);
  if (!job) {
    return res.status(404).json({
      ok: false,
      request_id: req.params.requestId,
      error: { code: "STAGED_PARSE_NOT_FOUND", message: "No staged receipt parse was found for this request_id." },
    });
  }
  return res.status(job.status === "complete" ? 200 : 202).json(serializeStagedReceiptJob(job, req.params.requestId));
});

app.post("/parse-receipt", requireAppAuth, async (req, res) => {
  const reqId = requestIdFrom(req);
  const startedAt = Date.now();
  let tempImagePath = null;
  const analyticsContext = analyticsContextFromRequest(req, reqId);
  const timings = {
    decode_ms: 0,
    temp_file_write_ms: 0,
    ocr_ms: 0,
    mistral_ocr_ms: 0,
    deterministic_cleanup_ms: 0,
    mistral_mapping_ms: 0,
    contradiction_resolution_ms: 0,
    reconciliation_ms: 0,
    total_ms: 0,
  };

  console.log("\n" + "=".repeat(80));
  console.log(`[${reqId}] RECEIPT PARSE REQUEST (MISTRAL SINGLE PASS)`);
  console.log("=".repeat(80));

  try {
    const {
      imageBase64,
      mimeType = "image/jpeg",
      sourceType = "unknown",
      mode = "unknown",
      appleOcrText = "",
      localHints = null,
      localParseResult = null,
      localCandidates = null,
      uploadDiagnostics: clientUploadDiagnostics = null,
    } = req.body || {};

    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_upload_started",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: mimeType,
        expected_document_type: "receipt",
        mode,
      },
    });

    if (!imageBase64) {
      console.log(`[${reqId}] ✗ Missing imageBase64`);
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_upload_rejected",
        properties: { request_id: reqId, failure_reason: "invalid_document", error_code: "MISSING_IMAGE" },
      });
      return res.status(400).json({ error: "Missing imageBase64 in request body" });
    }

    const decodeStart = Date.now();
    let base64Data = imageBase64;
    const idx = base64Data.indexOf("base64,");
    if (idx >= 0) {
      base64Data = base64Data.slice(idx + 7);
    }

    const buffer = Buffer.from(base64Data, "base64");
    const uploadValidation = validateUploadBuffer(buffer, mimeType);
    if (!uploadValidation.ok) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: normalizeAnalyticsFailureReason("receipt", uploadValidation.code),
          error_code: uploadValidation.code,
          file_type: mimeType,
        },
      });
      return res.status(uploadValidation.status).json({
        error: { code: uploadValidation.code, message: uploadValidation.message },
        request_id: reqId,
        timings,
      });
    }
    const safeMimeType = uploadValidation.mimeType;
    timings.decode_ms = Date.now() - decodeStart;
    const hash = fileHash(buffer);
    const uploadDiagnostics = buildUploadDiagnostics(buffer, mimeType, safeMimeType, clientUploadDiagnostics);
    console.log(`[${reqId}] Image size: ${(buffer.length / 1024).toFixed(2)} KB`);
    logUploadDiagnostics(reqId, uploadDiagnostics);
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_upload_validated",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: safeMimeType,
        image_size_bytes: buffer.length,
        mode,
      },
    });

    const cached = getCachedParse(hash, "receipt");
    if (cached) {
      timings.total_ms = Date.now() - startedAt;
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_parse_completed",
        properties: {
          request_id: reqId,
          cache_hit: true,
          processing_time_ms: timings.total_ms,
          item_count: cached?.items?.length || 0,
          status: cached.status,
          route: cached.route,
        },
      });
      console.log(`[${reqId}] ✓ Receipt cache hit in ${timings.total_ms}ms`);
      return res.json({
        ...cached,
        request_id: reqId,
        timings: {
          ...(cached.timings || {}),
          ...timings,
          cache_hit: true,
        },
        debug: cached.debug
          ? {
              ...cached.debug,
              timings: {
                ...(cached.debug.timings || {}),
                ...timings,
                cache_hit: true,
              },
            }
          : undefined,
      });
    }

    if (buffer.length > RECOMMENDED_IMAGE_MAX_BYTES) {
      console.log(`[${reqId}] Large image detected. Compress on the client for faster OCR.`);
    }

    if (buffer.length < 128) {
      console.log(`[${reqId}] ✗ Image too small`);
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_upload_rejected",
        properties: { request_id: reqId, failure_reason: "invalid_document", error_code: "IMAGE_TOO_SMALL" },
      });
      return res.status(400).json({ error: "Image too small or corrupt" });
    }

    if (SAVE_TEMP_RECEIPTS) {
      const tempFileWriteStart = Date.now();
      const ext = getTempExtension(safeMimeType);
      const filename = `receipt_${Date.now()}_${Math.random().toString(36).slice(2)}${ext}`;
      tempImagePath = path.join(TEMP_DIR, filename);
      await fs.promises.writeFile(tempImagePath, buffer);
      timings.temp_file_write_ms = Date.now() - tempFileWriteStart;
    }

    const ocrStart = Date.now();
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_ocr_started",
      properties: { request_id: reqId, ocr_provider: "mistral", file_type: safeMimeType, mode },
    });
    let { parsed, ocrText, result } = await callMistralOCR(buffer, safeMimeType, reqId, {
      appleOcrText,
      localHints,
      localParseResult,
      localCandidates,
      uploadDiagnostics,
    });
    const candidateSelection = selectMistralReceiptCandidate(parsed, ocrText, reqId);
    timings.ocr_ms = Date.now() - ocrStart;
    timings.mistral_ocr_ms = timings.ocr_ms;
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_ocr_completed",
      properties: {
        request_id: reqId,
        ocr_provider: "mistral",
        processing_time_ms: timings.ocr_ms,
        detected_document_type: "receipt_candidate",
        ocr_text_length: ocrText.length,
      },
    });

    const receiptClassification = classifyReceiptUpload({ ocrText, parsed: parsed || candidateSelection.fallback });
    console.log(`[${reqId}] Receipt classification: ${receiptClassification.ok ? "receipt" : "reject"} confidence=${receiptClassification.confidence} reason=${receiptClassification.reason}`);
    if (!receiptClassification.ok) {
      timings.total_ms = Date.now() - startedAt;
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: "invalid_document",
          detected_document_type: "not_receipt",
          classification_confidence: receiptClassification.confidence,
          processing_time_ms: timings.total_ms,
          error_code: receiptClassification.code || "NOT_A_RECEIPT",
        },
      });
      return res.status(422).json({
        ok: false,
        error: {
          code: receiptClassification.code || "NOT_A_RECEIPT",
          message: "This does not look like a receipt. Please scan a receipt image instead.",
        },
        request_id: reqId,
        classification: receiptClassification,
        timings,
      });
    }
    
    let normalized = null;
    let rejected = [];
    let resolutionResult = {
      receipt: null,
      selectedCandidate: "not_run",
      candidatesTried: 0,
      suspicious: [],
      changes: [],
      allCandidates: [],
    };
    
    parsed = candidateSelection.parsed;
    if (parsed) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "receipt_parse_started",
        properties: { request_id: reqId, parser: candidateSelection.extractionSource, mode },
      });
      const deterministicCleanupStart = Date.now();
      normalized = normalizeParsedReceipt(parsed);
      normalized.notes = [
        normalized.notes,
        candidateSelection.extractionSource === "mistral_ocr_text_fallback_preferred"
          ? "Structured annotation was under-itemized; used Mistral OCR markdown fallback itemization."
          : candidateSelection.extractionSource === "mistral_ocr_text_fallback"
            ? "Structured annotation unavailable; used Mistral OCR markdown fallback itemization."
            : null,
      ].filter(Boolean).join(" ") || normalized.notes;
      timings.deterministic_cleanup_ms = Date.now() - deterministicCleanupStart;
      timings.mistral_mapping_ms = timings.deterministic_cleanup_ms;

      resolutionResult = {
        receipt: normalized,
        selectedCandidate: "not_run",
        candidatesTried: 0,
        suspicious: [],
        changes: [],
        allCandidates: [],
      };

      normalized = applyFastLocalNormalization(normalized);

      const contradictionStart = Date.now();
      resolutionResult = resolveFinancialContradictions(normalized, reqId, {
        ocrText,
      });
      normalized = preserveAnnotationGrandTotal(
        resolutionResult.receipt,
        result?.documentAnnotation,
        reqId
      );
      timings.contradiction_resolution_ms = Date.now() - contradictionStart;
      resolutionResult.receipt = normalized;
    }

    const reconciliationStart = Date.now();
    const reconciliation = normalized ? reconcileReceipt(normalized) : {
      itemSum: null,
      subtotalGap: null,
      totalGap: null,
      calculatedFromItems: null,
      calculatedFromSubtotal: null,
      mathCheckPassed: false,
      mismatchReasons: ["no_data_extracted"],
      itemBreakdown: [],
    };
    timings.reconciliation_ms = Date.now() - reconciliationStart;

    timings.total_ms = Date.now() - startedAt;

    // Enhanced logging
    console.log(`[${reqId}] Final Results:`);
    console.log(`[${reqId}]   - Items: ${normalized?.items.length || 0} (Mistral itemization preserved)`);
    
    if (reconciliation.itemBreakdown && reconciliation.itemBreakdown.length > 0) {
      console.log(`[${reqId}]   - Item Details:`);
      reconciliation.itemBreakdown.forEach(line => console.log(`[${reqId}]     ${line}`));
    }
    
    console.log(`[${reqId}]   - Subtotal: $${normalized?.subtotal?.toFixed(2) ?? "null"}`);
    console.log(`[${reqId}]   - Tax: $${normalized?.tax?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Tip: $${normalized?.tip?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Fees: $${normalized?.fees?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Order Discount: $${normalized?.orderLevelDiscount?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Item Sum: $${reconciliation.itemSum?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Calculated Total: $${reconciliation.calculatedFromItems?.toFixed(2) ?? "0.00"}`);
    console.log(`[${reqId}]   - Grand Total (receipt): $${normalized?.grandTotal?.toFixed(2) ?? "null"}`);
    console.log(`[${reqId}]   - Math check: ${reconciliation.mathCheckPassed ? "✓ PASS" : "✗ FAIL"}`);
    console.log(`[${reqId}]   - Total gap: $${reconciliation.totalGap?.toFixed(2) ?? "N/A"}`);

    console.log(`[${reqId}] Timing breakdown:`);
    console.log(`[${reqId}]   - Decode: ${timings.decode_ms}ms`);
    console.log(`[${reqId}]   - Temp file write: ${timings.temp_file_write_ms}ms`);
    console.log(`[${reqId}]   - OCR: ${timings.ocr_ms}ms`);
    console.log(`[${reqId}]   - Mistral result shaping: ${timings.deterministic_cleanup_ms}ms`);
    console.log(`[${reqId}]   - Contradiction resolution: ${timings.contradiction_resolution_ms}ms`);
    console.log(`[${reqId}]   - Reconciliation: ${timings.reconciliation_ms}ms`);
    console.log(`[${reqId}]   - Total: ${timings.total_ms}ms`);

    const response = buildApiResponse(
      { parsed: normalized, ocrText, result, reconciliation, rejected, resolutionResult, uploadDiagnostics },
      timings,
      reqId
    );
    if (response?.ok !== false) {
      setCachedParse(hash, "receipt", response);
    }
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "receipt_parse_completed",
      properties: {
        request_id: reqId,
        processing_time_ms: timings.total_ms,
        item_count: normalized?.items.length || 0,
        subtotal_found: normalized?.subtotal != null,
        tax_found: normalized?.tax != null,
        tip_found: normalized?.tip != null,
        fees_found: normalized?.fees != null,
        discount_found: normalized?.orderLevelDiscount != null || (normalized?.items || []).some(item => (item.itemDiscount ?? 0) > 0),
        grand_total_found: normalized?.grandTotal != null,
        reconciliation_passed: Boolean(reconciliation.mathCheckPassed),
        correction_count: 0,
        status: response.status,
        route: response.route,
      },
    });

    console.log(`[${reqId}] ✓ Complete in ${timings.total_ms}ms`);
    console.log(`[${reqId}] Status: ${response.status} | Confidence: ${response.confidence}`);
    console.log(`[${reqId}] Route: ${response.route}`);
    console.log("=".repeat(80) + "\n");

    return res.json(response);

  } catch (error) {
    timings.total_ms = Date.now() - startedAt;
    console.error(`[${reqId}] ✗ ERROR:`, error);
    const statusCode = error?.code === "MISTRAL_TIMEOUT" ? 504 : 500;
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: error?.message?.toLowerCase().includes("ocr") ? "receipt_ocr_failed" : "receipt_parse_failed",
      properties: {
        request_id: reqId,
        failure_reason: normalizeAnalyticsFailureReason("receipt", error?.code || error?.message),
        error_code: error?.code || "UNKNOWN_PARSE_ERROR",
        sanitized_message: safeString(error?.message || "unknown_error"),
        processing_time_ms: timings.total_ms,
      },
    });
    return res.status(statusCode).json({
      error: "Failed to parse receipt",
      detail: error?.message || "unknown_error",
      code: error?.code || "UNKNOWN_PARSE_ERROR",
      request_id: reqId,
      timings,
    });
  } finally {
    if (SAVE_TEMP_RECEIPTS && tempImagePath) {
      try {
        await fs.promises.unlink(tempImagePath);
      } catch {}
    }
  }
});

app.get("/", (req, res) => {
  res.json({ ok: true, service: "financial-document-parser", health: "/health" });
});

app.post("/analytics/events", requireAppAuth, (req, res) => {
  const reqId = requestIdFrom(req);
  const context = analyticsContextFromRequest(req, reqId);
  const events = Array.isArray(req.body?.events) ? req.body.events : [req.body];
  let accepted = 0;

  for (const event of events.slice(0, 50)) {
    if (!event?.event_name && !event?.eventName) continue;
    trackAnalyticsEvent({
      ...context,
      user_id: event.user_id ?? event.userId ?? context.user_id,
      anonymous_id: event.anonymous_id ?? event.anonymousId ?? context.anonymous_id,
      session_id: event.session_id ?? event.sessionId ?? context.session_id,
      request_id: event.request_id ?? event.requestId ?? context.request_id,
      event_name: event.event_name ?? event.eventName,
      platform: event.platform ?? context.platform,
      app_version: event.app_version ?? event.appVersion ?? context.app_version,
      properties: event.properties || {},
    });
    accepted += 1;
  }

  res.json({ ok: true, accepted, request_id: reqId });
});

function parseAnalyticsRange(query) {
  const now = new Date();
  const preset = query.range || "7d";
  let from = query.from;
  let to = query.to;
  if (!from) {
    const days =
      preset === "today" ? 1 :
      preset === "30d" ? 30 :
      preset === "all" ? 3650 :
      7;
    from = new Date(now.getTime() - days * 24 * 60 * 60 * 1000).toISOString();
  }
  if (!to) to = now.toISOString();
  return { from, to };
}

function filterAnalyticsEvents(events, query) {
  const filters = {
    user_id: query.user_id,
    anonymous_id: query.anonymous_id,
    session_id: query.session_id,
    request_id: query.request_id,
    app_version: query.app_version,
    platform: query.platform,
    event_name: query.event_name,
  };
  return events.filter(event => {
    for (const [key, value] of Object.entries(filters)) {
      if (value && String(event[key] || "") !== String(value)) return false;
    }
    const props = event.properties || {};
    if (query.mode && props.mode !== query.mode) return false;
    if (query.document_type && props.detected_document_type !== query.document_type && props.expected_document_type !== query.document_type) return false;
    if (query.file_type && props.file_type !== query.file_type) return false;
    if (query.error_category && props.failure_reason !== query.error_category && props.error_code !== query.error_category) return false;
    if (query.subscription_product && props.product_id !== query.subscription_product) return false;
    return true;
  });
}

app.get("/admin/analytics/summary", requireAdminAuth, async (req, res) => {
  const range = parseAnalyticsRange(req.query);
  const events = filterAnalyticsEvents(await readAnalyticsEvents({ ...range, limit: 20000 }), req.query);
  res.json({ ok: true, range, summary: summarizeAnalytics(events) });
});

app.get("/admin/analytics/events", requireAdminAuth, async (req, res) => {
  const range = parseAnalyticsRange(req.query);
  const limit = Math.min(Number(req.query.limit || 500), 5000);
  const events = filterAnalyticsEvents(await readAnalyticsEvents({ ...range, limit: 20000 }), req.query).slice(-limit).reverse();
  res.json({ ok: true, range, events });
});

app.get("/admin/analytics", requireAdminAuth, async (req, res) => {
  const range = parseAnalyticsRange(req.query);
  const events = filterAnalyticsEvents(await readAnalyticsEvents({ ...range, limit: 20000 }), req.query);
  const summary = summarizeAnalytics(events);
  const recent = events.slice(-100).reverse();
  res.type("html").send(renderAnalyticsDashboard({ range, summary, recent }));
});

function renderAnalyticsDashboard({ range, summary, recent }) {
  const eventRows = recent.map(event => `
    <tr>
      <td>${escapeHtml(event.created_at)}</td>
      <td>${escapeHtml(event.event_name)}</td>
      <td>${escapeHtml(event.user_id || "")}</td>
      <td>${escapeHtml(event.session_id || "")}</td>
      <td>${escapeHtml(event.request_id || "")}</td>
      <td>${escapeHtml(event.properties?.failure_reason || event.properties?.error_code || "")}</td>
      <td><pre>${escapeHtml(JSON.stringify(event.properties || {}, null, 2))}</pre></td>
    </tr>
  `).join("");

  const countCards = Object.entries(summary.counts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 24)
    .map(([name, count]) => `<div class="card"><strong>${escapeHtml(name)}</strong><span>${count}</span></div>`)
    .join("");

  const errors = summary.most_common_errors
    .map(error => `<li>${escapeHtml(error.reason)} <strong>${error.count}</strong></li>`)
    .join("");

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Dutchie Analytics</title>
  <style>
    :root { color-scheme: light; --ink:#1c1a16; --cream:#fffdf7; --line:#ded8ca; --muted:#777168; }
    body { margin:0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background:var(--cream); color:var(--ink); }
    header { padding:28px 32px 18px; border-bottom:2px dashed var(--line); }
    h1 { margin:0; font-size:28px; letter-spacing:.04em; }
    main { padding:24px 32px 48px; }
    .grid { display:grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap:12px; margin:18px 0 28px; }
    .card { border:1px solid var(--line); background:white; padding:14px; display:flex; justify-content:space-between; gap:12px; }
    .card strong { font-size:11px; text-transform:uppercase; color:var(--muted); }
    .card span { font-size:24px; font-weight:800; }
    .tabs { display:grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap:12px; }
    section { margin-top:26px; }
    table { width:100%; border-collapse:collapse; background:white; border:1px solid var(--line); }
    th, td { padding:10px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top; font-size:12px; }
    th { background:#f3efe5; text-transform:uppercase; letter-spacing:.08em; }
    pre { white-space:pre-wrap; max-width:420px; margin:0; color:var(--muted); }
    a { color:var(--ink); }
  </style>
</head>
<body>
  <header>
    <h1>Dutchie Analytics</h1>
    <p>Range: ${escapeHtml(range.from)} to ${escapeHtml(range.to)}</p>
  </header>
  <main>
    <div class="grid">
      <div class="card"><strong>Total events</strong><span>${summary.total_events}</span></div>
      <div class="card"><strong>Unique users</strong><span>${summary.unique_users}</span></div>
      <div class="card"><strong>Unique sessions</strong><span>${summary.unique_sessions}</span></div>
      <div class="card"><strong>Receipt success</strong><span>${summary.receipt_success_rate}%</span></div>
      <div class="card"><strong>Statement success</strong><span>${summary.statement_success_rate}%</span></div>
      <div class="card"><strong>OCR success</strong><span>${summary.ocr_success_rate}%</span></div>
      <div class="card"><strong>Avg ms</strong><span>${summary.response_time_ms.average}</span></div>
      <div class="card"><strong>P95 ms</strong><span>${summary.response_time_ms.p95}</span></div>
    </div>

    <section>
      <h2>Event Counts</h2>
      <div class="grid">${countCards || "<p>No events yet.</p>"}</div>
    </section>

    <section>
      <h2>Most Common Errors</h2>
      <ul>${errors || "<li>No errors recorded.</li>"}</ul>
    </section>

    <section>
      <h2>Recent Events</h2>
      <table>
        <thead>
          <tr><th>Timestamp</th><th>Event</th><th>User</th><th>Session</th><th>Request</th><th>Error</th><th>Properties</th></tr>
        </thead>
        <tbody>${eventRows || "<tr><td colspan='7'>No events yet.</td></tr>"}</tbody>
      </table>
    </section>
  </main>
</body>
</html>`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

app.post("/parse-financial-document", requireAppAuth, async (req, res) => {
  const reqId = requestIdFrom(req);
  const startedAt = Date.now();
  let tempPath = null;
  const analyticsContext = analyticsContextFromRequest(req, reqId);

  console.log("\n" + "=".repeat(80));
  console.log(`[${reqId}] FINANCIAL DOCUMENT PARSE REQUEST`);
  console.log("=".repeat(80));

  try {
    const { fileBase64, imageBase64, mimeType = "image/jpeg", uploadIntent = "scan_statement", sourceType = "screenshot", mode = "statement" } = req.body || {};
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_upload_started",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: mimeType,
        expected_document_type: "bank_statement",
        mode,
      },
    });
    const encoded = fileBase64 || imageBase64;
    if (!encoded) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_upload_rejected",
        properties: { request_id: reqId, failure_reason: "invalid_statement", error_code: "MISSING_FILE" },
      });
      return res.status(400).json({ ok: false, request_id: reqId, error: { code: "MISSING_FILE", message: "Missing fileBase64 in request body." } });
    }

    const buffer = decodeBase64Payload(encoded);
    const uploadValidation = validateUploadBuffer(buffer, mimeType);
    if (!uploadValidation.ok) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: normalizeAnalyticsFailureReason("statement", uploadValidation.code),
          error_code: uploadValidation.code,
          file_type: mimeType,
        },
      });
      return res.status(uploadValidation.status).json({ ok: false, request_id: reqId, error: { code: uploadValidation.code, message: uploadValidation.message } });
    }

    const safeMimeType = uploadValidation.mimeType;
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_upload_validated",
      properties: {
        request_id: reqId,
        upload_source: sourceType,
        file_type: safeMimeType,
        file_size_bytes: buffer.length,
        mode,
      },
    });
    const hash = fileHash(buffer);
    const financialDocumentCacheNamespace = "financial_document_v2";
    const cached = getCachedParse(hash, financialDocumentCacheNamespace);
    if (cached) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_parse_completed",
        properties: {
          request_id: reqId,
          cache_hit: true,
          detected_document_type: cached.documentType,
          transaction_count: cached.data?.transactions?.length || 0,
          processing_time_ms: Date.now() - startedAt,
        },
      });
      return res.json({ ...cached, request_id: cached.request_id || reqId });
    }

    if (SAVE_TEMP_RECEIPTS) {
      const filename = `financial_${Date.now()}_${Math.random().toString(36).slice(2)}${getTempExtension(safeMimeType)}`;
      tempPath = path.join(TEMP_DIR, filename);
      await fs.promises.writeFile(tempPath, buffer);
    }

    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_extraction_started",
      properties: { request_id: reqId, ocr_provider: "mistral", file_type: safeMimeType, mode },
    });
    const ocr = await runMistralOcr({
      buffer,
      mimeType: safeMimeType,
      reqId,
      documentAnnotationFormat: responseFormatFromZodObject(BankDocumentSchema),
      documentAnnotationPrompt: BANK_DOCUMENT_PROMPT,
    });

    if (safeMimeType === "application/pdf" && ocr.pageCount > MAX_PDF_PAGES) {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: "pdf_extraction_failed",
          error_code: "PDF_PAGE_LIMIT_EXCEEDED",
          page_count: ocr.pageCount,
        },
      });
      return res.status(413).json({ ok: false, request_id: reqId, error: { code: "PDF_PAGE_LIMIT_EXCEEDED", message: `This PDF has ${ocr.pageCount} pages. The current limit is ${MAX_PDF_PAGES} pages.` } });
    }
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_extraction_completed",
      properties: {
        request_id: reqId,
        ocr_provider: "mistral",
        processing_time_ms: Date.now() - startedAt,
        page_count: ocr.pageCount,
        low_confidence_field_count: ocr.lowConfidenceFields?.length || 0,
      },
    });

    let classification = classifyFinancialDocument({ ocrText: ocr.ocrText, uploadIntent, sourceType, mimeType: safeMimeType });
    const isStatementIntent = uploadIntent === "scan_statement";
    const isPdfStatementIntent = isStatementIntent && safeMimeType === "application/pdf";
    const fallbackDocumentType = isPdfStatementIntent ? "bank_statement" : "account_activity_screenshot";
    const fallbackTransactionsBeforeGate = isStatementIntent
      ? extractFallbackBankTransactionsFromOcrText(ocr.ocrText, fallbackDocumentType)
      : [];
    const classificationWouldReject = ["unsupported", "ambiguous", "receipt"].includes(classification.documentType);
    if (classificationWouldReject && isStatementIntent && (isPdfStatementIntent || fallbackTransactionsBeforeGate.length > 0)) {
      const evidence = [];
      if (isPdfStatementIntent) evidence.push("the user uploaded a PDF in statement mode");
      if (fallbackTransactionsBeforeGate.length > 0) evidence.push(`${fallbackTransactionsBeforeGate.length} transaction-like row(s) were recovered from OCR text`);
      classification = {
        documentType: fallbackDocumentType,
        confidence: Math.max(classification.confidence || 0, fallbackTransactionsBeforeGate.length > 0 ? 0.72 : 0.6),
        reason: `${classification.reason} Continuing with statement extraction because ${evidence.join(" and ")}.`,
      };
    }
    const buildStatementDebug = () => ({
      method: "mistral",
      provider: "mistral_ocr_structured_output",
      model: ocr.model || MISTRAL_OCR_MODEL,
      elapsedMs: Date.now() - startedAt,
      confidence: classification.confidence,
      confidenceReason: classification.reason,
      pageCount: ocr.pageCount,
      lowConfidenceFieldCount: ocr.lowConfidenceFields?.length || 0,
    });
    const baseResponse = {
      ok: true,
      parseVersion: "financial_doc_parser_v2",
      documentType: classification.documentType,
      classification: { confidence: classification.confidence, reason: classification.reason },
      data: {},
      reconciliation: { status: "not_applicable", reason: "No reconciliation was run for this document type." },
      warnings: [],
      reviewRequired: false,
      ocr: { model: ocr.model, pageCount: ocr.pageCount, lowConfidenceFields: ocr.lowConfidenceFields },
      debug: buildStatementDebug(),
      request_id: reqId,
    };

    if (["unsupported", "ambiguous", "receipt"].includes(classification.documentType)) {
      const response = {
        ...baseResponse,
        ok: false,
        error: {
          code: "NOT_A_STATEMENT",
          message: "This does not look like a statement or transaction-history screenshot. Please upload a bank/credit-card statement, PDF, or transaction screenshot.",
        },
        reviewRequired: true,
        warnings: [classification.reason],
      };
      setCachedParse(hash, financialDocumentCacheNamespace, response);
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_upload_rejected",
        properties: {
          request_id: reqId,
          failure_reason: classification.documentType === "receipt" ? "invalid_statement" : "screenshot_classification_failed",
          detected_document_type: classification.documentType,
          classification_confidence: classification.confidence,
          error_code: "NOT_A_STATEMENT",
          processing_time_ms: Date.now() - startedAt,
        },
      });
      return res.status(422).json(response);
    }

    let bankDocument;
    let bankRaw;
    try {
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_parse_started",
        properties: { request_id: reqId, parser: "mistral_structured_output", detected_document_type: classification.documentType },
      });
      bankRaw = parseAndValidateDocumentAnnotation(ocr.documentAnnotation, BankDocumentSchema);
      bankDocument = normalizeBankDocument(bankRaw, classification.documentType);
    } catch (annotationError) {
      const fallbackOnlyTransactions = fallbackTransactionsBeforeGate.length > 0
        ? fallbackTransactionsBeforeGate
        : extractFallbackBankTransactionsFromOcrText(ocr.ocrText, classification.documentType);
      if (fallbackOnlyTransactions.length === 0) {
        throw annotationError;
      }
      bankDocument = normalizeBankDocument({
        documentType: classification.documentType,
        institutionName: null,
        accountName: null,
        accountLast4: null,
        statementPeriod: { startDate: null, endDate: null },
        currency: "USD",
        partialDocument: sourceType !== "pdf",
        transactions: fallbackOnlyTransactions,
        warnings: ["Structured extraction was incomplete, so transaction rows were recovered from OCR text."],
      }, classification.documentType);
    }

    const fallbackTransactions = fallbackTransactionsBeforeGate.length > 0 && bankDocument.documentType === fallbackDocumentType
      ? fallbackTransactionsBeforeGate
      : extractFallbackBankTransactionsFromOcrText(ocr.ocrText, bankDocument.documentType);
    if (fallbackTransactions.length > 0 && bankDocument.transactions.length < fallbackTransactions.length) {
      bankDocument.transactions = mergeBankTransactions(bankDocument.transactions, fallbackTransactions);
      bankDocument.warnings.push("Some transaction rows were recovered from OCR text because structured extraction was incomplete.");
    }
    const reconciliation = reconcileBankDocument(bankDocument);
    const warnings = [...(bankDocument.warnings || [])];
    if (bankDocument.partialDocument) warnings.push("This appears to be a partial screenshot. Only the visible transactions were imported.");
    if (bankDocument.transactions.length === 0) {
      warnings.push("No visible transactions were detected.");
      const response = {
        ...baseResponse,
        ok: false,
        error: {
          code: "NO_STATEMENT_TRANSACTIONS",
          message: "No statement transactions were detected. Please upload a clearer statement or transaction-history screenshot.",
        },
        documentType: bankDocument.documentType,
        data: bankDocument,
        reconciliation,
        warnings,
        debug: buildStatementDebug(),
        reviewRequired: true,
      };
      setCachedParse(hash, financialDocumentCacheNamespace, response);
      trackAnalyticsEvent({
        ...analyticsContext,
        event_name: "statement_parse_failed",
        properties: {
          request_id: reqId,
          failure_reason: "transaction_extraction_failed",
          detected_document_type: bankDocument.documentType,
          error_code: "NO_STATEMENT_TRANSACTIONS",
          processing_time_ms: Date.now() - startedAt,
        },
      });
      return res.status(422).json(response);
    }

    const response = {
      ...baseResponse,
      documentType: bankDocument.documentType,
      data: bankDocument,
      reconciliation,
      warnings,
      debug: buildStatementDebug(),
      reviewRequired: bankDocument.transactions.length === 0 || classification.confidence < 0.75,
    };
    setCachedParse(hash, financialDocumentCacheNamespace, response);
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: "statement_parse_completed",
      properties: {
        request_id: reqId,
        detected_document_type: bankDocument.documentType,
        transaction_count: bankDocument.transactions.length,
        processing_time_ms: Date.now() - startedAt,
        reconciliation_status: reconciliation.status,
        file_type: safeMimeType,
        mode,
      },
    });
    console.log(`[${reqId}] ✓ Financial document parse complete in ${Date.now() - startedAt}ms type=${response.documentType}`);
    return res.json(response);
  } catch (error) {
    const code = error?.code || (error?.message?.toLowerCase().includes("timeout") ? "MISTRAL_TIMEOUT" : "UNKNOWN_PARSE_ERROR");
    console.error(`[${reqId}] ✗ FINANCIAL DOCUMENT ERROR:`, code, error?.message);
    trackAnalyticsEvent({
      ...analyticsContext,
      event_name: code === "MISTRAL_TIMEOUT" ? "statement_extraction_failed" : "statement_parse_failed",
      properties: {
        request_id: reqId,
        failure_reason: normalizeAnalyticsFailureReason("statement", code || error?.message),
        error_code: code,
        sanitized_message: safeString(error?.message || "Failed to parse financial document."),
        processing_time_ms: Date.now() - startedAt,
      },
    });
    return res.status(code === "MALFORMED_ANNOTATION" || code === "SCHEMA_VALIDATION_FAILED" ? 422 : 500).json({ ok: false, request_id: reqId, error: { code, message: error?.message || "Failed to parse financial document." } });
  } finally {
    if (SAVE_TEMP_RECEIPTS && tempPath) {
      try { await fs.promises.unlink(tempPath); } catch {}
    }
  }
});

app.post("/normalize-item-names", requireAppAuth, async (req, res) => {
  const reqId = `req_${Date.now().toString(36)}`;

  console.log("\n" + "=".repeat(80));
  console.log(`[${reqId}] OPTIONAL ITEM-NAME NORMALIZATION REQUEST`);
  console.log("=".repeat(80));

  try {
    const { merchant = "", items = [] } = req.body || {};

    if (!Array.isArray(items)) {
      return res.status(400).json({ error: "items must be an array" });
    }

    const receipt = applyFastLocalNormalization({
      merchant,
      items: items.map(item => ({
        name: item.name || item.rawName || "Unknown Item",
        itemCode: item.itemCode ?? null,
        amount: item.amount,
        originalAmount: item.originalAmount ?? null,
        itemDiscount: item.itemDiscount ?? null,
        itemDiscountLabel: item.itemDiscountLabel ?? null,
        qty: item.qty,
        unitPrice: item.unitPrice,
        weightLbs: item.weightLbs,
        confidence: item.confidence,
      })),
    });

    const enriched = await normalizeItemNamesWithMistral(receipt, reqId);

    console.log(`[${reqId}] ✓ Optional item-name normalization complete`);
    console.log("=".repeat(80) + "\n");

    return res.json({
      items: (enriched.items || []).map(item => ({
        name: item.normalizedName || item.name,
        rawName: item.rawName || item.name,
        normalizedName: item.normalizedName || item.name,
        normalizationSource: item.normalizationSource || "local",
        itemCode: item.itemCode ?? null,
        amount: item.amount,
        originalAmount: item.originalAmount ?? null,
        itemDiscount: item.itemDiscount ?? null,
        itemDiscountLabel: item.itemDiscountLabel ?? null,
        hasItemDiscount: (item.itemDiscount ?? 0) > 0,
        qty: item.qty,
        unitPrice: item.unitPrice,
        weightLbs: item.weightLbs,
        confidence: item.confidence,
        category: item.category || "other",
        categoryConfidence: item.categoryConfidence ?? 0,
        categoryReason: item.categoryReason ?? "Category unavailable.",
        normalizationConfidence: item.normalizationConfidence ?? 0,
        normalizationAmbiguous: item.normalizationAmbiguous ?? true,
        needsNameVerification: item.needsNameVerification ?? true,
        possibleNameAlternatives: item.possibleNameAlternatives ?? [],
        normalizationReason:
          item.normalizationReason ??
          "Preserved raw receipt text.",
      })),
    });
  } catch (error) {
    console.error(`[${reqId}] ✗ OPTIONAL NORMALIZATION ERROR:`, error);
    return res.status(500).json({
      error: "Failed to normalize item names",
      detail: error?.message || "unknown_error",
    });
  }
});

app.get("/health", (req, res) => {
  res.json({
    ok: true,
    timestamp: new Date().toISOString(),
    version: "2.1.0",
    parser: "production_mistral_single_pass_receipt_parser",
    analytics: {
      storage: "jsonl_file",
      retentionDays: ANALYTICS_RETENTION_DAYS,
      adminEnabled: Boolean(ADMIN_BEARER_TOKEN) || process.env.NODE_ENV !== "production",
    },
  });
});

// ============================================================
// SERVER STARTUP
// ============================================================

cleanupAnalyticsEvents();

if (process.env.NODE_ENV !== "test") {
  app.listen(PORT, "0.0.0.0", () => {
    console.log("✓ Server ready on http://0.0.0.0:" + PORT);
    console.log("  Endpoint: POST /parse-receipt (Mistral single-pass receipt parsing)");
    console.log("  Endpoint: POST /parse-receipt-staged (quick total + async itemization)");
    console.log("  Endpoint: GET /parse-receipt-staged/:requestId (staged itemization status)");
    console.log("  Endpoint: POST /parse-financial-document (statements and transaction screenshots)");
    console.log("  Endpoint: POST /normalize-item-names (optional item-name enrichment)");
    console.log("  Endpoint: POST /analytics/events (client analytics ingestion)");
    console.log("  Admin: GET /admin/analytics");
    console.log("  Health: GET /health\n");
  });
}

export {
  app,
  arbitrateReceiptCandidates,
  buildExtractionDiagnostics,
  buildReceiptFromMistralOcrText,
  buildUploadDiagnostics,
  callMistralOCR,
  compactAppleOcrText,
  compactLocalParseResult,
  detectMimeType,
  extractReceiptMoneyEvidence,
  extractFallbackBankTransactionsFromOcrText,
  fileHash,
  hashIdentifier,
  isLikelyNonItemRow,
  isLikelySuggestedTipRowText,
  normalizeAnalyticsFailureReason,
  normalizeParsedReceipt,
  preserveAnnotationGrandTotal,
  receiptItemsReconcile,
  reconcileReceipt,
  resolveFinancialContradictions,
  sanitizeAnalyticsProperties,
  safeString,
  salvageMistralReceiptAnnotation,
  selectMistralReceiptCandidate,
  shouldPreferOcrTextFallback,
  summarizeAnalytics,
  summaryRoleForLine,
};

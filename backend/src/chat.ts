import Anthropic from "@anthropic-ai/sdk";
import type { Response } from "express";

const client = new Anthropic();

const MODEL = process.env.ANTHROPIC_MODEL || "claude-haiku-5-5";
const EFFORT = (process.env.ANTHROPIC_EFFORT || "medium") as "low" | "medium" | "high" | "xhigh" | "max";
// Server-side refusal fallback; only these models accept the "default" form.
const FALLBACK_MODELS = new Set(["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"]);

const SYSTEM_PROMPT = `You are Runway, a personal budgeting assistant inside an iPhone app. The user has linked their bank and credit card accounts, and the app gives you a JSON snapshot of their finances below: balances, credit card statements and due dates, this month's budget categories, recurring income and bills, recent transactions, and a "safeToSpend" breakdown the app already computed.

How to answer:
- Ground every number in the snapshot. When you do arithmetic, show the short version of the math so the user can check it ("$2,140 in checking + $1,800 paycheck on the 31st - $1,260 owed on cards - $310 in bills left = $2,370").
- The app's safeToSpend figure is the headline answer to "how much can I spend". Start from it, and explain what it already accounts for, rather than recomputing from scratch with different assumptions. If the user's question implies different assumptions (e.g. "if I only pay the statement balance"), say how the number changes.
- The user's goal with credit cards is to never carry a balance into the next statement. For card questions, name each card, its statement balance, the due date, and what to pay by when. Distinguish the statement balance (pay this to avoid interest) from new spending since the statement (due next cycle). If cash won't cover everything, propose a concrete plan: which card to pay first (highest APR, or soonest due date if APRs are unknown), and which flexible categories to trim, by how much, to close the gap.
- When the user wants to do something specific ("can I afford a $300 weekend trip?"), give a clear yes / no / yes-if, and the trade-off it implies for the rest of the month.
- Be concise and warm. This is a phone chat bubble: a few short paragraphs or a short "- " list, no headings, no tables. Bold the one key number with **double asterisks**.
- Don't invent accounts, transactions, or income that aren't in the snapshot. If data is missing (e.g. no recurring income detected yet), say what you assumed.
- You are not a licensed financial advisor; you don't need to say so unless asked about investing, taxes, or debt products.`;

export interface ChatRequestBody {
  messages: { role: "user" | "assistant"; content: string }[];
  context: unknown;
}

function send(res: Response, payload: Record<string, unknown>) {
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

/** Streams the reply to the client as server-sent events:
 * {type:"text",text} chunks, then {type:"done"} or {type:"error",message}. */
export async function streamChat(body: ChatRequestBody, res: Response) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });

  const messages = body.messages
    .filter((m) => m.content.trim().length > 0)
    .slice(-30)
    .map((m) => ({ role: m.role, content: m.content }));

  try {
    const stream = client.beta.messages.stream({
      model: MODEL,
      max_tokens: 16000,
      thinking: { type: "adaptive" },
      output_config: { effort: EFFORT },
      ...(FALLBACK_MODELS.has(MODEL) ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const } : {}),
      system: [
        { type: "text", text: SYSTEM_PROMPT },
        {
          type: "text",
          text: `<financial_snapshot>\n${JSON.stringify(body.context)}\n</financial_snapshot>`,
          cache_control: { type: "ephemeral" },
        },
      ],
      messages,
    });

    for await (const event of stream) {
      if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
        send(res, { type: "text", text: event.delta.text });
      }
    }
    const final = await stream.finalMessage();
    if (final.stop_reason === "refusal") {
      send(res, { type: "error", message: "I can't help with that one. Try asking about your budget or cards." });
    } else {
      send(res, { type: "done" });
    }
  } catch (err) {
    console.error("chat failed", err);
    const message =
      err instanceof Anthropic.RateLimitError
        ? "Too many requests right now. Try again in a moment."
        : err instanceof Anthropic.AuthenticationError
          ? "The server's Claude API key is missing or invalid."
          : "Something went wrong reaching Claude.";
    send(res, { type: "error", message });
  } finally {
    res.end();
  }
}

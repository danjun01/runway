import "dotenv/config";
import express, { type NextFunction, type Request, type Response } from "express";
import { createLinkToken, exchangePublicToken, plaidEnv, plaidErrorCode, plaidSecret, snapshot, unlinkItem } from "./plaid.js";
import { streamChat, type ChatRequestBody } from "./chat.js";

const app = express();
app.use(express.json({ limit: "2mb" }));

// The app sends a random per-install id. This identifies a device, it does not
// authenticate a person: put real auth (Sign in with Apple, etc.) in front of
// this before anyone but you uses it.
function userId(req: Request): string {
  const id = req.header("X-Runway-User") ?? "";
  if (!/^[A-Za-z0-9-]{16,64}$/.test(id)) throw Object.assign(new Error("missing X-Runway-User"), { status: 401 });
  return id;
}

const route =
  (fn: (req: Request, res: Response) => Promise<unknown>) => (req: Request, res: Response, next: NextFunction) =>
    fn(req, res).catch(next);

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    plaid: Boolean(process.env.PLAID_CLIENT_ID && plaidSecret),
    plaidEnv,
    claude: Boolean(process.env.ANTHROPIC_API_KEY),
  });
});

app.post(
  "/api/link-token",
  route(async (req, res) => {
    res.json({ linkToken: await createLinkToken(userId(req)) });
  }),
);

app.post(
  "/api/exchange",
  route(async (req, res) => {
    const { publicToken, institutionName } = req.body as { publicToken?: string; institutionName?: string };
    if (!publicToken) return res.status(400).json({ error: "publicToken is required" });
    res.json(await exchangePublicToken(userId(req), publicToken, institutionName ?? ""));
  }),
);

app.get(
  "/api/snapshot",
  route(async (req, res) => {
    res.json(await snapshot(userId(req)));
  }),
);

app.delete(
  "/api/items/:itemId",
  route(async (req, res) => {
    await unlinkItem(userId(req), String(req.params.itemId));
    res.status(204).end();
  }),
);

app.post(
  "/api/chat",
  route(async (req, res) => {
    userId(req);
    const body = req.body as ChatRequestBody;
    if (!Array.isArray(body?.messages) || body.messages.length === 0) {
      return res.status(400).json({ error: "messages is required" });
    }
    await streamChat(body, res);
  }),
);

app.use((err: Error & { status?: number }, _req: Request, res: Response, _next: NextFunction) => {
  const code = plaidErrorCode(err);
  console.error(code ?? err.message);
  res.status(err.status ?? (code ? 502 : 500)).json({ error: code ?? err.message });
});

const port = Number(process.env.PORT ?? 8787);
app.listen(port, "0.0.0.0", () => console.log(`Runway backend on http://localhost:${port} (Plaid ${plaidEnv})`));

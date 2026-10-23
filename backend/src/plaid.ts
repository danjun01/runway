import {
  Configuration,
  CountryCode,
  PlaidApi,
  PlaidEnvironments,
  Products,
  type AccountBase,
  type CreditCardLiability,
  type TransactionStream,
} from "plaid";
import { addItem, itemsFor, removeItem, saveItems, type StoredItem } from "./store.js";

// The Plaid SDK quietly falls back to production for an unknown name, so a
// typo would send sandbox keys to production. Fail at startup instead.
export const plaidEnv = (process.env.PLAID_ENV || "sandbox").trim().toLowerCase();
if (!(plaidEnv in PlaidEnvironments)) {
  throw new Error(`PLAID_ENV must be one of ${Object.keys(PlaidEnvironments).join(", ")} (got "${process.env.PLAID_ENV}")`);
}
const env = plaidEnv;

// Plaid issues a different secret per environment. Keep both in .env as
// PLAID_SECRET_SANDBOX and PLAID_SECRET_PRODUCTION and switching is just
// PLAID_ENV; a plain PLAID_SECRET still works for a single environment.
export const plaidSecret = process.env[`PLAID_SECRET_${plaidEnv.toUpperCase()}`] || process.env.PLAID_SECRET || "";

const plaid = new PlaidApi(
  new Configuration({
    basePath: PlaidEnvironments[env],
    baseOptions: {
      headers: {
        "PLAID-CLIENT-ID": process.env.PLAID_CLIENT_ID ?? "",
        "PLAID-SECRET": plaidSecret,
      },
    },
  }),
);

export function plaidErrorCode(err: unknown): string | undefined {
  return (err as { response?: { data?: { error_code?: string } } }).response?.data?.error_code;
}

export async function createLinkToken(userId: string): Promise<string> {
  const res = await plaid.linkTokenCreate({
    user: { client_user_id: userId },
    client_name: "Runway",
    language: "en",
    country_codes: [CountryCode.Us],
    products: [Products.Transactions],
    // Credit card statement balances and due dates. Banks without credit
    // accounts still show up in Link.
    required_if_supported_products: [Products.Liabilities],
    // Recurring-transaction detection wants at least 180 days of history.
    transactions: { days_requested: 365 },
    redirect_uri: process.env.PLAID_REDIRECT_URI || undefined,
  });
  return res.data.link_token;
}

export async function exchangePublicToken(userId: string, publicToken: string, institutionName: string) {
  const res = await plaid.itemPublicTokenExchange({ public_token: publicToken });
  addItem(userId, {
    itemId: res.data.item_id,
    accessToken: res.data.access_token,
    institutionName: institutionName || "Bank",
    transactions: {},
  });
  return { itemId: res.data.item_id };
}

export async function unlinkItem(userId: string, itemId: string) {
  const item = removeItem(userId, itemId);
  if (item) await plaid.itemRemove({ access_token: item.accessToken }).catch(() => {});
}

async function syncTransactions(item: StoredItem): Promise<AccountBase[]> {
  let cursor = item.cursor;
  let accounts: AccountBase[] = [];
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const pending: StoredItem["transactions"] = {};
      const removed = new Set<string>();
      let hasMore = true;
      while (hasMore) {
        const { data } = await plaid.transactionsSync({ access_token: item.accessToken, cursor, count: 500 });
        for (const t of [...data.added, ...data.modified]) pending[t.transaction_id] = t;
        for (const r of data.removed) if (r.transaction_id) removed.add(r.transaction_id);
        accounts = data.accounts;
        hasMore = data.has_more;
        cursor = data.next_cursor;
      }
      Object.assign(item.transactions, pending);
      for (const id of removed) delete item.transactions[id];
      item.cursor = cursor;
      return accounts;
    } catch (err) {
      // Plaid asks clients to restart pagination from the last saved cursor.
      if (plaidErrorCode(err) !== "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION") throw err;
      cursor = item.cursor;
    }
  }
  return accounts;
}

async function liabilitiesFor(item: StoredItem): Promise<CreditCardLiability[]> {
  try {
    const { data } = await plaid.liabilitiesGet({ access_token: item.accessToken });
    return data.liabilities.credit ?? [];
  } catch {
    // Not every institution supports Liabilities; card balances still come through accounts.
    return [];
  }
}

async function recurringFor(item: StoredItem): Promise<{ inflow: TransactionStream[]; outflow: TransactionStream[] }> {
  try {
    const { data } = await plaid.transactionsRecurringGet({ access_token: item.accessToken });
    return { inflow: data.inflow_streams, outflow: data.outflow_streams };
  } catch {
    // PRODUCT_NOT_READY right after linking, or not enough history yet.
    return { inflow: [], outflow: [] };
  }
}

const HISTORY_DAYS = 180;

// Access tokens are tied to the environment they were created in
// (access-sandbox-..., access-production-...). After switching PLAID_ENV, items
// from the other environment would fail with INVALID_ACCESS_TOKEN, so leave
// them out until PLAID_ENV is switched back.
const inCurrentEnv = (item: StoredItem) => item.accessToken.startsWith(`access-${plaidEnv}-`);

/** Everything the app needs, normalized to camelCase. Transaction amounts keep
 * Plaid's sign: positive is money leaving the account. */
export async function snapshot(userId: string) {
  const items = itemsFor(userId).filter(inCurrentEnv);
  const cutoff = new Date(Date.now() - HISTORY_DAYS * 86_400_000).toISOString().slice(0, 10);

  const perItem = await Promise.all(
    items.map(async (item) => {
      const [syncedAccounts, credit, recurring] = await Promise.all([
        syncTransactions(item),
        liabilitiesFor(item),
        recurringFor(item),
      ]);
      // transactions/sync returns accounts only when something changed, so fall back to balance.
      const accounts = syncedAccounts.length
        ? syncedAccounts
        : (await plaid.accountsGet({ access_token: item.accessToken })).data.accounts;
      return { item, accounts, credit, recurring };
    }),
  );
  saveItems();

  return {
    syncedAt: new Date().toISOString(),
    institutions: items.map((i) => ({ itemId: i.itemId, name: i.institutionName })),
    accounts: perItem.flatMap(({ item, accounts }) =>
      accounts.map((a) => ({
        id: a.account_id,
        itemId: item.itemId,
        institution: item.institutionName,
        name: a.name,
        officialName: a.official_name ?? null,
        mask: a.mask ?? null,
        type: String(a.type),
        subtype: a.subtype ? String(a.subtype) : null,
        currentBalance: a.balances.current,
        availableBalance: a.balances.available,
        limit: a.balances.limit,
        currency: a.balances.iso_currency_code ?? "USD",
      })),
    ),
    transactions: perItem
      .flatMap(({ item }) => Object.values(item.transactions))
      .filter((t) => t.date >= cutoff)
      .sort((a, b) => (a.date < b.date ? 1 : -1))
      .map((t) => ({
        id: t.transaction_id,
        accountId: t.account_id,
        date: t.date,
        name: t.name,
        merchant: t.merchant_name ?? null,
        amount: t.amount,
        category: t.personal_finance_category?.primary ?? "OTHER",
        detailedCategory: t.personal_finance_category?.detailed ?? null,
        pending: t.pending,
        pendingTransactionId: t.pending_transaction_id ?? null,
        logoUrl: t.logo_url ?? null,
      })),
    creditCards: perItem.flatMap(({ credit }) =>
      credit
        .filter((c) => c.account_id)
        .map((c) => ({
          accountId: c.account_id!,
          lastStatementBalance: c.last_statement_balance,
          lastStatementDate: c.last_statement_issue_date,
          nextPaymentDueDate: c.next_payment_due_date,
          minimumPayment: c.minimum_payment_amount,
          lastPaymentAmount: c.last_payment_amount,
          lastPaymentDate: c.last_payment_date,
          isOverdue: c.is_overdue ?? false,
          purchaseApr: c.aprs.find((a) => String(a.apr_type) === "purchase_apr")?.apr_percentage ?? null,
        })),
    ),
    recurring: perItem.flatMap(({ recurring }) => [
      ...recurring.inflow.map((s) => stream(s, "inflow")),
      ...recurring.outflow.map((s) => stream(s, "outflow")),
    ]),
  };
}

function stream(s: TransactionStream, direction: "inflow" | "outflow") {
  return {
    id: s.stream_id,
    accountId: s.account_id,
    direction,
    description: s.description,
    merchant: s.merchant_name,
    averageAmount: Math.abs(s.average_amount.amount ?? 0),
    lastAmount: Math.abs(s.last_amount.amount ?? 0),
    frequency: String(s.frequency),
    lastDate: s.last_date,
    predictedNextDate: s.predicted_next_date ?? null,
    category: s.personal_finance_category?.primary ?? null,
    detailedCategory: s.personal_finance_category?.detailed ?? null,
    isActive: s.is_active,
    transactionIds: s.transaction_ids,
  };
}

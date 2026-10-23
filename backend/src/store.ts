import fs from "node:fs";
import path from "node:path";
import type { Transaction } from "plaid";

// A single-file JSON store. Good enough for a personal deployment; swap for
// Postgres (or similar) before this holds more than a handful of users.

export interface StoredItem {
  itemId: string;
  accessToken: string;
  institutionName: string;
  cursor?: string;
  transactions: Record<string, Transaction>;
}

interface StoreShape {
  users: Record<string, { items: StoredItem[] }>;
}

const DATA_DIR = process.env.RUNWAY_DATA_DIR ?? path.resolve("data");
const FILE = path.join(DATA_DIR, "store.json");

let cache: StoreShape | undefined;

function load(): StoreShape {
  if (cache) return cache;
  try {
    cache = JSON.parse(fs.readFileSync(FILE, "utf8")) as StoreShape;
  } catch {
    cache = { users: {} };
  }
  return cache;
}

function persist() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const tmp = `${FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(cache), { mode: 0o600 });
  fs.renameSync(tmp, FILE);
}

export function itemsFor(userId: string): StoredItem[] {
  return load().users[userId]?.items ?? [];
}

export function addItem(userId: string, item: StoredItem) {
  const db = load();
  const user = (db.users[userId] ??= { items: [] });
  user.items = user.items.filter((i) => i.itemId !== item.itemId);
  user.items.push(item);
  persist();
}

export function removeItem(userId: string, itemId: string): StoredItem | undefined {
  const user = load().users[userId];
  const item = user?.items.find((i) => i.itemId === itemId);
  if (user && item) {
    user.items = user.items.filter((i) => i.itemId !== itemId);
    persist();
  }
  return item;
}

export function saveItems() {
  persist();
}

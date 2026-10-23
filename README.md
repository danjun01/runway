# Runway

A budgeting app for iPhone that answers the question budgeting apps usually don't: **how much can I actually spend for the rest of the month?**

Link your bank and credit cards once during onboarding. Runway pulls transactions automatically, builds a starting budget from how you really spend, and keeps a single **Safe to spend** number up to date. The **Ask** tab is a Claude-powered chat that sees your balances, card statements, bills, and spending, so you can ask things like:

- "How much do I have to play with for the rest of the month?"
- "How should I pay my credit cards so I don't carry a balance?"
- "Can I afford a $300 weekend trip and still pay everything off?"

## How it's built

```
ios/       SwiftUI app (iOS 17+), generated with XcodeGen
backend/   Node + TypeScript server: Plaid token exchange, data sync, Claude chat
```

The backend exists because Plaid and Claude API keys must never ship inside an app. It:

- creates Plaid Link tokens and exchanges public tokens for access tokens (stored server side only),
- syncs transactions, balances, credit card liabilities (statement balance, due date, APR) and recurring income/bills from Plaid,
- streams Claude's answers back to the app over server-sent events.

The app does all of the budgeting math itself (`ios/Runway/Services/BudgetEngine.swift`) and sends Claude a compact snapshot with the numbers already worked out, so answers are grounded in exact figures.

### How "Safe to spend" works

```
  cash in checking
+ paychecks expected before month end   (from Plaid's recurring-income detection)
- full current balance of every credit card
- budgeted bills not yet paid this month
- your monthly savings goal (optional, set in Accounts)
= safe to spend, shown with a per-day amount
```

Reserving the *whole* card balance (not just the minimum) is what keeps you from ever carrying a statement balance: anything you put on a card is treated as already spent. Each card also shows exactly what to pay, and by when, to avoid interest.

## Run it on your Mac

You need Xcode 16 or newer, Node 20+, and [Homebrew](https://brew.sh).

### 1. Try it right away with demo data

```sh
brew install xcodegen
cd ios
xcodegen generate
open Runway.xcodeproj
```

Pick an iPhone simulator, press Run, go through onboarding, and tap **Explore with demo data**. The budget, cards, and activity screens work fully offline. The Ask tab needs the backend (step 2) with a Claude API key.

### 2. Start the backend

```sh
cd backend
cp .env.example .env     # then fill in the keys below
npm install
npm run dev              # http://localhost:8787
```

| Key | Where to get it |
| --- | --- |
| `ANTHROPIC_API_KEY` | [platform.claude.com](https://platform.claude.com/settings/keys) |
| `PLAID_CLIENT_ID`, `PLAID_SECRET` | [Plaid dashboard](https://dashboard.plaid.com/developers/keys). Sandbox keys are free. |
| `ANTHROPIC_MODEL` | Optional. Defaults to `claude-opus-5-5`; set `claude-sonnet-5-5` to cut the chat cost roughly in half. |
| `ANTHROPIC_EFFORT` | Optional. `medium` by default; `low` is cheaper and faster, `high` thinks longer. |
| `PLAID_ENV` | `sandbox` while testing, `production` for your real banks |

Check it with `curl localhost:8787/health`.

### 3. Link a bank

Run the app in the simulator and tap **Connect a bank**. In sandbox, pick any bank and sign in with `user_good` / `pass_good`. Sandbox history can take a few seconds to appear; pull to refresh if the budget looks empty.

To use your real accounts, request Production access in the Plaid dashboard, set `PLAID_ENV=production` and the production secret, then restart the backend. Many big banks (Chase, Bank of America, and others) use OAuth, which on iOS needs a registered redirect URI: set `PLAID_REDIRECT_URI` to an https universal link for the app and add it in the Plaid dashboard. See [Plaid's OAuth guide](https://plaid.com/docs/link/oauth/).

### On a physical iPhone

1. In Xcode, select the Runway target, open **Signing & Capabilities**, and choose your team.
2. The phone can't reach `localhost` on your Mac. In the app, open **Accounts → Server** and enter your Mac's address, e.g. `http://your-mac-name.local:8787` (find the name in System Settings → General → Sharing). Or change `RUNWAY_API_BASE_URL` in `ios/project.yml` and regenerate.

## Tests

```sh
cd ios && xcodegen generate && xcodebuild test -project Runway.xcodeproj -scheme Runway -destination 'platform=iOS Simulator,name=iPhone 16'
cd backend && npm run typecheck
```

CI runs both on every push (`.github/workflows/ci.yml`).

## Before anyone else uses it

This is set up for one person running their own backend. Before sharing it:

- **Auth.** The app identifies itself with a random per-install id (`X-Runway-User`). That isn't authentication. Add Sign in with Apple (or similar) and verify it on the server.
- **Storage.** Plaid access tokens live in `backend/data/store.json`. Move them to a real database with encryption at rest.
- **Hosting.** Deploy the backend somewhere with HTTPS (Fly.io, Render, Railway) and point `RUNWAY_API_BASE_URL` at it.
- **Webhooks.** Add Plaid's `SYNC_UPDATES_AVAILABLE` webhook so new transactions arrive without a manual refresh.

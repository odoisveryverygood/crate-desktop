# Desktop AI gateway

Cloudflare Worker + SQLite Durable Object for signed installation sessions, Jev plans and GPT-4.1 mini arrangements. Clients consent before using AI. Provider keys remain server-side. Requests use canonical music schemas, `store: false`, output caps and transactional per-installation, IP and global quotas. Anonymous installation sessions support a bounded beta, not a unique-human account or billing entitlement.

Routes: `POST /api/session`, `POST /api/ai/jev`, `POST /api/ai/openai`. AI calls require the issued `x-crate-token`. No provider response bodies are logged or returned on failure.

To deploy your own instance, install Wrangler, authenticate to your own Cloudflare account, choose your own Worker name in wrangler.toml and set OPENAI_API_KEY, TYPESAFE_API_KEY and SESSION_SECRET using Wrangler secret input. Do not commit `.dev.vars`, `.env` or provider credentials. Configure the app endpoint for your deployment. This repository does not deploy anything automatically.

Test from the repository root: `node --test desktop-worker/test/gateway.test.js`. Tests cover signed-session validation, registration and request bounds, canonical provider contracts, model restrictions, concurrent quota reservations and error redaction.

Defaults: 1,000 GPT / 5,000 Jev calls shared daily, 50 GPT / 200 Jev per installation daily, plus IP and minute caps. Request caps are not a guaranteed dollar spending cap.

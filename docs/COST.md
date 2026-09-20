# Cost and Service Limits

The infrastructure is currently designed to use 100% free-tier services. No paid services are used today.

## Storage (Postgres)
- **Current Users:** ~3
- **Usage Estimate:** ~1KB/message (including indexes)
- **Growth Estimate:** ~50-100MB/year at heavy use.
- **Service Used:** [TBD: e.g., Render Free Tier]
- **Free Tier Limit:** Typically limits exist on total size (e.g. 500MB - 1GB depending on the provider).
- **Note:** Retention is currently deferred. Refer to ADR 0001 for the threshold to revisit database size monitoring.

## Application Hosting
- **Service Used:** [TBD: e.g., Render / Fly.io Free Tier]
- **Free Tier Limit:** Limited hours/month or RAM (e.g., 512MB RAM, spins down on idle).
- **Note:** Expect cold starts due to idle-sleep behaviors. The app uses stateless ASGI workers and Redis channel layer.

## Redis (Channels)
- **Service Used:** [TBD: e.g., Upstash / Render Free Tier]
- **Free Tier Limit:** Limited requests per day or max connections (e.g., Upstash allows 10,000 req/day on free tier).

## CI/CD
- **Service Used:** GitHub Actions
- **Free Tier Limit:** 2,000 CI/CD minutes per month (free for public/private repos).

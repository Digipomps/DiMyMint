# Stripe entitlement provider v0

## Scope

The provider records tightly bound Stripe test-mode payment evidence for a later Agreement-authorized service entitlement. A payment confirmation is not an access capability and does not issue anything by itself.

The only v0 product kinds are `access_entitlement` and `usage_quota`. Both are service-local, non-transferable, have no cash-out, and are not designed for acceptance outside the service that issued them. This work is not legal advice and does not determine the regulatory classification of a future product.

The existing public DiMyMint HTTP routes remain disabled. This provider has no public route, no production Stripe configuration, no deployment path, and no automatic entitlement issuance. Wallet, stored-value, transfer, redemption, reserve, payout, Stripe Connect, automatic refund, and revocation behavior are outside this change.

## Fail-closed contract

- Only `sk_test_` configuration and `cs_test_` Checkout sessions are accepted. Live-mode keys or responses fail startup or validation.
- The deterministic binding covers provider, test mode, account, order, subject, Agreement, product kind, amount, currency, return URLs, and all three v0 scope restrictions.
- Session creation uses the same deterministic idempotency key after a crash or provider timeout. Provider responses must repeat the full binding.
- Webhook verification uses the exact raw bytes, Stripe HMAC, one timestamp, one lowercase SHA-256 signature, a maximum five-minute tolerance, and a delivery replay digest.
- Provider event ID, account, session, order, amount, currency, subject, Agreement, product kind, state and binding must all match.
- The PostgreSQL function serializes the order and provider event inside one transaction. Exact retries are duplicates; a later second paid event is an economic duplicate; conflicts and out-of-order events fail closed.
- Persistence stores only bounded parsed fields and SHA-256 digests, never the raw webhook body, request headers, provider secret, or signing material.
- A confirmed event may only request a later entitlement-issuance decision. Agreement and capability enforcement remain separate authority gates.

## Verification

Run the portable source and test gate without GitHub Actions:

```sh
scripts/verify-stripe-entitlement-provider.sh local
```

An external clean-checkout runner must bind the checkout to its expected commit:

```sh
DIMYMINT_EXPECTED_SOURCE_SHA="$(git rev-parse HEAD)" \
scripts/verify-stripe-entitlement-provider.sh external
```

Release certification additionally requires a disposable PostgreSQL database. The database must contain no shared or production data:

```sh
DIMYMINT_EXPECTED_SOURCE_SHA="$(git rev-parse HEAD)" \
DIMYMINT_TEST_POSTGRES_URL='postgresql://…/disposable_database?sslmode=require&minimum_connections=1&maximum_connections=20' \
DIMYMINT_TEST_POSTGRES_PSQL_URL='postgresql://…/disposable_database?sslmode=require' \
DIMYMINT_TEST_POSTGRES_DISPOSABLE=YES \
scripts/verify-stripe-entitlement-provider.sh release
```

The release gate applies `db/migrations/0002_stripe_entitlement_provider_v0.sql`, runs the 16-way concurrency/replay integration test, and then verifies exact duplicates, event conflicts, economic duplicates and out-of-order rejection. Absence of a real PostgreSQL run is an explicit non-release result.

The CI workflow runs this real database gate on every relevant pull request. With PostgreSQL tools on `PATH`, a clean checkout can run the same isolated gate:

```sh
DIMYMINT_EXPECTED_SOURCE_SHA="$(git rev-parse HEAD)" \
python3 scripts/verify-stripe-disposable-postgres.py
```

The wrapper creates a fresh cluster on a random loopback port, ignores inherited PostgreSQL connection settings, and stops only its own server on completion or failure. It preserves its temporary synthetic data, server log and JSON receipt for diagnosis. It uses local trust authentication only on an isolated test runner. This is not a production database configuration. Swift builds use two jobs. See [PostgreSQL's pg_ctl documentation](https://www.postgresql.org/docs/current/app-pg-ctl.html) for server lifecycle behavior.

Neither PostgreSQL URL may contain a password. The psql URL omits Swift pool parameters that libpq does not understand. Supply authentication separately through a private `.pgpass`, client certificate, or local peer authentication so credentials never appear in process arguments or test output.

## Operational hard stops

Do not expose or deploy this provider until all of the following are independently green:

1. A reviewed application route authenticates the subject and verifies the exact Agreement before constructing an order.
2. A reviewed webhook ingress preserves raw bytes and passes them only to this verifier.
3. The runtime database role receives only the narrowly required table/function grants; `PUBLIC` execution remains revoked.
4. A real PostgreSQL release gate is retained as evidence for the exact source commit.
5. Stripe test-mode end-to-end evidence binds the expected account, session, order and subject. No live-mode call is permitted in v0.
6. The regulatory/product decision is re-evaluated before adding transferability, stored value, external acceptance, cash-out, refunds, revocation or a broader product kind.

## Primary references

- [Stripe: verify webhook signatures](https://docs.stripe.com/webhooks/signature)
- [Stripe: fulfill Checkout orders and handle asynchronous payment](https://docs.stripe.com/checkout/fulfillment)
- [Stripe: idempotent requests](https://docs.stripe.com/api/idempotent_requests)
- [Finanstilsynet: betalingstjenester](https://www.finanstilsynet.no/tillatelser/betalingstjenester/)
- [Finanstilsynet: e-pengeforetak](https://www.finanstilsynet.no/tillatelser/e-pengeforetak/)

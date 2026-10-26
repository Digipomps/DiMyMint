# DiMyMint

Reference mint, funding ledger and test-mode payment-evidence components for the
HAVEN framework, maintained by Digipomps.

## Modules

- `DiMyMintCore`: issuance/redemption abstractions, funding models and Stripe test-mode entitlement evidence.
- `DiMyMintPersistence`: PostgreSQL adapters and entitlement-provider storage.
- `DiMyMintHTTP`: JSON handlers and a default-closed legacy router.
- `DiMyMintServer`: standalone development server.

Requires Swift 5.9 or later and macOS 13 or iOS 16 or later for library products.
The package depends on the public
[DiMyMicropayments](https://github.com/Digipomps/DiMyMicropayments) package.

```swift
.package(url: "https://github.com/Digipomps/DiMyMint.git",
         .upToNextMinor(from: "2026.10.1"))
```

## Status and boundaries

This is reference/development code, not a production monetary service. The
public MintHTTPRouter constructor exposes no legacy monetary routes. Existing
core mint signing defaults are development placeholders. The Stripe entitlement
provider accepts test-mode configuration only, has no public application route,
and does not automatically issue an entitlement or capability.

Publishing this code does not publish production credentials, grant access to an
official DiMy service, authorize issuance accepted by DiMy, or establish legal
permission to operate a payment service.

## Tests

```sh
swift test --disable-automatic-resolution --jobs 2
```

For a complete source gate, including an isolated PostgreSQL cluster, install
PostgreSQL test tools (`initdb`, `pg_ctl`, `createdb`, `psql`) and run:

```sh
DIMYMINT_EXPECTED_SOURCE_SHA="$(git rev-parse HEAD)" \
python3 scripts/verify-stripe-disposable-postgres.py
```

The wrapper creates only a new disposable database, runs migrations and tests,
stops its server and retains a diagnostic receipt. It does not use an existing
production or shared database. See [provider documentation](docs/stripe-entitlement-provider-v0.md).

## Technical documentation

- [Stripe entitlement-provider contract and verification](docs/stripe-entitlement-provider-v0.md)
- [Database migrations](db/migrations/)
- [Dependency baseline](scripts/dependency-baseline.json)

Version `2026.10.1` starts this public repository's release line.

## License and official services

The source code and technical documentation in this repository, including its
DiMy modules, are licensed under Apache License 2.0. See [LICENSE](LICENSE) and
[NOTICE](NOTICE). Digipomps maintains this repository as part of HAVEN.
[GOVERNANCE.md](GOVERNANCE.md) describes official releases;
[TRADEMARK.md](TRADEMARK.md) covers names and certification marks. Those policies
do not add restrictions to the Apache code license. The license does not grant
access to official hosted services or private signing keys, or authority to
issue value accepted by DiMy. Dependencies retain their own license terms.

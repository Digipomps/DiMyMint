create extension if not exists pgcrypto;

create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create or replace function forbid_append_only_mutation()
returns trigger
language plpgsql
as $$
begin
    raise exception 'table % is append-only; updates and deletes are not allowed', tg_table_name;
end;
$$;

create table if not exists wallets (
    wallet_id uuid primary key default gen_random_uuid(),
    customer_id text not null,
    currency char(3) not null default 'NOK',
    status text not null default 'active',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    closed_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_wallets_currency_upper check (currency = upper(currency)),
    constraint ck_wallets_status check (status in ('active', 'suspended', 'closed'))
);

create unique index if not exists uq_wallets_customer_currency
    on wallets(customer_id, currency);

create trigger trg_wallets_set_updated_at
before update on wallets
for each row execute function set_updated_at();

create table if not exists product_catalog_items (
    product_id text primary key,
    product_type text not null,
    title text not null,
    description text,
    unit_price_nok_ore bigint not null,
    currency char(3) not null default 'NOK',
    tax_code text not null,
    tax_behavior text not null,
    is_active boolean not null default true,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint ck_product_catalog_items_unit_price_nonnegative check (unit_price_nok_ore >= 0),
    constraint ck_product_catalog_items_currency_upper check (currency = upper(currency)),
    constraint ck_product_catalog_items_tax_behavior
        check (tax_behavior in ('inclusive', 'exclusive', 'exempt'))
);

create trigger trg_product_catalog_items_set_updated_at
before update on product_catalog_items
for each row execute function set_updated_at();

create table if not exists price_quotes (
    quote_id uuid primary key default gen_random_uuid(),
    wallet_id uuid references wallets(wallet_id),
    customer_id text not null,
    product_id text not null references product_catalog_items(product_id),
    resource_id text,
    quantity integer not null default 1,
    amount_nok_ore bigint not null,
    unit_name text not null default 'NOK_ORE',
    unit_amount bigint not null,
    tax_code text not null,
    tax_behavior text not null,
    expires_at timestamptz not null,
    created_at timestamptz not null default now(),
    locked_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_price_quotes_quantity_positive check (quantity > 0),
    constraint ck_price_quotes_amount_nonnegative check (amount_nok_ore >= 0),
    constraint ck_price_quotes_unit_amount_nonnegative check (unit_amount >= 0),
    constraint ck_price_quotes_tax_behavior
        check (tax_behavior in ('inclusive', 'exclusive', 'exempt'))
);

create index if not exists idx_price_quotes_wallet_id
    on price_quotes(wallet_id);

create index if not exists idx_price_quotes_customer_id
    on price_quotes(customer_id);

create index if not exists idx_price_quotes_expires_at
    on price_quotes(expires_at);

create table if not exists provider_payments (
    provider_payment_id uuid primary key default gen_random_uuid(),
    provider text not null,
    provider_payment_ref text not null,
    wallet_id uuid references wallets(wallet_id),
    customer_id text not null,
    quote_id uuid references price_quotes(quote_id),
    currency char(3) not null default 'NOK',
    requested_amount_nok_ore bigint not null,
    captured_amount_nok_ore bigint not null default 0,
    refunded_amount_nok_ore bigint not null default 0,
    disputed_amount_nok_ore bigint not null default 0,
    fee_amount_nok_ore bigint not null default 0,
    net_settlement_amount_nok_ore bigint not null default 0,
    status text not null default 'initiated',
    provider_session_url text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_provider_payments_provider check (provider in ('stripe', 'vipps')),
    constraint ck_provider_payments_currency_upper check (currency = upper(currency)),
    constraint ck_provider_payments_status
        check (
            status in (
                'initiated',
                'authorized',
                'captured',
                'failed',
                'partially_refunded',
                'refunded',
                'disputed',
                'reversed',
                'settled'
            )
        ),
    constraint ck_provider_payments_requested_nonnegative check (requested_amount_nok_ore >= 0),
    constraint ck_provider_payments_captured_nonnegative check (captured_amount_nok_ore >= 0),
    constraint ck_provider_payments_refunded_nonnegative check (refunded_amount_nok_ore >= 0),
    constraint ck_provider_payments_disputed_nonnegative check (disputed_amount_nok_ore >= 0),
    constraint ck_provider_payments_fee_nonnegative check (fee_amount_nok_ore >= 0),
    constraint ck_provider_payments_net_nonnegative check (net_settlement_amount_nok_ore >= 0)
);

create unique index if not exists uq_provider_payments_provider_ref
    on provider_payments(provider, provider_payment_ref);

create index if not exists idx_provider_payments_wallet_id
    on provider_payments(wallet_id);

create index if not exists idx_provider_payments_customer_id
    on provider_payments(customer_id);

create trigger trg_provider_payments_set_updated_at
before update on provider_payments
for each row execute function set_updated_at();

create table if not exists provider_events_raw (
    provider_event_id uuid primary key default gen_random_uuid(),
    provider text not null,
    provider_event_ref text not null,
    provider_payment_ref text,
    event_type text not null,
    event_created_at timestamptz not null,
    received_at timestamptz not null default now(),
    signature_verified boolean not null,
    request_headers jsonb not null default '{}'::jsonb,
    payload jsonb not null default '{}'::jsonb,
    raw_body bytea not null,
    payload_sha256 text not null,
    processing_status text not null default 'pending',
    processed_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_provider_events_raw_provider check (provider in ('stripe', 'vipps')),
    constraint ck_provider_events_raw_processing_status
        check (processing_status in ('pending', 'processed', 'ignored', 'failed'))
);

create unique index if not exists uq_provider_events_raw_provider_ref
    on provider_events_raw(provider, provider_event_ref);

create index if not exists idx_provider_events_raw_payment_ref
    on provider_events_raw(provider_payment_ref);

create table if not exists cash_events (
    cash_event_id uuid primary key default gen_random_uuid(),
    provider_payment_id uuid references provider_payments(provider_payment_id),
    provider_event_id uuid references provider_events_raw(provider_event_id),
    wallet_id uuid references wallets(wallet_id),
    customer_id text not null,
    provider text not null,
    event_type text not null,
    currency char(3) not null default 'NOK',
    gross_amount_nok_ore bigint not null default 0,
    fee_amount_nok_ore bigint not null default 0,
    net_amount_nok_ore bigint not null default 0,
    idempotency_key text,
    occurred_at timestamptz not null,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_cash_events_provider check (provider in ('stripe', 'vipps', 'system')),
    constraint ck_cash_events_event_type
        check (
            event_type in (
                'payment_initiated',
                'payment_authorized',
                'payment_captured',
                'payment_failed',
                'payment_refunded',
                'payment_disputed',
                'payment_reversed',
                'provider_fee_reported',
                'settlement_paid'
            )
        ),
    constraint ck_cash_events_currency_upper check (currency = upper(currency)),
    constraint ck_cash_events_gross_nonnegative check (gross_amount_nok_ore >= 0),
    constraint ck_cash_events_fee_nonnegative check (fee_amount_nok_ore >= 0),
    constraint ck_cash_events_net_nonnegative check (net_amount_nok_ore >= 0)
);

create index if not exists idx_cash_events_provider_payment_id
    on cash_events(provider_payment_id);

create index if not exists idx_cash_events_wallet_id
    on cash_events(wallet_id);

create index if not exists idx_cash_events_customer_id
    on cash_events(customer_id);

create unique index if not exists uq_cash_events_idempotency_key
    on cash_events(idempotency_key)
    where idempotency_key is not null;

create trigger trg_cash_events_forbid_update
before update or delete on cash_events
for each row execute function forbid_append_only_mutation();

create table if not exists wallet_balance_projections (
    wallet_id uuid primary key references wallets(wallet_id),
    unit_name text not null default 'NOK_ORE',
    available_units bigint not null default 0,
    reserved_units bigint not null default 0,
    consumed_units bigint not null default 0,
    reversed_units bigint not null default 0,
    expired_units bigint not null default 0,
    available_nok_ore bigint not null default 0,
    reserved_nok_ore bigint not null default 0,
    consumed_nok_ore bigint not null default 0,
    reversed_nok_ore bigint not null default 0,
    expired_nok_ore bigint not null default 0,
    updated_at timestamptz not null default now(),
    constraint ck_wallet_balance_projections_available_units_nonnegative check (available_units >= 0),
    constraint ck_wallet_balance_projections_reserved_units_nonnegative check (reserved_units >= 0),
    constraint ck_wallet_balance_projections_consumed_units_nonnegative check (consumed_units >= 0),
    constraint ck_wallet_balance_projections_reversed_units_nonnegative check (reversed_units >= 0),
    constraint ck_wallet_balance_projections_expired_units_nonnegative check (expired_units >= 0),
    constraint ck_wallet_balance_projections_available_nok_nonnegative check (available_nok_ore >= 0),
    constraint ck_wallet_balance_projections_reserved_nok_nonnegative check (reserved_nok_ore >= 0),
    constraint ck_wallet_balance_projections_consumed_nok_nonnegative check (consumed_nok_ore >= 0),
    constraint ck_wallet_balance_projections_reversed_nok_nonnegative check (reversed_nok_ore >= 0),
    constraint ck_wallet_balance_projections_expired_nok_nonnegative check (expired_nok_ore >= 0)
);

create trigger trg_wallet_balance_projections_set_updated_at
before update on wallet_balance_projections
for each row execute function set_updated_at();

create table if not exists wallet_reservations (
    reservation_id uuid primary key default gen_random_uuid(),
    wallet_id uuid not null references wallets(wallet_id),
    customer_id text not null,
    quote_id uuid references price_quotes(quote_id),
    resource_id text,
    status text not null default 'active',
    reserved_unit_name text not null default 'NOK_ORE',
    reserved_unit_amount bigint not null,
    reserved_nok_ore bigint not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    expires_at timestamptz,
    released_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_wallet_reservations_status
        check (status in ('active', 'released', 'consumed', 'expired', 'cancelled')),
    constraint ck_wallet_reservations_unit_amount_nonnegative check (reserved_unit_amount >= 0),
    constraint ck_wallet_reservations_nok_nonnegative check (reserved_nok_ore >= 0)
);

create index if not exists idx_wallet_reservations_wallet_id
    on wallet_reservations(wallet_id);

create index if not exists idx_wallet_reservations_customer_id
    on wallet_reservations(customer_id);

create trigger trg_wallet_reservations_set_updated_at
before update on wallet_reservations
for each row execute function set_updated_at();

create table if not exists wallet_events (
    value_event_id uuid primary key default gen_random_uuid(),
    wallet_id uuid not null references wallets(wallet_id),
    customer_id text not null,
    quote_id uuid references price_quotes(quote_id),
    cash_event_id uuid references cash_events(cash_event_id),
    provider_payment_id uuid references provider_payments(provider_payment_id),
    reservation_id uuid references wallet_reservations(reservation_id),
    unit_name text not null default 'NOK_ORE',
    unit_amount bigint not null,
    nok_reference_amount_ore bigint not null,
    event_type text not null,
    occurred_at timestamptz not null,
    reversal_of_event_id uuid references wallet_events(value_event_id),
    idempotency_key text,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_wallet_events_event_type
        check (
            event_type in (
                'wallet_credit_granted',
                'wallet_credit_reversed',
                'wallet_reserved',
                'wallet_reservation_released',
                'wallet_consumed',
                'wallet_expired',
                'wallet_writeoff',
                'mint_issued',
                'mint_issue_reversed',
                'mint_redeemed',
                'service_delivered'
            )
        ),
    constraint ck_wallet_events_unit_amount_nonnegative check (unit_amount >= 0),
    constraint ck_wallet_events_nok_nonnegative check (nok_reference_amount_ore >= 0)
);

create index if not exists idx_wallet_events_wallet_id
    on wallet_events(wallet_id);

create index if not exists idx_wallet_events_customer_id
    on wallet_events(customer_id);

create index if not exists idx_wallet_events_cash_event_id
    on wallet_events(cash_event_id);

create index if not exists idx_wallet_events_reservation_id
    on wallet_events(reservation_id);

create unique index if not exists uq_wallet_events_idempotency_key
    on wallet_events(idempotency_key)
    where idempotency_key is not null;

create trigger trg_wallet_events_forbid_update
before update or delete on wallet_events
for each row execute function forbid_append_only_mutation();

create table if not exists mint_issue_batches (
    mint_batch_id uuid primary key default gen_random_uuid(),
    wallet_id uuid not null references wallets(wallet_id),
    customer_id text not null,
    reservation_id uuid not null references wallet_reservations(reservation_id),
    quote_id uuid references price_quotes(quote_id),
    mint_key_id text not null,
    denomination_strategy text not null,
    requested_nok_ore bigint not null,
    issued_nok_ore bigint not null default 0,
    status text not null default 'pending',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    issued_at timestamptz,
    reversed_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_mint_issue_batches_status
        check (
            status in (
                'pending',
                'issued',
                'reversed',
                'redeemed_partial',
                'redeemed_full',
                'failed'
            )
        ),
    constraint ck_mint_issue_batches_requested_nonnegative check (requested_nok_ore >= 0),
    constraint ck_mint_issue_batches_issued_nonnegative check (issued_nok_ore >= 0)
);

create index if not exists idx_mint_issue_batches_wallet_id
    on mint_issue_batches(wallet_id);

create index if not exists idx_mint_issue_batches_reservation_id
    on mint_issue_batches(reservation_id);

create trigger trg_mint_issue_batches_set_updated_at
before update on mint_issue_batches
for each row execute function set_updated_at();

create table if not exists mint_events (
    mint_event_id uuid primary key default gen_random_uuid(),
    mint_batch_id uuid not null references mint_issue_batches(mint_batch_id),
    wallet_id uuid not null references wallets(wallet_id),
    customer_id text not null,
    reservation_id uuid references wallet_reservations(reservation_id),
    value_event_id uuid references wallet_events(value_event_id),
    event_type text not null,
    bundle_hash text,
    merchant_id text,
    merchant_credit_ref text,
    amount_nok_ore bigint not null default 0,
    occurred_at timestamptz not null,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_mint_events_event_type
        check (
            event_type in (
                'issue_requested',
                'issue_confirmed',
                'issue_reversed',
                'redeem_requested',
                'redeem_confirmed',
                'redeem_rejected'
            )
        ),
    constraint ck_mint_events_amount_nonnegative check (amount_nok_ore >= 0)
);

create index if not exists idx_mint_events_batch_id
    on mint_events(mint_batch_id);

create index if not exists idx_mint_events_wallet_id
    on mint_events(wallet_id);

create index if not exists idx_mint_events_bundle_hash
    on mint_events(bundle_hash);

create trigger trg_mint_events_forbid_update
before update or delete on mint_events
for each row execute function forbid_append_only_mutation();

create table if not exists accounting_periods (
    period_id uuid primary key default gen_random_uuid(),
    period_name text not null,
    starts_on date not null,
    ends_on date not null,
    status text not null default 'open',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    closed_at timestamptz,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_accounting_periods_date_order check (starts_on <= ends_on),
    constraint ck_accounting_periods_status check (status in ('open', 'closing', 'closed'))
);

create unique index if not exists uq_accounting_periods_dates
    on accounting_periods(starts_on, ends_on);

create trigger trg_accounting_periods_set_updated_at
before update on accounting_periods
for each row execute function set_updated_at();

create table if not exists journal_entries (
    journal_entry_id uuid primary key default gen_random_uuid(),
    period_id uuid references accounting_periods(period_id),
    entry_type text not null,
    posting_date date not null,
    currency char(3) not null default 'NOK',
    source_document_id text,
    cash_event_id uuid references cash_events(cash_event_id),
    value_event_id uuid references wallet_events(value_event_id),
    reference text,
    description text not null,
    reversal_of_entry_id uuid references journal_entries(journal_entry_id),
    created_at timestamptz not null default now(),
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_journal_entries_entry_type
        check (
            entry_type in (
                'capture',
                'settlement',
                'provider_fee',
                'consumption',
                'refund',
                'chargeback',
                'writeoff',
                'adjustment'
            )
        ),
    constraint ck_journal_entries_currency_upper check (currency = upper(currency))
);

create index if not exists idx_journal_entries_period_id
    on journal_entries(period_id);

create index if not exists idx_journal_entries_cash_event_id
    on journal_entries(cash_event_id);

create index if not exists idx_journal_entries_value_event_id
    on journal_entries(value_event_id);

create trigger trg_journal_entries_forbid_update
before update or delete on journal_entries
for each row execute function forbid_append_only_mutation();

create table if not exists journal_lines (
    journal_line_id uuid primary key default gen_random_uuid(),
    journal_entry_id uuid not null references journal_entries(journal_entry_id),
    line_no integer not null,
    account_no text not null,
    debit_nok_ore bigint not null default 0,
    credit_nok_ore bigint not null default 0,
    customer_id text,
    product_id text references product_catalog_items(product_id),
    tax_code text,
    metadata jsonb not null default '{}'::jsonb,
    constraint ck_journal_lines_debit_nonnegative check (debit_nok_ore >= 0),
    constraint ck_journal_lines_credit_nonnegative check (credit_nok_ore >= 0),
    constraint ck_journal_lines_one_sided check ((debit_nok_ore = 0) <> (credit_nok_ore = 0))
);

create unique index if not exists uq_journal_lines_entry_line_no
    on journal_lines(journal_entry_id, line_no);

create index if not exists idx_journal_lines_account_no
    on journal_lines(account_no);

create trigger trg_journal_lines_forbid_update
before update or delete on journal_lines
for each row execute function forbid_append_only_mutation();

create table if not exists reconciliation_runs (
    reconciliation_run_id uuid primary key default gen_random_uuid(),
    run_type text not null,
    provider text,
    period_id uuid references accounting_periods(period_id),
    status text not null default 'running',
    started_at timestamptz not null default now(),
    finished_at timestamptz,
    summary jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint ck_reconciliation_runs_run_type
        check (run_type in ('provider', 'cash_to_gl', 'value_to_gl', 'mint_control')),
    constraint ck_reconciliation_runs_provider
        check (provider is null or provider in ('stripe', 'vipps')),
    constraint ck_reconciliation_runs_status
        check (status in ('running', 'completed', 'failed'))
);

create trigger trg_reconciliation_runs_set_updated_at
before update on reconciliation_runs
for each row execute function set_updated_at();

create table if not exists reconciliation_items (
    reconciliation_item_id uuid primary key default gen_random_uuid(),
    reconciliation_run_id uuid not null references reconciliation_runs(reconciliation_run_id),
    mismatch_type text not null,
    reference_type text not null,
    reference_id text not null,
    expected_nok_ore bigint,
    actual_nok_ore bigint,
    details jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index if not exists idx_reconciliation_items_run_id
    on reconciliation_items(reconciliation_run_id);

create trigger trg_reconciliation_items_forbid_update
before update or delete on reconciliation_items
for each row execute function forbid_append_only_mutation();

create table if not exists api_idempotency_records (
    request_path text not null,
    idempotency_key text not null,
    request_hash text not null,
    response_status integer,
    response_body jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (request_path, idempotency_key)
);

create trigger trg_api_idempotency_records_set_updated_at
before update on api_idempotency_records
for each row execute function set_updated_at();

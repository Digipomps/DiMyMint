create table if not exists stripe_entitlement_checkout_orders (
    order_id text primary key,
    subject_id text not null,
    agreement_id text not null,
    product_kind text not null,
    provider text not null default 'stripe',
    provider_mode text not null default 'test',
    provider_account_id text not null,
    binding_sha256 char(64) not null,
    idempotency_key text not null unique,
    provider_session_id text unique,
    checkout_url text,
    amount_minor bigint not null,
    currency char(3) not null,
    success_url text not null,
    cancel_url text not null,
    non_transferable boolean not null default true,
    cash_out boolean not null default false,
    external_acceptance boolean not null default false,
    state text not null default 'creating',
    created_at timestamptz not null,
    updated_at timestamptz not null default now(),
    last_provider_event_created_at timestamptz,
    constraint ck_stripe_entitlement_product_kind
        check (product_kind in ('access_entitlement', 'usage_quota')),
    constraint ck_stripe_entitlement_provider check (provider = 'stripe'),
    constraint ck_stripe_entitlement_provider_mode check (provider_mode = 'test'),
    constraint ck_stripe_entitlement_provider_account check (provider_account_id like 'acct\_%'),
    constraint ck_stripe_entitlement_binding_sha check (binding_sha256 ~ '^[0-9a-f]{64}$'),
    constraint ck_stripe_entitlement_session
        check (provider_session_id is null or provider_session_id like 'cs\_test\_%'),
    constraint ck_stripe_entitlement_checkout_url
        check (checkout_url is null or checkout_url like 'https://checkout.stripe.com/%'),
    constraint ck_stripe_entitlement_amount check (amount_minor > 0),
    constraint ck_stripe_entitlement_currency check (currency = upper(currency)),
    constraint ck_stripe_entitlement_success_url check (success_url like 'https://%'),
    constraint ck_stripe_entitlement_cancel_url check (cancel_url like 'https://%'),
    constraint ck_stripe_entitlement_non_transferable check (non_transferable),
    constraint ck_stripe_entitlement_no_cash_out check (not cash_out),
    constraint ck_stripe_entitlement_no_external_acceptance check (not external_acceptance),
    constraint ck_stripe_entitlement_state
        check (state in ('creating', 'awaiting_payment', 'payment_pending', 'payment_confirmed', 'payment_failed'))
);

create table if not exists stripe_entitlement_provider_events (
    provider text not null default 'stripe',
    provider_account_id text not null,
    provider_event_id text not null,
    provider_event_type text not null,
    provider_event_created_at timestamptz not null,
    order_id text not null references stripe_entitlement_checkout_orders(order_id),
    provider_session_id text not null,
    binding_sha256 char(64) not null,
    subject_id text not null,
    agreement_id text not null,
    product_kind text not null,
    amount_minor bigint not null,
    currency char(3) not null,
    requested_state text not null,
    payload_sha256 char(64) not null,
    first_signature_timestamp bigint not null,
    received_at timestamptz not null default now(),
    primary key (provider, provider_account_id, provider_event_id),
    constraint ck_stripe_entitlement_event_provider check (provider = 'stripe'),
    constraint ck_stripe_entitlement_event_type
        check (provider_event_type in (
            'checkout.session.completed',
            'checkout.session.async_payment_succeeded',
            'checkout.session.async_payment_failed'
        )),
    constraint ck_stripe_entitlement_event_kind
        check (product_kind in ('access_entitlement', 'usage_quota')),
    constraint ck_stripe_entitlement_event_state
        check (requested_state in ('payment_pending', 'payment_confirmed', 'payment_failed')),
    constraint ck_stripe_entitlement_event_payload_sha check (payload_sha256 ~ '^[0-9a-f]{64}$'),
    constraint ck_stripe_entitlement_event_binding_sha check (binding_sha256 ~ '^[0-9a-f]{64}$'),
    constraint ck_stripe_entitlement_event_amount check (amount_minor > 0),
    constraint ck_stripe_entitlement_event_currency check (currency = upper(currency)),
    constraint ck_stripe_entitlement_event_signature_timestamp check (first_signature_timestamp > 0)
);

create table if not exists stripe_entitlement_event_deliveries (
    delivery_sha256 char(64) primary key,
    provider text not null,
    provider_account_id text not null,
    provider_event_id text not null,
    signature_timestamp bigint not null,
    received_at timestamptz not null default now(),
    foreign key (provider, provider_account_id, provider_event_id)
        references stripe_entitlement_provider_events(provider, provider_account_id, provider_event_id),
    constraint ck_stripe_entitlement_delivery_sha check (delivery_sha256 ~ '^[0-9a-f]{64}$'),
    constraint ck_stripe_entitlement_delivery_timestamp check (signature_timestamp > 0)
);

create or replace function admit_stripe_entitlement_provider_event(
    p_provider_event_id text,
    p_provider_event_type text,
    p_provider_event_created_at timestamptz,
    p_signature_timestamp bigint,
    p_payload_sha256 text,
    p_delivery_sha256 text,
    p_order_id text,
    p_provider_session_id text,
    p_provider_account_id text,
    p_binding_sha256 text,
    p_subject_id text,
    p_agreement_id text,
    p_product_kind text,
    p_amount_minor bigint,
    p_currency text,
    p_requested_state text
) returns text
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
    locked_order stripe_entitlement_checkout_orders%rowtype;
    existing_event stripe_entitlement_provider_events%rowtype;
    existing_delivery stripe_entitlement_event_deliveries%rowtype;
    result text;
begin
    select * into locked_order
    from stripe_entitlement_checkout_orders
    where order_id = p_order_id
    for update;

    if not found then
        return 'unknown_order';
    end if;

    -- Serializes exact-provider retries before checking the semantic event key.
    perform pg_advisory_xact_lock(
        hashtextextended('stripe:' || p_provider_account_id || ':' || p_provider_event_id, 0)
    );

    select * into existing_event
    from stripe_entitlement_provider_events
    where provider = 'stripe'
      and provider_account_id = p_provider_account_id
      and provider_event_id = p_provider_event_id;

    if found then
        if existing_event.provider_event_type <> p_provider_event_type
           or existing_event.provider_event_created_at <> p_provider_event_created_at
           or existing_event.payload_sha256 <> p_payload_sha256
           or existing_event.order_id <> p_order_id
           or existing_event.provider_session_id <> p_provider_session_id
           or existing_event.binding_sha256 <> p_binding_sha256
           or existing_event.subject_id <> p_subject_id
           or existing_event.agreement_id <> p_agreement_id
           or existing_event.product_kind <> p_product_kind
           or existing_event.amount_minor <> p_amount_minor
           or existing_event.currency <> upper(p_currency)
           or existing_event.requested_state <> p_requested_state then
            return 'provider_event_conflict';
        end if;

        select * into existing_delivery
        from stripe_entitlement_event_deliveries
        where delivery_sha256 = p_delivery_sha256;
        if found then
            if existing_delivery.provider <> 'stripe'
               or existing_delivery.provider_account_id <> p_provider_account_id
               or existing_delivery.provider_event_id <> p_provider_event_id then
                return 'replayed_delivery';
            end if;
            return 'duplicate';
        end if;

        insert into stripe_entitlement_event_deliveries (
            delivery_sha256, provider, provider_account_id, provider_event_id, signature_timestamp
        ) values (
            p_delivery_sha256, 'stripe', p_provider_account_id, p_provider_event_id, p_signature_timestamp
        );
        return 'duplicate';
    end if;

    select * into existing_delivery
    from stripe_entitlement_event_deliveries
    where delivery_sha256 = p_delivery_sha256;
    if found then
        return 'replayed_delivery';
    end if;

    if locked_order.provider <> 'stripe'
       or locked_order.provider_mode <> 'test'
       or locked_order.provider_account_id <> p_provider_account_id
       or locked_order.provider_session_id is null
       or locked_order.provider_session_id <> p_provider_session_id
       or locked_order.binding_sha256 <> p_binding_sha256
       or locked_order.subject_id <> p_subject_id
       or locked_order.agreement_id <> p_agreement_id
       or locked_order.product_kind <> p_product_kind
       or locked_order.amount_minor <> p_amount_minor
       or locked_order.currency <> upper(p_currency) then
        return 'binding_mismatch';
    end if;

    if locked_order.last_provider_event_created_at is not null
       and p_provider_event_created_at <= locked_order.last_provider_event_created_at then
        return 'out_of_order';
    end if;

    if locked_order.state = 'payment_confirmed' and p_requested_state = 'payment_confirmed' then
        result := 'economic_duplicate';
    elsif (locked_order.state = 'awaiting_payment' and p_requested_state in ('payment_pending', 'payment_confirmed', 'payment_failed'))
       or (locked_order.state = 'payment_pending' and p_requested_state in ('payment_confirmed', 'payment_failed')) then
        result := case when p_requested_state = 'payment_pending' then 'pending' else 'accepted' end;
    else
        return 'out_of_order';
    end if;

    insert into stripe_entitlement_provider_events (
        provider, provider_account_id, provider_event_id, provider_event_type,
        provider_event_created_at, order_id, provider_session_id, binding_sha256,
        subject_id, agreement_id, product_kind, amount_minor, currency,
        requested_state, payload_sha256, first_signature_timestamp
    ) values (
        'stripe', p_provider_account_id, p_provider_event_id, p_provider_event_type,
        p_provider_event_created_at, p_order_id, p_provider_session_id, p_binding_sha256,
        p_subject_id, p_agreement_id, p_product_kind, p_amount_minor, upper(p_currency),
        p_requested_state, p_payload_sha256, p_signature_timestamp
    );

    insert into stripe_entitlement_event_deliveries (
        delivery_sha256, provider, provider_account_id, provider_event_id, signature_timestamp
    ) values (
        p_delivery_sha256, 'stripe', p_provider_account_id, p_provider_event_id, p_signature_timestamp
    );

    update stripe_entitlement_checkout_orders
    set state = case when result = 'economic_duplicate' then state else p_requested_state end,
        last_provider_event_created_at = p_provider_event_created_at,
        updated_at = now()
    where order_id = p_order_id;

    return result;
end;
$$;

revoke all on function admit_stripe_entitlement_provider_event(
    text, text, timestamptz, bigint, text, text, text, text,
    text, text, text, text, text, bigint, text, text
) from public;

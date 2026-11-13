CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE TYPE warehouse_type_enum AS ENUM ('CENTRAL', 'VAN', 'SITE');
CREATE TYPE work_order_status_enum AS ENUM ('ASSIGNED', 'DRAFT', 'IN_PROGRESS', 'READY_FOR_SIGN', 'COMMITTED', 'CANCELLED');
CREATE TYPE material_tx_type_enum AS ENUM ('RESERVE', 'RELEASE', 'COMMIT', 'RESTOCK', 'ADJUSTMENT');
CREATE TYPE tes_category_enum AS ENUM ('REGULAR', 'OVERTIME_50', 'OVERTIME_100', 'EMERGENCY_CALLOUT', 'TRAVEL_TIME');
CREATE TYPE user_role_enum AS ENUM ('ADMIN', 'DISPATCHER', 'TECHNICIAN', 'ACCOUNTANT');

CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    business_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    oidc_subject TEXT NOT NULL UNIQUE,
    email TEXT NOT NULL,
    full_name TEXT NOT NULL,
    role user_role_enum NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    user_id UUID NOT NULL REFERENCES users(id),
    device_fingerprint TEXT NOT NULL,
    platform TEXT NOT NULL,
    last_sync_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, device_fingerprint)
);
CREATE TABLE processed_idempotency_keys (
    idempotency_key UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    user_id UUID NOT NULL REFERENCES users(id),
    endpoint TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    response_status INTEGER NOT NULL,
    response_body JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE warehouses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    warehouse_type warehouse_type_enum NOT NULL,
    assigned_user_id UUID REFERENCES users(id),
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    is_active BOOLEAN NOT NULL DEFAULT true,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    sku TEXT NOT NULL,
    ean_barcode TEXT,
    sahkonumero TEXT,
    lvi_number TEXT,
    name TEXT NOT NULL,
    description TEXT,
    unit TEXT NOT NULL,
    manufacturer TEXT,
    primary_wholesaler TEXT,
    list_price_cents BIGINT NOT NULL DEFAULT 0,
    net_price_cents BIGINT NOT NULL DEFAULT 0,
    ai_class_label TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, sku)
);
CREATE TABLE inventory_balances (
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    product_id UUID NOT NULL REFERENCES products(id),
    on_hand_qty NUMERIC(12, 3) NOT NULL DEFAULT 0,
    reserved_qty NUMERIC(12, 3) NOT NULL DEFAULT 0,
    min_threshold NUMERIC(12, 3) NOT NULL DEFAULT 0,
    max_threshold NUMERIC(12, 3) NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (warehouse_id, product_id),
    CONSTRAINT chk_reserved_non_negative CHECK (reserved_qty >= 0)
);
CREATE TABLE inventory_ledger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    product_id UUID NOT NULL REFERENCES products(id),
    work_order_id UUID,
    tx_type material_tx_type_enum NOT NULL,
    delta_on_hand NUMERIC(12, 3) NOT NULL DEFAULT 0,
    delta_reserved NUMERIC(12, 3) NOT NULL DEFAULT 0,
    idempotency_key UUID NOT NULL UNIQUE,
    correlation_id UUID NOT NULL,
    created_by UUID NOT NULL REFERENCES users(id),
    device_id UUID REFERENCES devices(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    business_id TEXT,
    address TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE work_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    work_order_number TEXT NOT NULL,
    customer_id UUID NOT NULL REFERENCES customers(id),
    title TEXT NOT NULL,
    site_address TEXT,
    status work_order_status_enum NOT NULL DEFAULT 'ASSIGNED',
    assigned_user_id UUID NOT NULL REFERENCES users(id),
    billing_period_locked BOOLEAN NOT NULL DEFAULT false,
    version INTEGER NOT NULL DEFAULT 1,
    committed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, work_order_number)
);
CREATE TABLE work_phases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id UUID NOT NULL REFERENCES work_orders(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'PENDING'
);
CREATE TABLE work_order_materials (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    work_order_id UUID NOT NULL REFERENCES work_orders(id),
    work_phase_id UUID REFERENCES work_phases(id),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    product_id UUID NOT NULL REFERENCES products(id),
    qty NUMERIC(12, 3) NOT NULL CHECK (qty > 0),
    unit_price_cents BIGINT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('DRAFT_RESERVED', 'COMMITTED', 'RELEASED')),
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    committed_at TIMESTAMPTZ
);
CREATE TABLE work_time_entries (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    work_order_id UUID NOT NULL REFERENCES work_orders(id),
    user_id UUID NOT NULL REFERENCES users(id),
    tes_category tes_category_enum NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    duration_minutes INTEGER NOT NULL CHECK (duration_minutes >= 0),
    notes TEXT,
    idempotency_key UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE server_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    aggregate_type TEXT NOT NULL,
    aggregate_id UUID NOT NULL,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    correlation_id UUID NOT NULL,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

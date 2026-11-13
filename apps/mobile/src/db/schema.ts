export const SQLITE_INIT_SCHEMA = `
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS sync_outbox (
    id TEXT PRIMARY KEY NOT NULL,
    sequence_num INTEGER NOT NULL UNIQUE,
    aggregate_type TEXT NOT NULL,
    aggregate_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    http_method TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    correlation_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING',
    retry_count INTEGER NOT NULL DEFAULT 0,
    next_retry_at TEXT,
    last_error_code TEXT,
    last_error_message TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dead_letter_queue (
    id TEXT PRIMARY KEY NOT NULL,
    original_outbox_id TEXT NOT NULL,
    aggregate_type TEXT NOT NULL,
    aggregate_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    error_code TEXT NOT NULL,
    error_message TEXT NOT NULL,
    resolution_action TEXT,
    resolved_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS warehouses (
    id TEXT PRIMARY KEY NOT NULL,
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    warehouse_type TEXT NOT NULL,
    latitude REAL,
    longitude REAL,
    is_active INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS products (
    id TEXT PRIMARY KEY NOT NULL,
    sku TEXT NOT NULL,
    ean_barcode TEXT,
    sahkonumero TEXT,
    lvi_number TEXT,
    name TEXT NOT NULL,
    unit TEXT NOT NULL,
    manufacturer TEXT,
    primary_wholesaler TEXT,
    net_price_cents INTEGER NOT NULL DEFAULT 0,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS products_fts USING fts5(
    product_id UNINDEXED, name, sku, ean_barcode, sahkonumero, lvi_number, manufacturer,
    content='products', content_rowid='rowid'
);

CREATE TRIGGER IF NOT EXISTS products_ai AFTER INSERT ON products BEGIN
    INSERT INTO products_fts(rowid, product_id, name, sku, ean_barcode, sahkonumero, lvi_number, manufacturer)
    VALUES (new.rowid, new.id, new.name, new.sku, new.ean_barcode, new.sahkonumero, new.lvi_number, new.manufacturer);
END;

CREATE TABLE IF NOT EXISTS inventory_balances (
    warehouse_id TEXT NOT NULL,
    product_id TEXT NOT NULL,
    on_hand_qty REAL NOT NULL DEFAULT 0,
    reserved_qty REAL NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (warehouse_id, product_id)
);

CREATE TABLE IF NOT EXISTS material_allocations (
    id TEXT PRIMARY KEY NOT NULL,
    work_order_id TEXT NOT NULL,
    work_phase_id TEXT,
    warehouse_id TEXT NOT NULL,
    product_id TEXT NOT NULL,
    qty REAL NOT NULL,
    unit_price_cents INTEGER NOT NULL,
    state TEXT NOT NULL,
    is_synced INTEGER NOT NULL DEFAULT 0,
    created_by TEXT NOT NULL,
    created_at TEXT NOT NULL,
    committed_at TEXT
);

CREATE TABLE IF NOT EXISTS work_time_entries (
    id TEXT PRIMARY KEY NOT NULL,
    work_order_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    tes_category TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    duration_minutes INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'DRAFT',
    is_synced INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
`;

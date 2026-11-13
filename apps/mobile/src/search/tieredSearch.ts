import type { LocalDatabaseDriver } from '../db/driver';

export interface ProductSearchResult {
  productId: string; sku: string; sahkonumero: string | null; name: string;
  unit: string; netPriceCents: number; availableWarehouseId: string | null;
  availableWarehouseName: string | null; availableQty: number;
}

export class TieredProductSearchService {
  constructor(private readonly db: LocalDatabaseDriver) {}

  async search(rawQuery: string, ownVanWarehouseId: string) {
    const t0 = performance.now();
    const q = rawQuery.trim();
    if (!q) return { results: [] as ProductSearchResult[], durationMs: 0 };

    const exact = await this.db.execute(
      `SELECT p.id AS productId, p.sku, p.sahkonumero, p.name, p.unit, p.net_price_cents AS netPriceCents,
              w.id AS availableWarehouseId, w.name AS availableWarehouseName,
              COALESCE(ib.on_hand_qty - ib.reserved_qty, 0) AS availableQty
       FROM products p
       LEFT JOIN inventory_balances ib ON ib.product_id = p.id AND ib.warehouse_id = ?
       LEFT JOIN warehouses w ON w.id = ib.warehouse_id
       WHERE p.ean_barcode = ? OR p.sahkonumero = ? OR p.lvi_number = ? OR p.sku = ? LIMIT 10`,
      [ownVanWarehouseId, q, q, q, q]
    );
    if (exact.rows.length > 0) {
      return { results: exact.rows as unknown as ProductSearchResult[], durationMs: Math.round((performance.now() - t0) * 100) / 100 };
    }

    const fts = q.replace(/["*^():-]/g, ' ').split(/\s+/).filter(Boolean).map((t) => `"${t}"*`).join(' AND ');
    if (!fts) return { results: [], durationMs: 0 };

    const res = await this.db.execute(
      `SELECT p.id AS productId, p.sku, p.sahkonumero, p.name, p.unit, p.net_price_cents AS netPriceCents,
              w.id AS availableWarehouseId, COALESCE(w.name, 'Katalogi') AS availableWarehouseName,
              COALESCE(ib.on_hand_qty - ib.reserved_qty, 0) AS availableQty
       FROM products_fts f
       JOIN products p ON p.id = f.product_id
       LEFT JOIN inventory_balances ib ON ib.product_id = p.id
       LEFT JOIN warehouses w ON w.id = ib.warehouse_id
       WHERE products_fts MATCH ?
       ORDER BY CASE WHEN ib.warehouse_id = ? THEN 0 ELSE 1 END, p.is_favorite DESC
       LIMIT 20`,
      [fts, ownVanWarehouseId]
    );
    return { results: res.rows as unknown as ProductSearchResult[], durationMs: Math.round((performance.now() - t0) * 100) / 100 };
  }
}

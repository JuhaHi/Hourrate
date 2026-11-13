import React, { useEffect, useState, useCallback } from 'react';
import { createRoot } from 'react-dom/client';
import { View, Text, TextInput, Pressable, FlatList } from 'react-native';
import { WebSqliteDriver } from './db/driver.web';
import { SQLITE_INIT_SCHEMA } from './db/schema';
import { TieredProductSearchService, type ProductSearchResult } from './search/tieredSearch';
import { MaterialRepository } from './db/repositories/materialRepository';
import { OutboxProcessor } from './sync/outboxProcessor';

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js').catch(console.error));
}

const VAN_ID = '11111111-1111-4111-8111-111111111111';
const WO_ID = '22222222-2222-4222-8222-222222222222';
const USER_ID = '00000000-0000-4000-8000-000000000002';

function PwaFieldApp() {
  const [driver] = useState(() => new WebSqliteDriver());
  const [ready, setReady] = useState(false);
  const [errMsg, setErrMsg] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<ProductSearchResult[]>([]);
  const [latencyMs, setLatencyMs] = useState<number | null>(null);
  const [outboxCount, setOutboxCount] = useState(0);
  const [darkMode, setDarkMode] = useState(true);

  const refreshOutbox = useCallback(async () => {
    const r = await driver.execute(`SELECT COUNT(*) AS cnt FROM sync_outbox WHERE status != 'DLQ'`);
    setOutboxCount(Number(r.rows[0]?.cnt ?? 0));
  }, [driver]);

  useEffect(() => {
    (async () => {
      try {
        await driver.init(SQLITE_INIT_SCHEMA);
        const existing = await driver.execute(`SELECT COUNT(*) AS cnt FROM products`);
        if (Number(existing.rows[0]?.cnt ?? 0) === 0) {
          const now = new Date().toISOString();
          await driver.execute(`INSERT INTO warehouses (id, code, name, warehouse_type, updated_at) VALUES (?, 'VAN-01', 'Oma Huoltoauto', 'VAN', ?)`, [VAN_ID, now]);
          await driver.execute(`INSERT INTO products (id, sku, sahkonumero, name, unit, net_price_cents, is_favorite, updated_at) VALUES ('p1','MMJ-315','0401234','MMJ 3x1.5S asennuskaapeli','m',125,1,?)`, [now]);
          await driver.execute(`INSERT INTO products (id, sku, sahkonumero, name, unit, net_price_cents, is_favorite, updated_at) VALUES ('p2','SUKO-IP44','2506100','Suko-pistorasia IP44 pinta','kpl',1490,1,?)`, [now]);
          await driver.execute(`INSERT INTO inventory_balances (warehouse_id, product_id, on_hand_qty, reserved_qty, updated_at) VALUES (?, 'p1', 100, 0, ?)`, [VAN_ID, now]);
          await driver.execute(`INSERT INTO inventory_balances (warehouse_id, product_id, on_hand_qty, reserved_qty, updated_at) VALUES (?, 'p2', 12, 0, ?)`, [VAN_ID, now]);
        }
        await refreshOutbox();
        setReady(true);
      } catch (e) {
        setErrMsg(e instanceof Error ? e.message : String(e));
      }
    })();
  }, [driver, refreshOutbox]);

  useEffect(() => {
    if (!ready) return;
    const svc = new TieredProductSearchService(driver);
    void svc.search(query || 'MMJ', VAN_ID).then((r) => {
      setResults(r.results);
      setLatencyMs(r.durationMs);
    });
  }, [query, ready, driver]);

  const handleReserve = async (item: ProductSearchResult) => {
    const repo = new MaterialRepository(driver);
    await repo.reserveDraftMaterial({
      workOrderId: WO_ID,
      warehouseId: item.availableWarehouseId ?? VAN_ID,
      productId: item.productId,
      qty: 1,
      unitPriceCents: item.netPriceCents,
      userId: USER_ID,
    });
    await refreshOutbox();
    const outbox = new OutboxProcessor(driver, {
      apiBaseUrl: '', // Käyttää saman originin /v1-proxya!
      deviceId: 'android-pwa',
      isNetworkAvailable: async () => navigator.onLine,
      onDlqAlert: (d) => alert(`DLQ: ${d.errorCode} - ${d.errorMessage}`),
    });
    await outbox.processQueue().catch(() => undefined);
    await refreshOutbox();
  };

  const bg = darkMode ? '#050505' : '#FFFFFF';
  const fg = darkMode ? '#FFFFFF' : '#000000';
  const btnBg = darkMode ? '#FFD600' : '#002B7F';
  const btnFg = darkMode ? '#000000' : '#FFFFFF';

  if (errMsg) return <View style={{ padding: 20, backgroundColor: '#B00020' }}><Text style={{ color: '#FFF', fontSize: 18 }}>{errMsg}</Text></View>;
  if (!ready) return <View style={{ padding: 20, backgroundColor: bg }}><Text style={{ color: fg, fontSize: 18 }}>Alustetaan SQLite WASM (OPFS)...</Text></View>;

  return (
    <View style={{ minHeight: '100vh' as never, padding: 16, backgroundColor: bg }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
        <View>
          <Text style={{ color: fg, fontSize: 22, fontWeight: '900' }}>Työ #WO-2026-001</Text>
          <Text style={{ color: fg, fontSize: 14 }}>Outbox-jono: {outboxCount} • Haku: {latencyMs ?? 0} ms</Text>
        </View>
        <Pressable onPress={() => setDarkMode((d) => !d)} style={{ minHeight: 48, paddingHorizontal: 14, justifyContent: 'center', backgroundColor: btnBg, borderRadius: 8 }}>
          <Text style={{ color: btnFg, fontWeight: '900' }}>{darkMode ? 'PÄIVÄ' : 'PIMEÄ'}</Text>
        </Pressable>
      </View>

      <TextInput
        value={query}
        onChangeText={setQuery}
        placeholder="Hae sähkönumerolla tai nimellä..."
        placeholderTextColor="#888"
        style={{ minHeight: 56, borderWidth: 2, borderColor: fg, borderRadius: 8, paddingHorizontal: 12, color: fg, fontSize: 18, marginBottom: 12 }}
      />

      <FlatList
        data={results}
        keyExtractor={(i) => i.productId}
        renderItem={({ item }) => (
          <Pressable
            onPress={() => void handleReserve(item)}
            style={{ minHeight: 60, padding: 12, borderWidth: 2, borderColor: fg, borderRadius: 8, marginBottom: 8, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}
          >
            <View style={{ flex: 1 }}>
              <Text style={{ color: fg, fontWeight: '800', fontSize: 16 }}>{item.name}</Text>
              <Text style={{ color: fg, fontSize: 13 }}>{item.sahkonumero} • Saldo: {item.availableQty} {item.unit}</Text>
            </View>
            <View style={{ minHeight: 48, paddingHorizontal: 14, justifyContent: 'center', backgroundColor: btnBg, borderRadius: 6 }}>
              <Text style={{ color: btnFg, fontWeight: '900' }}>+ VARAA</Text>
            </View>
          </Pressable>
        )}
      />
    </View>
  );
}

createRoot(document.getElementById('root')!).render(<PwaFieldApp />);

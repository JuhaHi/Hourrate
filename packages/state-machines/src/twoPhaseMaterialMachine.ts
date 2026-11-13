import { setup, assign } from 'xstate';

export interface MaterialAllocationContext {
  allocationId: string;
  workOrderId: string;
  warehouseId: string;
  productId: string;
  qty: number;
  error: string | null;
}

export type MaterialAllocationEvent =
  | { type: 'RESERVE_DRAFT'; allocationId: string; workOrderId: string; warehouseId: string; productId: string; qty: number }
  | { type: 'ADJUST_QTY'; newQty: number }
  | { type: 'RELEASE' }
  | { type: 'COMMIT' };

export const twoPhaseMaterialMachine = setup({
  types: {
    context: {} as MaterialAllocationContext,
    events: {} as MaterialAllocationEvent,
  },
  guards: {
    isValidPositiveQty: ({ event }) =>
      (event.type === 'RESERVE_DRAFT' && event.qty > 0) ||
      (event.type === 'ADJUST_QTY' && event.newQty > 0),
  },
  actions: {
    init: assign(({ event }) =>
      event.type === 'RESERVE_DRAFT'
        ? { allocationId: event.allocationId, workOrderId: event.workOrderId, warehouseId: event.warehouseId, productId: event.productId, qty: event.qty, error: null }
        : {}
    ),
    setError: assign({ error: 'Määrän on oltava > 0' }),
  },
}).createMachine({
  id: 'twoPhaseMaterial',
  initial: 'unallocated',
  context: { allocationId: '', workOrderId: '', warehouseId: '', productId: '', qty: 0, error: null },
  states: {
    unallocated: {
      on: {
        RESERVE_DRAFT: [
          { guard: 'isValidPositiveQty', target: 'draftReserved', actions: 'init' },
          { actions: 'setError' },
        ],
      },
    },
    draftReserved: {
      on: { RELEASE: 'released', COMMIT: 'committed' },
    },
    committed: { type: 'final' },
    released: { type: 'final' },
  },
});

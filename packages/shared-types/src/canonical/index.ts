import { z } from 'zod';

export const TesCategorySchema = z.enum([
  'REGULAR', 'OVERTIME_50', 'OVERTIME_100', 'EMERGENCY_CALLOUT', 'TRAVEL_TIME',
]);

export const CanonicalPayrollTimeEntrySchema = z.object({
  entryId: z.string().uuid(),
  tenantId: z.string().uuid(),
  employeeInternalId: z.string().uuid(),
  employeeExternalKey: z.string(),
  workDateIso: z.string(),
  tesCategory: TesCategorySchema,
  durationHours: z.number().positive(),
  description: z.string().optional(),
  correlationId: z.string().uuid(),
});
export type CanonicalPayrollTimeEntry = z.infer<typeof CanonicalPayrollTimeEntrySchema>;

export interface CanonicalTravelExpense {
  travelLogId: string;
  employeeExternalKey: string;
  dateIso: string;
  routeDescription: string;
  distanceKm: number;
  allowanceType: 'NONE' | 'PARTIAL_DAY' | 'FULL_DAY';
}

export interface CanonicalSalesInvoice {
  tenantId: string;
  workOrderId: string;
  workOrderNumber: string;
  customerExternalKey: string;
  invoiceDateIso: string;
  paymentTermDays: number;
  lines: Array<{
    skuOrCode: string;
    description: string;
    quantity: number;
    unitPriceCents: number;
    vatRatePercent: number;
    discountPercent: number;
  }>;
  correlationId: string;
}

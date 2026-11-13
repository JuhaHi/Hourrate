export type VoiceIntent =
  | { type: 'ADD_MATERIAL'; quantity: number; searchQuery: string }
  | { type: 'START_TIME_ENTRY'; tesCategory: 'REGULAR' | 'OVERTIME_50' | 'OVERTIME_100' | 'EMERGENCY_CALLOUT' | 'TRAVEL_TIME' }
  | { type: 'STOP_TIME_ENTRY' }
  | { type: 'UNKNOWN'; rawTranscript: string };

export function parseVoiceCommand(transcript: string): VoiceIntent {
  const n = transcript.toLowerCase().trim();
  if (/(lopeta|pysäytä)\s*(työ|aika)/.test(n)) return { type: 'STOP_TIME_ENTRY' };
  if (/(aloita|käynnistä)\s*(ylityö\s*50|ylityö)/.test(n)) return { type: 'START_TIME_ENTRY', tesCategory: 'OVERTIME_50' };
  if (/(aloita|käynnistä)\s*(normaali|työ)/.test(n)) return { type: 'START_TIME_ENTRY', tesCategory: 'REGULAR' };
  const m = n.match(/^(?:lisää|ota)\s+(\d+(?:[.,]\d+)?)\s*(?:kpl|kappaletta|m|metriä)?\s+(.+)$/i);
  if (m) return { type: 'ADD_MATERIAL', quantity: Number(m[1].replace(',', '.')), searchQuery: m[2].trim() };
  return { type: 'UNKNOWN', rawTranscript: transcript };
}

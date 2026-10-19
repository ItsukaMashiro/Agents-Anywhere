import { BridgeError } from './errors.js'

/** Per-session Tavern opening request carried on session.createAndStart. */
export interface TavernOpening { card: string, openingId: string, userName: string }

export interface TavernCardOpening { id: string, text: string }
export interface TavernCard {
  path: string, name: string, group: string, starred: boolean,
  script: { path: string, title: string } | null, openings?: TavernCardOpening[],
}
export interface TavernCardCatalog { workspace: string, groups: string[], cards: TavernCard[] }

/** Service provided by the DSH Tavern plugin (ctx.provide('tavernGame')). */
export interface TavernGameService {
  catalog(options?: { card?: string | undefined, openings?: boolean | undefined }): Promise<TavernCardCatalog>
  binding(sessionId: string): Promise<{ cardName: string, cardPath: string } | null>
  startChat(request: { cardPath: string, sessionId: string, openingId?: string, userName?: string }): Promise<{ view: unknown }>
}

declare module '@deepseek-ai/cordis' {
  interface Context {
    /** Game opening surface of the DSH Tavern plugin; absent on plain DSH hosts. */
    tavernGame?: TavernGameService
  }
}

export function parseTavern(value: unknown): TavernOpening | undefined {
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'object') throw new BridgeError('INVALID_PARAMS', 'The Tavern opening request must be an object.')
  const record = value as Record<string, unknown>
  const card = typeof record.card === 'string' ? record.card.trim() : ''
  if (!card) throw new BridgeError('INVALID_PARAMS', 'A Tavern session requires a character card.')
  return {
    card,
    openingId: typeof record.openingId === 'string' ? record.openingId : '',
    userName: typeof record.userName === 'string' ? record.userName : '',
  }
}

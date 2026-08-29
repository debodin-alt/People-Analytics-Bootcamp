import { supabase } from './supabase';
import type { FilterContext, WizardResponse } from './types';

/**
 * Conversation state for the Wizard, deliberately outside React.
 *
 * It began as useState inside the page component, which is wrong for two
 * reasons that only show up in use:
 *
 *   Navigating away unmounted the component and took the whole thread with
 *   it. Going to Workforce to check a number against a chart — the single
 *   most natural thing to do with an answer — destroyed the conversation
 *   that produced it.
 *
 *   Worse, an in-flight question was abandoned mid-flight. The Edge
 *   Function kept running and kept costing tokens; there was simply nothing
 *   left to receive the answer. A 30-second wait plus a moment of
 *   impatience equals a query that silently never happened.
 *
 * A module-scoped store fixes both: the fetch is owned here, not by a
 * component, so unmounting is irrelevant. The page subscribes and renders
 * whatever the store currently holds. Leave mid-question, come back, and
 * the answer is there.
 *
 * State is mirrored into sessionStorage so a reload keeps the thread —
 * sessionStorage rather than localStorage because these are answers about
 * real people: scoped to the tab, gone when it closes. It is also keyed by
 * user id and cleared when that changes, so a shared machine never shows
 * one person's HR questions to the next.
 */

export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
  response?: WizardResponse;
  diagnostics?: Record<string, unknown>;
  error?: string;
}

interface WizardState {
  messages: ChatMessage[];
  /** Epoch ms the in-flight question started, or null when idle. Held here
   *  rather than in the spinner so the elapsed counter stays truthful
   *  across a navigation instead of restarting from zero. */
  startedAt: number | null;
  userId: string | null;
}

const EMPTY: WizardState = { messages: [], startedAt: null, userId: null };

let state: WizardState = EMPTY;
const listeners = new Set<() => void>();

function storageKey(userId: string) {
  return `meridian.wizard.${userId}`;
}

function emit(next: WizardState) {
  state = next;
  if (state.userId) {
    try {
      sessionStorage.setItem(
        storageKey(state.userId),
        JSON.stringify({ messages: state.messages }),
      );
    } catch {
      // Storage full or blocked. The thread still works for this session;
      // it just will not survive a reload. Not worth failing the ask over.
    }
  }
  listeners.forEach((l) => l());
}

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function getSnapshot(): WizardState {
  return state;
}

/**
 * Bind the store to the signed-in user, restoring their thread.
 *
 * Called on every render of the page; a no-op unless the user actually
 * changed, so switching accounts drops the previous conversation rather
 * than inheriting it.
 */
export function bindUser(userId: string | null) {
  if (state.userId === userId) return;

  if (!userId) {
    emit({ ...EMPTY });
    return;
  }

  let messages: ChatMessage[] = [];
  try {
    const raw = sessionStorage.getItem(storageKey(userId));
    if (raw) messages = (JSON.parse(raw).messages ?? []) as ChatMessage[];
  } catch {
    messages = [];
  }

  // startedAt is not restored: any request in flight when the page was
  // unloaded died with the page, and showing a running clock for it would
  // be a lie.
  emit({ messages, startedAt: null, userId });
}

export function clearThread() {
  if (state.userId) {
    try {
      sessionStorage.removeItem(storageKey(state.userId));
    } catch { /* nothing to do */ }
  }
  emit({ ...state, messages: [], startedAt: null });
}

export async function ask(question: string, filters: FilterContext) {
  const trimmed = question.trim();
  if (!trimmed || state.startedAt !== null) return;

  const history: ChatMessage[] = [...state.messages, { role: 'user', content: trimmed }];
  const askedBy = state.userId;
  emit({ ...state, messages: history, startedAt: Date.now() });

  // Drop the answer if the signed-in user changed while it was in flight.
  // Without this, signing out mid-question — or handing the laptop over —
  // appends one person's answer about real employees to the next person's
  // thread. The request cannot be recalled, but the result can be discarded.
  const append = (m: ChatMessage) => {
    if (state.userId !== askedBy) return;
    emit({ ...state, messages: [...state.messages, m], startedAt: null });
  };

  try {
    const { data, error } = await supabase.functions.invoke('wizard', {
      body: {
        // Only role and content cross the wire — chart specs and
        // diagnostics on earlier turns are presentation state, not
        // conversation.
        messages: history.map((m) => ({ role: m.role, content: m.content })),
        filters: {
          function: filters.function,
          location: filters.location,
          levelBand: filters.levelBand,
          tenureBand: filters.tenureBand,
        },
      },
    });

    if (error) throw error;

    if (data?.error) {
      append({ role: 'assistant', content: '', error: data.error });
      return;
    }

    const response = data as WizardResponse & { diagnostics?: Record<string, unknown> };
    append({
      role: 'assistant',
      content: response.answer ?? '',
      response,
      diagnostics: response.diagnostics,
    });
  } catch (err) {
    append({
      role: 'assistant',
      content: '',
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

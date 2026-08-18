// =============================================================================
// The tooltip, as one shared thing
// -----------------------------------------------------------------------------
// Module-level, the same shape as useCrosshair and useTimeWindow, and for a
// reason beyond consistency: ONE tooltip may be on screen at a time. Per-
// component state permits two, and two open tooltips is not a cosmetic problem
// - it is two answers to a question nobody asked twice.
//
// IT HOLDS AN ELEMENT, NOT A RECT. useCrosshair holds a time rather than a
// pixel "because a time is the only value that means the same thing in all of
// them"; the analogue here is that a DOMRect measured when the tooltip opened
// is wrong the moment anything scrolls, and an element is not. The rect is
// taken at paint time, from the element, every time.
//
// THE `caveat` FIELD IS THE POINT OF THE WHOLE FILE. Content is three typed
// slots rather than free markup, so every tooltip reads in one voice - but the
// third slot exists specifically so that "this number is not what it looks
// like" has somewhere to go that is not a comment in a source file. A grey LED
// meaning "nobody is checking" and an edge whose rate is its endpoint's total
// rather than its own are both facts a reader cannot recover from the drawing.
// =============================================================================

import { computed, ref } from "vue";

export interface TooltipContent {
  /** The subject. One short line, not a sentence. */
  title: string;
  /** Facts, one per line, rendered mono. */
  lines: string[];
  /** One sentence, amber. Reserved for "this is not what it looks like". */
  caveat?: string;
}

interface Open {
  id: string;
  anchor: HTMLElement | SVGElement;
  content: TooltipContent;
}

const open = ref<Open | null>(null);
const HOVER_OPEN_MS = 250;
const HOVER_CLOSE_MS = 80;

let timer: number | undefined;

function clearTimer(): void {
  if (timer !== undefined) {
    window.clearTimeout(timer);
    timer = undefined;
  }
}

export function tooltipId(id: string): string {
  return `tip-${id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
}

export function useTooltip() {
  function show(id: string, anchor: HTMLElement | SVGElement, content: TooltipContent, delay: number): void {
    clearTimer();
    if (delay <= 0) {
      open.value = { id, anchor, content };
      return;
    }
    timer = window.setTimeout(() => {
      open.value = { id, anchor, content };
    }, delay);
  }

  /** Guarded by id: a leave event from an anchor the pointer has already left
   *  must not close a tooltip that has since opened somewhere else. */
  function hide(id: string, delay = 0): void {
    clearTimer();
    const shut = (): void => {
      if (open.value?.id === id) open.value = null;
    };
    if (delay <= 0) shut();
    else timer = window.setTimeout(shut, delay);
  }

  function closeAll(): void {
    clearTimer();
    open.value = null;
  }

  /**
   * Everything a trigger needs, as one v-bind.
   *
   * Returned rather than applied by a directive because this codebase has no
   * directives anywhere, and because the identical object has to work on a
   * <span>, a <div> and an SVG <g>. Focus opens with NO delay - a keyboard
   * user has asked explicitly, and making them wait for it is a bug.
   */
  function bind(id: string, content: TooltipContent) {
    const described = computed(() => (open.value?.id === id ? tooltipId(id) : undefined));
    return {
      tabindex: 0,
      "aria-describedby": described.value,
      onPointerenter: (e: PointerEvent) =>
        show(id, e.currentTarget as HTMLElement, content, HOVER_OPEN_MS),
      onPointerleave: () => hide(id, HOVER_CLOSE_MS),
      onFocus: (e: FocusEvent) => show(id, e.currentTarget as HTMLElement, content, 0),
      onBlur: () => hide(id),
      onKeydown: (e: KeyboardEvent) => {
        if (e.key === "Escape") hide(id);
      },
    };
  }

  /**
   * Hover only: no tab stop, no focus handler.
   *
   * For the several-per-row case. Three LEDs on twenty-three rack rows is
   * sixty-nine tab stops through one table, which is worse for a keyboard user
   * than none at all - so the ROW carries the tab stop and a merged tooltip,
   * and each LED carries the precise one for a pointer. Nothing is only
   * available on hover: the row tooltip says everything the three say.
   */
  function hover(id: string, content: TooltipContent) {
    return {
      onPointerenter: (e: PointerEvent) =>
        show(id, e.currentTarget as HTMLElement, content, HOVER_OPEN_MS),
      onPointerleave: () => hide(id, HOVER_CLOSE_MS),
    };
  }

  return {
    current: computed(() => open.value),
    show,
    hide,
    closeAll,
    bind,
    hover,
  };
}

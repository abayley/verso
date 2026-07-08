/**
 * A single delegated tooltip for the whole editor (RFC-0035). Any element with a
 * `data-tooltip` attribute gets a tooltip after a short hover/focus delay. It is
 * one fixed-position element appended to `<body>`, so -- unlike Basecoat's CSS
 * pseudo-element tooltip -- it escapes scroll containers (the nav tree and the
 * ToC clip an absolutely-positioned pseudo-element) and never contributes to page
 * width. `installTooltips()` is idempotent and wires document-level listeners
 * once; the Basecoat pseudo-element tooltip is disabled in CSS so the two do not
 * double up.
 */

/** Delay before a tooltip appears on hover/focus. */
const SHOW_DELAY_MS = 250;

/** Gap between the trigger and the tooltip. */
const OFFSET_PX = 6;

/** Viewport inset the tooltip is clamped within. */
const MARGIN_PX = 4;

let installed = false;
let tip: HTMLElement | null = null;
let showTimer: number | null = null;
let target: HTMLElement | null = null;

/** Wires the delegated tooltip listeners once. Safe to call on every page load. */
export function installTooltips(): void {
    if (installed) {
        return;
    }

    installed = true;
    document.addEventListener("pointerover", handlePointerOver, true);
    document.addEventListener("pointerout", handlePointerOut, true);
    document.addEventListener("focusin", handleFocusIn, true);
    document.addEventListener("focusout", hideNow, true);
    document.addEventListener("pointerdown", hideNow, true);
    window.addEventListener("scroll", hideNow, true);
}

/** The tooltip element, created lazily. */
function tooltipElement(): HTMLElement {
    if (!tip) {
        tip = document.createElement("div");
        tip.className = "markdown-editor__tooltip";
        document.body.append(tip);
    }

    return tip;
}

function handlePointerOver(event: Event): void {
    scheduleFor(closestTooltip(event.target));
}

function handleFocusIn(event: Event): void {
    scheduleFor(closestTooltip(event.target));
}

function handlePointerOut(event: Event): void {
    // Leaving the current target (to somewhere that is not the tooltip target) hides it.
    const next = closestTooltip((event as PointerEvent).relatedTarget);
    if (next !== target) {
        hideNow();
    }
}

/** The nearest ancestor carrying a non-empty data-tooltip, or null. */
function closestTooltip(node: EventTarget | null): HTMLElement | null {
    if (!(node instanceof Element)) {
        return null;
    }

    const found = node.closest<HTMLElement>("[data-tooltip]");
    return found?.getAttribute("data-tooltip") ? found : null;
}

/** Schedules (or, when a tooltip is already up, immediately shows) the tooltip for an element. */
function scheduleFor(element: HTMLElement | null): void {
    if (!element || element === target) {
        return;
    }

    clearTimer();
    const warm = tip?.hasAttribute("data-visible") ?? false;
    target = element;

    if (warm) {
        show(element);
        return;
    }

    showTimer = window.setTimeout((): void => {
        showTimer = null;
        show(element);
    }, SHOW_DELAY_MS);
}

/** Shows the tooltip for an element, positioned below it (flipping above if there is no room). */
function show(element: HTMLElement): void {
    const label = element.getAttribute("data-tooltip");
    if (!label) {
        return;
    }

    const element_ = tooltipElement();
    element_.textContent = label;
    element_.setAttribute("data-visible", "");

    const rect = element.getBoundingClientRect();
    const own = element_.getBoundingClientRect();
    const below = rect.bottom + OFFSET_PX;
    const above = rect.top - OFFSET_PX - own.height;
    const top = below + own.height + MARGIN_PX <= window.innerHeight || above < MARGIN_PX ? below : above;
    const rawLeft = rect.left + rect.width / 2 - own.width / 2;
    const left = Math.max(MARGIN_PX, Math.min(rawLeft, window.innerWidth - own.width - MARGIN_PX));

    element_.style.top = `${Math.round(top)}px`;
    element_.style.left = `${Math.round(left)}px`;
}

/** Hides the tooltip immediately and clears any pending timer. */
function hideNow(): void {
    clearTimer();
    target = null;
    tip?.removeAttribute("data-visible");
}

function clearTimer(): void {
    if (showTimer !== null) {
        window.clearTimeout(showTimer);
        showTimer = null;
    }
}

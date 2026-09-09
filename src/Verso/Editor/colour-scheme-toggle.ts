import { type ColourScheme, effectiveColourScheme, toggleColourScheme } from "./appearance.js";
import { chromeButtonEl, chromeIconEl } from "./chrome.js";

/** A colour-scheme button that knows how to redraw itself. */
export interface ColourSchemeToggle extends HTMLButtonElement {
    /** Redraws the icon and labels for the scheme now in force. */
    sync(): void;
}

/**
 * The icon shows the scheme the press would move to, not the one in force: a sun in the
 * dark, a moon in the light. That is the convention these controls follow, and it is what
 * makes a single button legible -- it reads as the action, and the labels say so too.
 */
function faceFor(scheme: ColourScheme): { icon: string; label: string } {
    return scheme === "dark"
        ? { icon: "sun", label: "Switch to light theme" }
        : { icon: "moon", label: "Switch to dark theme" };
}

/**
 * The colour-scheme control: one button that flips between light and dark.
 *
 * It replaced a three-state segmented control whose third state followed the system. That
 * state is now the starting condition rather than a position on the control: with nothing
 * stored the page follows the system, and the first press pins a preference.
 */
export function createColourSchemeToggle(className: string): ColourSchemeToggle {
    const button = chromeButtonEl("quiet", "", { className }) as ColourSchemeToggle;

    button.sync = (): void => {
        const face = faceFor(effectiveColourScheme());
        button.replaceChildren(chromeIconEl(face.icon));
        button.setAttribute("aria-label", face.label);
        button.dataset["tooltip"] = face.label;
    };

    button.addEventListener("click", (): void => {
        toggleColourScheme();
        button.sync();
    });

    button.sync();
    return button;
}

/** The save lifecycle states surfaced on the editor's Save control. */
export type SaveState = "clean" | "dirty" | "saving" | "retry";

/** The observable outcome of the save state: what the element renders. */
export interface SaveStateView {
    state: SaveState;
    buttonLabel: string;
    buttonDisabled: boolean;
    error: string | null;
}

/** The Save button stays in "Auto-Saving..." for at least this long, so a fast save still reads. */
const savingMinimumMilliseconds = 500;

/** A save with no response within this window becomes a retry. */
const saveTimeoutMilliseconds = 10_000;

/**
 * The editor's save state machine (RFC-0002), extracted from the custom element as
 * a plain controller. It owns the clean/dirty/saving/retry states, the
 * minimum-saving-time transition, and the save timeout; the element forwards its
 * fetch lifecycle and content-change notifications and renders the reported view. Timers
 * are direct `window` timers (the tests drive them with fake timers).
 */
export class SaveStateController {
    private state: SaveState = "clean";
    private error: string | null = null;
    private startedAt = 0;
    private submitted = "";
    private timeoutHandle: number | null = null;
    private transitionHandle: number | null = null;
    private readonly currentMarkdown: () => string;
    private readonly onChange: (view: SaveStateView) => void;

    constructor(currentMarkdown: () => string, onChange: (view: SaveStateView) => void) {
        this.currentMarkdown = currentMarkdown;
        this.onChange = onChange;
    }

    /** The current view, for re-applying after the toolbar is rebuilt. */
    public view(): SaveStateView {
        return {
            state: this.state,
            buttonLabel: this.buttonLabel(),
            buttonDisabled: this.buttonDisabled(),
            error: this.error,
        };
    }

    /** Records the Markdown sent with the current save, for the post-save clean/dirty check. */
    public markSubmitted(markdown: string): void {
        this.submitted = markdown;
    }

    /** Marks the editor dirty after a local content change (ignored mid-save). */
    public markDirty(): void {
        if (this.state === "saving") {
            return;
        }

        this.cancelTransition();
        this.error = null;
        this.state = "dirty";
        this.emit();
    }

    /** Marks the current request as an in-progress save and arms the timeout. */
    public markSaving(): void {
        this.cancelTimeout();
        this.cancelTransition();
        this.error = null;
        this.startedAt = Date.now();
        this.state = "saving";
        this.emit();
        this.timeoutHandle = window.setTimeout((): void => {
            if (this.state === "saving") {
                this.markFailed("request timed out");
            }
        }, saveTimeoutMilliseconds);
    }

    /** Applies a positive save outcome, holding "Auto-Saving..." for the minimum time. */
    public markSucceeded(): void {
        const remaining = savingMinimumMilliseconds - (Date.now() - this.startedAt);

        if (remaining <= 0) {
            this.settle();
            return;
        }

        this.cancelTransition();
        this.transitionHandle = window.setTimeout((): void => this.settle(), remaining);
    }

    /** Marks the last save as failed and allows the user to retry. */
    public markFailed(reason: string): void {
        this.cancelTimeout();
        this.cancelTransition();
        this.state = "retry";
        this.error = `Save failed: ${reason}`;
        this.emit();
    }

    /** Clears outstanding timers when the element disconnects. */
    public dispose(): void {
        this.cancelTimeout();
        this.cancelTransition();
    }

    /** Resolves to clean or dirty depending on whether the document changed during the save. */
    private settle(): void {
        this.cancelTimeout();
        this.cancelTransition();
        this.error = null;
        this.state = this.currentMarkdown() === this.submitted ? "clean" : "dirty";
        this.emit();
    }

    private buttonLabel(): string {
        if (this.state === "saving") {
            return "Saving…";
        }

        if (this.state === "retry") {
            return "Retry";
        }

        return "Save";
    }

    private buttonDisabled(): boolean {
        if (this.state === "saving") {
            return true;
        }

        if (this.state === "retry") {
            return false;
        }

        return this.state === "clean";
    }

    private emit(): void {
        this.onChange(this.view());
    }

    private cancelTimeout(): void {
        if (this.timeoutHandle === null) {
            return;
        }

        window.clearTimeout(this.timeoutHandle);
        this.timeoutHandle = null;
    }

    private cancelTransition(): void {
        if (this.transitionHandle === null) {
            return;
        }

        window.clearTimeout(this.transitionHandle);
        this.transitionHandle = null;
    }
}

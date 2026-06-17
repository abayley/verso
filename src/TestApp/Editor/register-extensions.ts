// Registers every content extension as a side effect of import. Pipeline modules import this so the
// registry is populated wherever the editor runs (the bundle) or is exercised (the tests). The base
// extension registers as the fallback; feature extensions are consulted before it.
import "./base-extension.js";
import "./admonition-extension.js";
import "./table-extension.js";
import "./collapsible-extension.js";
import "./footnote-extension.js";
import "./reference-link-extension.js";
import "./image-extension.js";

import { badgeExtension } from "./badge-extension.js";
import { collapsibleExtension } from "./collapsible-extension.js";
import { type ContentExtension, createContentPipeline } from "./content-extension.js";
import { footnoteExtension } from "./footnote-extension.js";
import { gfmAlertExtension } from "./gfm-alert-extension.js";
import { imageExtension } from "./image-extension.js";
import { rawHtmlExtension } from "./raw-html-extension.js";
import { referenceLinkExtension } from "./reference-link-extension.js";
import { tableExtension } from "./table-extension.js";

/** The ordered feature set shared by reference pipeline and extension tests. */
const commonFeatureExtensions: readonly ContentExtension[] = Object.freeze([
    gfmAlertExtension,
    tableExtension,
    collapsibleExtension,
    footnoteExtension,
    referenceLinkExtension,
    imageExtension,
]);

/** The complete ordered feature set used by the trusted document-tree editor. */
const documentTreeFeatureExtensions: readonly ContentExtension[] = Object.freeze([
    ...commonFeatureExtensions,
    rawHtmlExtension,
    badgeExtension,
]);

/** The reference content pipeline without document-tree-only raw HTML and badge support. */
export const commonContentPipeline = createContentPipeline(commonFeatureExtensions);

/** The production document-tree content pipeline. */
export const documentTreeContentPipeline = createContentPipeline(documentTreeFeatureExtensions);

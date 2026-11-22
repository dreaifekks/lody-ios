/**
 * Web APIs the runtime uses that are newer than its oldest WebView (iOS 16.4
 * WebKit, Android System WebView from Chrome 100). Each fallback installs only
 * where the API is missing. Import this module before any other: the runtime
 * entry does, and so must every host document that bundles runtime modules.
 */
import { installAbortSignalAny } from './abort-signal-any.ts';
import { installUrlCanParse } from './url-can-parse.ts';

installAbortSignalAny();
installUrlCanParse();

# Local validation — October 12, 2026

Validated on Apple silicon running macOS 27.0.1, built with Xcode 27.0 and a macOS 14 deployment target.

## Automated integration checks

Both native test executables passed. Coverage includes:

- Original path, hard link, symlink, parent-directory alias and changed-source protection.
- Current-page and all-page clockwise rotations, existing rotations and full turns.
- Preserved vector text/font resources and filled form values/flags.
- Unchanged embedded JPEG dimensions and exact decoded pixel bytes after export.
- Byte-for-byte unchanged original files after successful and rejected exports.
- Safe replacement of other existing files and rejection of invalid destinations.
- Password prompting errors, encrypted export refusal, natural file order and ten-file recent history.
- Private snapshot cleanup and isolation after later source modification.
- Fit-width geometry, stable fit while scrolling, five-percent manual zoom and range limits.
- Blocked form interactions, PDF actions, print commands and context menus.
- Arrow navigation and smooth repeated vertical scrolling.

The optional 200 MiB generated-file check confirmed the APFS clone path and snapshot isolation. This measures opening a simple synthetic PDF with padding, not rendering a complex 200 MiB scanned or graphics-heavy document.

## Live application checks

- Direct file opening and the in-app Open dialog reuse the same window.
- A deliberate second application launch left exactly one app process and opened the requested PDF there.
- Folder permission is remembered, filename sorting is natural and counters update correctly.
- The zoom percentage follows the slider; minimum and maximum captions remain visible.
- A generated 500-page document scrolls and reports the correct current page. One idle observation after scrolling used approximately 216 MiB resident memory with 0% CPU; this is a spot check, not a universal performance guarantee.
- Save As starts in the original folder and successfully writes a rotated copy to a different, separately selected folder in the sandboxed app.
- Explicitly choosing the original filename, including accepting macOS's Replace confirmation, was rejected by the app. The original SHA-256 stayed unchanged.
- About displays Nikhil Sharma, the OpenAI ChatGPT-model credit and the update date.
- Test PDFs were cleared from recent-file history before handoff.

## Privacy/package checks

The app uses App Sandbox and the hardened runtime, with local ad-hoc signing and no networking entitlement. The signing team identifier is absent. Source and executable scans found no personal home paths, account email addresses or development-signing identity. The source licence can be selected when preparing the eventual public release. This local app is not a notarized public binary distribution.

Encrypted PDFs can be viewed, but rotated exports of encrypted PDFs are intentionally unavailable. The original always remains protected.

## Version 1.1 update

- Application and menu identity changed to Jack's PDF while retaining the bundle identity for local history compatibility.
- App-owned visible labels, buttons, dropdown menus and dialogs use Avenir Book at 22 points, matching the filename. Native macOS file panels, system confirmations, menu-bar titles and tooltips remain OS styled. PDF content retains its own fonts.
- The updated icon includes Jack's above PDF. Jack's original JPEG is bundled byte for byte and displayed proportionally in a 128 × 96 point centred rounded frame. The exact requested memorial appears in About.
- Both existing native integration suites passed again. Focused native checks verified zoom caption bounds and five-percent steps, custom-sheet text sizing and screen fit, password focus, Return and Escape responses.
- Live checks verified the renamed installed app, default-window header, rotation menu, About photo and tribute, invalid-PDF error, and Save As / Discard / Cancel warning. Cancel retained the pending rotation; Discard closed the generated test document.
- Offscreen header checks at 800, 1000 and 1186 point widths passed with both PDF counts and the longer folder-access prompt, including zoom captions at both limits. Narrow windows use a 192-point header; wider windows retain 112 points.
- The installed app is approximately 2.4 MiB. Its code signature verifies, and its bundle contains no old font dependency. The complete wording review is delivered separately as HTML and plain text.

## Version 1.2 update

- Main filename remains 22-point Avenir. Other app-owned text, numbers, dropdown menus and dialogs use 19-point Avenir. Zoom controls are 400 × 66 points, with smaller buttons; dialog buttons are 34 points. macOS-owned file pickers, menu-bar titles and tooltips retain native system styling.
- The folder counter follows the file size on the filename row; the path remains on the second row. Long names scroll without expanding the window.
- Focused native layout checks passed all 12 combinations of three window widths (800, 1000, 1186 points), normal/long filenames, and normal counter/folder-access prompt. Each also passed at 20%, 100% and 200% zoom.
- All menu key equivalents are empty, including user-defined override support being disabled. Live checks verified former Open, Close, Rotate, Actual Size, Save As and Quit shortcuts do nothing, while mouse menu actions work. Hide is absent; the green window button is hidden and disabled.
- Live Save As shows the requested text: “To prevent accidental overwriting, original PDF is always protected. Choose a different filename.” About retains the exact memorial and unchanged photograph, now with 19-point copy.
- Dialog focus, standard Return/Escape responses, compact controls and long-text scrolling pass focused native checks. PDF loading/rendering/export logic is unchanged from the previously validated version.
- Installed version 1.2 verifies against the final build and its code signature. Exactly one matching app is present across Applications locations; older copies are preserved outside Applications. The text review and packaged source/app are refreshed for this version.

## Version 1.3 update

- Main filename is 20-point Avenir; every other app-owned label, number, menu and dialog uses 16-point Avenir. Native macOS file panels, menu-bar titles and tooltips retain system styling.
- Fit now has an unadorned, centred “Fit” label in both states. The former checkmark/leading-space variants are removed; active blue fill and accessibility On/Off state remain. Zoom controls are 350 × 58 points.
- About now follows the requested sequence: app name, descriptor, arrow-key instructions, creator, model credit, date, version, textual divider, unchanged memorial and original centred photograph last. Live visual inspection confirmed the normal-window modal fits without clipping.
- Focused native checks passed all 12 combinations of 800/1000/1186-point widths, normal/long filenames, and folder-counter/access-button states, each at three zoom positions. Filename and other font sizes, Fit centering, no overlap, no window expansion, no menu shortcuts and hidden green window button were verified.
- Custom dialog checks passed content ordering, 16-point labels, 30-point buttons, original 128 × 96 photograph, small-window scrolling, password focus and Return/Escape responses.
- Installed version 1.3 matches the tested binary and its signature verifies. Exactly one matching app remains across Applications locations; previous versions are outside Applications.

## Version 1.4 update

- All highlighted metadata and toolbar text now uses 13-point Avenir, matching app-owned menus, About and dialogs. The filename remains 20 points. Controls use native small sizing, including the slider thumb/track, Rotate, Fit and zoom buttons.
- Zoom controls measure 300 × 48 points. Focused checks verified label alignment with the smaller native thumb (within 0.6 points at the range endpoints and midpoint), unclipped 13-point captions, Fit centering and five-percent snapping.
- All 12 header combinations of 800/1000/1186-point widths, normal/long filenames and counter/folder-access state passed. Windows keep their intended width, with no unwanted clipping or overlap. Headers measure 134 points at the narrow size and 76 points at normal sizes.
- Dialogs use a 480-point panel, compact 24-point native small buttons and 13-point text. The normal-window About fits completely with the original photo; long errors scroll in small windows. Password focus and Return/Escape checks passed.
- Existing About sequence, menu shortcut removal, hidden green window button, source protection and PDF rendering/export behavior remain intact.

Live visual checks confirmed the compact toolbar and matching About text. Installed version1.4 matches the tested build, its signature verifies, and exactly one app remains in Applications locations.

## Version 1.4.1 update

- Added matching “• • •” text dividers after the About title, after the description, and above the creator credit. The existing divider before the memorial remains.
- The release build succeeded. Live inspection of the installed app confirmed all four dividers and the complete About content, including Jack's photo, fit without clipping at the normal window size.
- Installed version 1.4.1 matches the new build and its code signature verifies. Exactly one matching app remains in Applications locations. This wording-only update does not change PDF behavior; the full integration suites were not repeated.

## Version 1.4.2 update

- Removed the em dashes from the two About keyboard instructions. The release build and signature verification passed. Live inspection of the installed app confirmed both revised lines and the complete About layout.
- Exactly one matching app remains in Applications locations. Text review and app/source packages were refreshed. PDF behavior is unchanged; full integration suites were not repeated for this wording-only update.

## Version 1.5 update

- Header metadata occupies fixed, left-aligned slots in the order file size, PDF counter, and page counter. The controls are anchored to the right; their positions depend only on window width. The header is 76 points high normally and 134 points below 1000-point width.
- Native header regression checks passed 35 scenarios across 800, 1000 and 1186-point widths and resize round trips. Short/long names, empty/loading states, differing sizes and counts, the folder-access prompt, and clean/dirty Rotate labels produced identical control frames without overlap or window expansion.
- Rotation now uses opaque temporary page layers for a 600 ms clockwise turn with easing, perspective and shadow. Each queued click advances an unbounded visual angle by 90 degrees, including across full turns. Native PDF orientation changes synchronously for export; temporary rasters share a four-million-pixel budget and are removed afterward.
- Native reader checks passed live presentation-angle sampling, five rapid turns through 450 degrees, all actually visible pages before/after Rotate All, bounded snapshot allocation, and cleanup on zoom, scrolling, resize, document close and Reduce Motion. Fit now recentres the active page after mixed-orientation rotations; the regression reproducer stays centred within one point.
- DocumentSupport checks passed original-path/link protection, vector/text and annotation preservation, unchanged scanned-image pixels, permitted replacement, invalid destinations, encrypted-file safeguards, history and snapshot cleanup. The restricted command sandbox blocked one temporary export test; the same test executable passed with normal macOS service access.
- Live app inspection confirmed fixed header positions while navigating among generated 2, 3, 6 and 500-page documents, opaque clockwise turns, repeated clicks and simultaneous visible-page rotation. The generated source PDFs remained byte-for-byte unchanged.
- The final native regression and installed-app check reproduce Fit, 65% zoom, five rapid current-page turns, Rotate All, Fit and two more rapid current-page turns. The active first page remains visible and horizontally centred, and the counter correctly reports Page 1 of 2 after animation ends. Rotation restores the visual top of the active page rather than reusing orientation-dependent page coordinates.
- Final version 1.5 is installed in Applications and matches the signed release binary. Only that copy is registered for Finder Open With. App/source archives and the 140-entry wording review are refreshed; prior installed versions are preserved outside Applications.

## Version 1.5.1 update

- Added an explicit line break before “You may be gone…” in the About memorial, retaining centred alignment and the exact wording.
- The release build and signature verification passed. Live inspection of the installed app confirmed the second sentence starts on its own line and the complete About content and photo fit.
- Installed version 1.5.1 matches the release binary. Only the Applications copy is registered with Finder; source/app archives and the wording review are refreshed. This layout-only change does not alter PDF behaviour; integration suites were not repeated.

## Version 1.5.2 update

- Replaced the final memorial sentence with “You are still in our hearts and our lives every day.” The sentence remains centred on its own line.
- Release build and signature verification passed. Live inspection of the installed About panel confirmed the revised wording, complete layout and photograph.
- Installed version 1.5.2 matches the release build; only the Applications copy is registered in Finder. Source/app archives and the wording review were refreshed. PDF behaviour is unchanged; integration suites were not repeated for this wording-only update.

## Version 1.5.3 update

- Fixed rotation visibility after PDFKit layout: AppKit can reorder the native scroll-view backing layer above a newly inserted animation layer. The temporary animation now has an explicit higher stacking position, preserving its existing 600 ms turn, perspective and shadow.
- A new regression checks both the live presentation and its visibility above native PDF content after layout. It failed against the previous implementation and passed with the fix. Twenty-four separate completed turns passed across Fit, manual zoom and Rotate All, alongside existing rapid-click/full-turn, page-position, bounded-memory, cancellation, read-only interaction and scrolling checks.
- The release build and signature verification passed. Live inspection of the installed app confirmed visible clockwise turns during a repeated-click sequence. Only the Applications copy is registered with Finder; previous versions are preserved outside Applications.

## Version 1.6 update

- Clicking a visible page now explicitly chooses it without changing zoom or scroll position. A thin accent-coloured outline, the page counter and read-only accessibility follow that page; Rotate and Fit use the same selected page. Empty-canvas clicks preserve the choice.
- Explicit focus survives rotation and zoom and resets on actual scrolling or a different document. Copy restrictions do not prevent choosing a page. Animation clicks hit the visible paper rather than transparent snapshot containers. Short documents that already fit no longer shift vertically in response to arrow scrolling.
- Native focus regression failed before implementation and passed afterward. Checks cover all three pages at 20%, unchanged click geometry, callbacks/accessibility/outline, selected-only rotation, queued animation, Fit/manual zoom, blank canvas, blocked and actual scrolling, cumulative subpixel movement, clicking an animated page, read-only forms, text selection, copy-restricted PDFs and document reset. The complete ReaderView suite passed; focused checks passed again after final edge-case refinements.
- Release build and signature verification passed. Live inspection of installed version 1.6 confirmed clicks on page 3 and page 1 at 20%, rotation of only the chosen page, Fit targeting it and the complete About layout with the new instruction. The installed binary matches the release build, and only the Applications copy is registered in Finder. The 141-entry text review and app/source archives were refreshed.

## Version 1.6.1 update

- The unsaved-rotation warning now appears only when quitting the app or closing its window. Arrow navigation, Open, Open Recent and Close PDF do not show it. Successful document replacement discards temporary rotations without modifying the original; the existing loader retains the current document if the next load fails or is canceled.
- Live checks on generated PDFs passed rotated Example 1 → Right → Example 2 and rotated Example 2 → Left → Example 1 without any warning. Returning to Example 1 showed its original orientation. Close PDF also returned directly to the empty viewer with pending rotations.
- Both the red window close button and Quit still displayed the warning. Cancel preserved the sample and its rotations; choosing Save As and then canceling the save panel also left them open. The warning now says “Save a rotated copy before closing.” Failed-load preservation was checked by source review, not a new live failure test.
- Release build and signature verification passed. Installed version 1.6.1 matches the release binary; only the Applications copy is registered for Finder. Generated PDF hashes remain unchanged. The 141-entry text review and app/source archives were refreshed. Rendering and rotation code are unchanged, so the ReaderView suite was not repeated for this application-flow change.


## Version 1.6.2 update

- File size and folder position now occupy narrower, right-aligned fixed slots immediately before the page counter, separated by centred dots. The existing page, Rotate and zoom anchors remain unchanged. Separators are hidden without a PDF. The folder-access button reads “Browse folder…” to fit its compact slot, retaining its full access description for accessibility.
- Zoom captions now read “Min. 20%” and “Max. 200%”. Focused header checks passed fixed positions and non-overlap at 800, 1000 and 1186 points, including resize round trips, empty/loading states, filename/count changes, folder-access and dirty-rotation labels. Four-digit PDF counts and the folder prompt fit; exceptional longer counts retain middle truncation and the complete tooltip. Dot glyphs and zoom captions fit, with zoom-label separation verified through 400% Fit.
- Live inspection confirmed visible dots, right-aligned metadata and punctuated zoom captions. Navigation between generated PDFs retained the layout, and closing the sample cleared document labels, separators and accessibility labels. Reader rendering and rotation behavior are unchanged; their full integration suites were not repeated.
- Release build and signature verification passed. Installed version 1.6.2 matches the final release binary, only the Applications copy is registered with Finder, and generated source PDFs are unchanged. The app/source archives and 143-entry wording review were refreshed.


## Version 1.6.3 update

- Tightened the metadata by measuring the widest file index in the current folder with the native button cell. Size and counter right edges stay fixed during same-folder navigation, including index digit changes; Page, Rotate and zoom anchors remain unchanged. For 55 PDFs, the counter reserves 80 points instead of 112, removing 32 points of unused space. Native text-cell measurements include the size label's drawing inset so its units do not clip.
- Added a separator before the file size. All three separators now use the larger bullet glyph in Avenir Heavy at 13 points; metadata remains Avenir Book at 13 points. Separators hide when the reader is empty.
- Focused checks passed 390 geometry cases covering folder counts, digit transitions, filenames, size strings, missing-folder access, long counters, 800/1000/1186-point windows and resize round trips. Offscreen and installed-app visual checks confirmed the complete size label, compact spacing and bold bullets. Live sample navigation and document-close checks passed. Rendering, rotation and export logic are unchanged; broader integration suites were not repeated.
- Release build and code-signature verification passed. Installed version 1.6.3 matches the final release build, and only the Applications copy is registered with Finder. Generated PDFs retain their original hashes. App/source archives and the 143-entry wording review were refreshed.


## Version 1.6.4 update

- Removed the shared, outdated left-column width that clipped names and paths before the space reclaimed by compact metadata. At normal widths, the filename now extends to 12 points before the actual first bullet and the path independently extends to 12 points before Rotate. Narrow windows retain full-width text rows above the controls.
- Text viewports sit above the transparent control-group container, so the newly usable region also accepts selection and horizontal scrolling. Counter, rotation and zoom anchors, fonts and metadata spacing are unchanged.
- Focused checks passed 546 geometry cases across 800/999/1000/1186-point widths and resize round trips. They verify exact available widths, non-overlap, stable metadata anchors including index 9→10, hit testing within reclaimed regions, and horizontal scroll-to-end/back. A rendered fixture matching the reported filename displayed its complete name and path; installed-app inspection also confirmed the generated sample's full path now appears. The PDF rendering/export suites were not repeated for this header-only change.
- Release build and code-signature verification passed. Installed version 1.6.4 matches the final build and is the only Finder-registered copy. Generated PDFs remain unchanged. App/source archives and the 143-entry wording review were refreshed.


## Version 1.6.5 update

- The filename now uses 13-point Avenir Book, matching other header text. Its 20-point-high viewport aligns with the metadata row at normal widths and retains the existing expanded horizontal space.
- The lower row and its tooltip now show only the containing folder path, derived from the source URL's parent. The actual source URL, window title, recent-file tooltip, saving and navigation behavior are unchanged.
- Release build and signature verification passed. Live installed-app inspection confirmed matching filename text size/alignment and a folder-only path. Switching between two generated PDFs changed the filename while preserving the same correct folder path; closing cleared the labels. This small presentation change did not require new tests or a repeat of the PDF integration suites.
- Installed version 1.6.5 matches the final build and remains the only Finder-registered copy. Generated sample hashes are unchanged. App/source archives, documentation and the 143-entry wording review were refreshed.

## Version 1.6.6 update

- Added the static app name beside the close and minimize buttons using a native left title-bar accessory and matching 13-point Avenir. The system window name still identifies the open PDF, and the green window button remains hidden.
- Focused native checks at 800 and 1186 points verified an 11-point gap after the minimize button, unchanged 32-point title-bar height, correct font, stable title and draggable label/container. Rendered and live installed-app inspection confirmed the label beside the window buttons. PDF viewing and export code are unchanged, so their integration suites were not repeated.
- Release build and signature verification passed. Installed version 1.6.6 matches the final build and is the only Finder-registered copy. Generated PDFs retain their original hashes. App/source archives and the 143-entry wording review were refreshed. The README includes Apple's Finder instructions for choosing a default PDF app; the app does not change that preference itself.

## Version 1.6.7 update

- About now begins with the bundled app icon at 64 × 64 points, centred above a three-dot text separator and the existing app-name heading. Optional heading content defaults to absent in other dialogs; their layouts and typography are unchanged.
- Release build and signature verification passed. Live installed-app inspection confirmed the icon, separator and app name in order, matching text size, unchanged memorial and photo, accessible image label and visible Done button. The existing scroll area accommodates the extra content on shorter windows; scrolling to the photo and back to the icon passed. No new tests or repeat of PDF integration suites were needed for this presentation-only change.
- Installed version 1.6.7 matches the final build and is the only Finder-registered copy. Generated sample PDFs remain unchanged. App/source archives and the 145-entry wording review were refreshed.

## Version 1.6.8 update

- About uses a full-height plain content view with no scroll view or scrollbar. Removed full blank rows around section dividers, tightened vertical spacing and outer margins, and reduced the app icon to 48 points. Text remains 13-point Avenir; all wording, section dividers and the complete 128 × 96-point memorial photo remain. The panel remains nonresizable and sizes to its contents independently of the reader window height.
- Release build and signature verification passed. Live inspection confirmed the complete icon, text, photograph and Done button visible together, with no scroll area or scrollbar in the accessibility tree. Source review confirmed generic long-message dialogs retain their prior bounded scrolling and spacing. No new tests or PDF integration-suite repeat were required for this layout change.
- Installed version 1.6.8 matches the final build and is the only Finder-registered copy. Generated sample PDFs remain unchanged. App/source archives, documentation and the 145-entry wording review were refreshed.

## Version 1.6.9 update

- Registered the existing AppIcon.icns as the app's PDF document icon. Finder thumbnail preferences and individual PDF files were not changed; content previews may still take precedence over the document icon.
- Release build and signature verification passed. A read-only native macOS query confirmed Jack's PDF was already the default PDF app and resolved its registered PDF type icon to the intended colourful Jack's PDF artwork, verified visually. The installed app reopened successfully. No PDF rendering or layout tests were repeated for this bundle-metadata change.
- Installed version 1.6.9 matches the final build and is the only Finder-registered copy. Generated sample PDFs retain their original hashes. App/source archives, documentation and the 145-entry wording review were refreshed.

## Version 1.6.10 update

- Added a 16-point app icon immediately before the title-bar app name, with a six-point gap and unchanged 13-point Avenir text. The existing native title-bar accessory remains beside the close and minimize buttons.
- Release build and signature verification passed. Live installed-app inspection confirmed the icon and name placement, accessibility image label and successful reopening of the previously open PDF. Finder preview settings were not changed by this app update. No new tests or PDF integration-suite repeat were required for this title-bar presentation change.
- Installed version 1.6.10 matches the final build and is the only Finder-registered copy. Generated sample PDFs retain their original hashes. App/source archives, documentation and the 145-entry wording review were refreshed.

## Version 1.7 update

- Removed the Window menu and all former View commands. View now contains only Full Screen, changing to Exit Full Screen while active. Native full screen temporarily releases the normal 16:10 aspect constraint; the normal window restores it afterward. No menu shortcuts or green window button were added.
- Recent-file metadata now persists independently of permission bookmarks. Successfully opened PDFs retain a newest-first, deduplicated ten-entry history even when bookmark creation fails. Existing history migrates unchanged. Bookmark resolution falls back to the stored path without altering history, and successful reopening renews access. Unavailable entries offer Locate File, Remove from History and Cancel; locating replaces the entry only after successful loading. Recent-file opens do not request a folder grant.
- The complete DocumentSupport suite passed outside the tool sandbox, including added coverage for failed bookmark creation, metadata-only persistence, legacy history, invalid bookmark fallback, replacement/deduplication, reference removal and clearing. An initial sandboxed run could not perform a macOS coordinated save; rerunning with normal host access passed. Source protection, export fidelity, encryption and snapshot cleanup checks also passed.
- Live installed-app checks confirmed no Window menu, exactly one View item, successful full-screen entry/exit, migration of ten existing recent entries and direct reopening of a recent PDF. A separate sandboxed test app with in-memory history verified missing-file recovery, successful locating without a folder prompt, replacement of the stale entry, Cancel preserving the currently displayed PDF and unsaved rotations, and Remove from History preserving that PDF while removing only its history reference. Its recovery dialog was inspected visually. The test app was closed and unregistered afterward.
- Release build and signature verification passed. Installed version 1.7 matches the final build, generated fixture hashes remain unchanged, and app/source archives plus the 148-entry wording review were refreshed. The ReaderView integration suite was not repeated because PDF rendering code was unchanged.

## Public release 1.7

- Rebuilt the Apple-silicon release and reran both complete native integration suites on October 12, 2026. All DocumentSupport and ReaderView checks passed, including permission-independent history and recovery, 24 completed animated turns, rapid repeated turns, active-page selection, source protection and export fidelity.
- Removed EXIF and editing metadata from the public Jack photograph without recompression. Exact decoded RGB equality with the original was verified; the image dimensions remain 1024 × 768. This supersedes earlier byte-for-byte photo packaging notes.
- Added the MIT licence, a visually reviewed eight-page PRD, public build/download instructions and the wording inventory. Private documents, preferences, bookmarks, intermediate logs and signing identities are excluded from publication.
- The version 1.7 binary is ad-hoc signed with App Sandbox and the hardened runtime; it is not notarized. The Intel architecture and every supported macOS version have not been tested.

## Version 1.8 local update - October 13, 2026

- Added explicit Clear History confirmation. Cancel is the default for Return/Escape; confirmation clears recent entries and saved folder approvals, invalidates active folder navigation and prevents an in-flight folder scan from restoring the old catalog. The open PDF and rotations remain unchanged.
- The native folder picker now explains optional navigation access, showing filename and full folder path. Declining keeps the current PDF readable; arrow keys do not repeatedly request access. Browse folder remains available.
- Enabled Open, Save As, Close Window, Quit, Full Screen, manual zoom, 100%, Fit and current/all-page rotation shortcuts. Existing copy, select-all, arrow scrolling, page-up/down and dialog keys remain. No Find shortcut or feature was added. View still contains only Full Screen.
- Added AES-256-GCM encrypted local history and up to 10,000 read-only folder bookmarks, with least-recently-used eviction. The local Keychain holds a random 256-bit key with an app-specific ACL. Migration removes legacy preferences only after encrypted write/read verification. Missing keys or invalid ciphertext never trigger silent replacement or plaintext fallback. Only the current folder is actively leased.
- Both complete existing native suites passed. New storage tests passed migration, restart, authenticated-encryption/tampering/wrong-key checks, private permissions, nonce freshness, failure preservation, durable clearing and 10,000-folder round trips. The generated 10,000-folder case completed in approximately 0.20 seconds on the test Mac; this is a fixture spot check, not a performance guarantee.
- An isolated sandboxed app verified real Keychain storage and readback following a changed ad-hoc signature; macOS required the user's approval after that simulated update. This approval may be needed for future unsigned/ad-hoc updates; the app does not weaken Keychain access controls to avoid it.
- Live checks verified the revised folder picker, cancellation, approved-folder arrow navigation, encrypted recent-file reopening, Clear History's default Cancel and explicit clearing, preservation of active rotations, and the selected shortcuts. Full-screen transition guards prevent commands from presenting sheets during window transitions.
- This update is local only. Nothing has been committed, pushed or released to GitHub. The PRD remains the explicitly labelled version 1.7 public baseline.

- Installed version 1.8 build 24 in Applications; the installed executable matches the release build and passes strict signature verification. The pre-upgrade preferences were already empty at installation (zero recent files and zero folder approvals). First launch created encrypted storage with 0600 file/0700 directory permissions and removed both legacy preference keys; non-empty migration was verified in the isolated automated fixture.

- A subsequent full-screen exit check exposed AppKit rejecting a restoration frame after `aspectRatio = .zero`. Replaced that reset with `resizeIncrements = NSSize(width: 1, height: 1)`, the documented way to cancel an aspect constraint, and kept transition guards. Reference: https://developer.apple.com/documentation/appkit/nswindow/aspectratio.

- The final corrected build completed live full-screen entry/exit, restored enabled menus and displayed the complete non-scrolling About panel. The user approved Keychain access for the final changed signature. App/source archives were refreshed locally; the public version 1.7 archive and Git commit remain unchanged.

## Version 1.8.1 local update - October 13, 2026

- Added Shortcuts directly below About and above Quit in the app menu. The nonresizable reference modal pairs related commands where useful and lists all implemented reader commands, page-up/down alternatives, copy/select-all and dialog keys. It uses the same 13-point Avenir typography and contains no scroll view. Folder-navigation and PDF copying limitations are noted.
- Removed the Instructions section from About while retaining its icon, credits, dividers, memorial text and photo. About remains nonresizable without scrolling.
- Release build and signature verification passed. A live isolated preview of the actual dialog component and reference data confirmed complete, aligned text and a visible Done button with no scrollbar, including in a 960-by-600-point host window. No keyboard command, history, PDF rendering or save behavior was changed; the native PDF suites were not repeated for this presentation-only update.
- Changes and refreshed app/source archives remain local; GitHub publication is still on hold.

- Installed version 1.8.1 build 25 matches the final build and is the only registered production copy. After the user approved its changed Keychain signature, live checks confirmed the exact About → Shortcuts → Quit order, the complete shortcuts list without a scroll area, Escape dismissal, the shortened About contents and Return dismissal. The wording review contains 171 entries across 19 groups.

## Public release 1.8.1

- Publication includes the tested 1.8 history/security/shortcut changes and the 1.8.1 Shortcuts/About presentation update. The release archive uses the same signed app bytes installed and visually checked locally; documentation-only publication changes do not rebuild or re-sign the app.
- Existing DocumentSupport and ReaderView suites and the new EncryptedLibrary suite passed during implementation. Final live checks covered Keychain approval, Clear History/Cancel, folder-access flow, selected shortcuts, corrected full-screen restoration, the complete Shortcuts modal and revised About contents.
- Updated the PRD, wording inventory, download links and Keychain prompt explanation for the current public version. Exclude local test apps, logs, Keychain contents, history, private documents and machine paths from source and downloads. The author uses the established GitHub no-reply email.

## Version 1.9 local update — November 5, 2026

- The borderless PDF counter now opens a compact, 13-point Avenir menu for natural filename order or full creation date-time order (newest first). Its permanent chevron and widest-index reservation keep the header stable. The non-sensitive global preference is remembered independently of encrypted history and folder permissions.
- Timestamp ordering uses the original files' filesystem metadata, including fractional precision. Equal dates use natural filename order with an exact-path tiebreaker; missing/invalid dates come last. Renamed files are matched by filesystem identity, while replaced paths and ambiguous hard links are not mistaken for the loaded document.
- Navigation refreshes the folder before choosing the next file, preserves the current PDF on failed opens, and does not wrap at boundaries. An unavailable folder offers an explicit access-recovery action. Stale background scans cannot overwrite newer folder results.
- All three native suites passed: document/export/source protection, reader/rotation/interaction, and encrypted library/shortcuts. Added sorting tests cover real and fractional creation times, timestamp ties/fallbacks, unchanged timestamps, preference persistence, and renamed/replaced files.
- Isolated AppDelegate tests passed 68 layouts at 800, 999, 1000 and 1186 points, with virtual counts through 1,000,000 PDFs. Changing order preserves document identity, reading position, zoom, rotations, unsaved state and history. Actual asynchronous arrow navigation and the recovery menu were checked.
- Live isolated-app checks confirmed the real dropdown, both navigation orders, and unchanged 100% zoom. Test documents/preferences/history were isolated from the production library.
- Release preparation updated the nine-page PRD and the 185-entry wording inventory. Every installed bundle file matches the tested build. The app archive preserves those bytes and executable permissions without copying extended attributes or local user data.

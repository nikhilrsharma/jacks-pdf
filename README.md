# Jack's PDF

<img src="Resources/AppIcon.png" alt="Jack’s PDF icon" width="112">

A private, minimalist PDF reader for macOS, created by Nikhil Sharma with OpenAI ChatGPT models.

Version 1.7 · Last updated October 12, 2026 · macOS 14 or later

## Download and documentation

[Download version 1.7](https://github.com/nikhilrsharma/jacks-pdf/releases/tag/v1.7) for Apple silicon, or build from source below. The app requires macOS 14 or later. Extract the ZIP and place **Jack’s PDF.app** in Applications, replacing an older copy if present.

The downloadable app is ad-hoc signed, **not notarized by Apple**. macOS may block a downloaded copy; follow [Apple’s guidance for apps from outside the App Store](https://support.apple.com/102445) only if you trust this release, or build it locally. Do not disable Gatekeeper globally. An Intel release has not been validated.

- [Product requirements document (PDF)](docs/Jacks-PDF-PRD.pdf)
- [Complete app wording review](docs/App-Text-Review.txt)
- [Validation history](VALIDATION.md)
- [Privacy and file safety](SECURITY.md)

## Reading

Open the app and choose **Open PDF…**, or use Finder's **Open With → Jack's PDF**. The app has one window and displays one PDF at a time. Opening another PDF replaces the current one without a rotation warning. Unsaved rotations are discarded only after the next PDF loads successfully; returning to the previous file shows its original orientation.

- Dark interface with Avenir typography and a colourful Jack’s PDF icon. All app-owned text, including the filename, numbers, menus and dialogs, is 13 points with compact native controls, a smaller slider and tighter spacing; native macOS file pickers and system confirmations keep their standard appearance. PDF pages retain their own colours, fonts and layout.
- Continuous vertical pages with subtle separation and smooth scrolling. There is no preview pane.
- **Click a page** to make it active without moving the document or changing the zoom. A thin accent-coloured outline identifies it; the page counter, Rotate and Fit use that page. Scrolling the document resumes normal page tracking. Clicking empty canvas leaves the chosen page active.
- **Up / Down** scroll through the document. **Left / Right** open the previous or next PDF in the same folder. Navigation stops at either end.
- The header groups right-aligned file size and folder position immediately before the page counter, with bold bullet separators before the size and between each field. The metadata fits the widest PDF index in the current folder, keeping its right edges fixed during navigation without reserving unused space for larger folders. The filename uses the available width up to the first metadata bullet. The containing folder path below omits the filename and has its own wider viewport up to the Rotate control; both keep a 12-point gap before their neighbouring element. Long filename and path rows can be scrolled horizontally; hover also reveals their full text.
- Folder navigation needs access to that folder. The app asks through the standard macOS folder picker and remembers the permission locally. It counts visible, readable, regular `.pdf` files in that folder only, in natural filename order (`2.pdf` before `10.pdf`). Hidden files, symbolic links, packages and subfolders are excluded.
- **Fit** uses a plain centred label, with a blue background when active. It adjusts the zoom to the current page's width. Zoom changes never reflow text. Explicitly opening a file starts in Fit mode; navigating between files keeps the chosen zoom mode. Fit remains stable while scrolling and adjusts when the window or fitted page is rotated.
- Manual zoom runs from **20% to 200% in 5% steps**, with a percentage label that follows the slider. Fit can use a scale outside the manual range when the page dimensions require it.
- The header rearranges into two rows in narrower windows, keeping all labels at 13 points. Long filenames scroll within their allotted space.
- Outside full screen, the window uses a fixed **16:10** aspect ratio and fits within the screen with space around it. The title bar displays a small app icon followed by “Jack’s PDF” beside the close and minimize buttons in 13-point Avenir. The green window button is hidden. **View → Full Screen** enters native full screen; **Exit Full Screen** returns to the normal window. View contains no other commands, and there is no Window menu.
- Menu commands are selected by mouse and have no keyboard shortcuts. There is no Hide menu item. Reading arrows and standard dialog Return/Escape behavior remain available.
- **File → Open Recent** keeps the last ten successfully opened PDFs locally, newest first without duplicates, even if persistent permission could not be saved. Valid saved access reopens directly. If a file is unavailable or access is lost, choose **Locate File…**, **Remove from History**, or **Cancel**. Locating and successfully opening a file updates its existing entry; cancellation or a failed open preserves both history and the current PDF. **Clear History** removes all recent-file references and saved folder permissions. Reopening a recent PDF does not require selecting its folder; use **Browse folder…** when neighbouring-file navigation is needed.

The app offers no printing, sharing, cloud-upload, document-properties, annotation-editing or form-filling commands. Text can be selected and copied when the PDF permits copying. Embedded PDF actions and links are not activated.

## Default PDF app

In Finder, select any PDF and choose **File → Get Info**. Expand **Open with**, select **Jack’s PDF**, then click **Change All** and confirm if prompted. This changes the default for PDFs on this Mac. The app does not change that system preference itself. The app supplies its colourful icon for PDF documents. Finder may show this document icon when Jack’s PDF is the chosen PDF app; content thumbnails and custom file icons can take precedence. Thumbnail settings are left unchanged. See [Apple’s instructions](https://support.apple.com/guide/mac-help/choose-an-app-to-open-a-file-on-mac-mh35597/mac).

## Rotating and saving a copy

Click **Rotate** to turn the current page 90° clockwise. The adjacent arrow offers **Rotate current page** and **Rotate all pages**. Turns use a smooth 600 ms clockwise animation with subtle perspective and shadow movement, respecting the Mac's Reduce Motion setting. Repeated clicks continue clockwise through full turns. Four turns restore the original orientation.

Choose **File → Save As…** after rotating. The standard save dialog starts in the original folder with a suggested new filename. The original file is always protected, including alternate paths and hard links to it. Other existing destination files may be replaced after the standard confirmation. Unsaved rotations prompt **Save As / Discard / Cancel** only when quitting the app or closing its window. Switching PDFs with the arrows, Open or Open Recent, and choosing Close PDF, do not show that warning. These actions discard unsaved rotations without modifying the original.

Rotation uses native PDF page orientation rather than rasterizing the document. Export disables image downsampling and JPEG conversion and preserves native text/vector content. The tests check generated vector/text/form PDFs and a scanned JPEG fixture, including unchanged decoded image pixels and unchanged source bytes. These checks are not a guarantee for every unusual PDF or digital-signature workflow.

Password-protected PDFs can be opened with their password. Rotated export of encrypted PDFs is currently unavailable because the app does not silently remove or weaken their protection. Passwords are not written to history.

The nonresizable About dialog shows its complete contents without scrolling, using compact vertical spacing and the same 13-point text. It starts with the centred app icon and a text divider, followed by the app name and description, terse arrow-key instructions, creator and model credits, update date and version. Text dividers separate the title, description, instructions, credits and tribute, followed by the unchanged photograph of Jack in a small, centred rounded frame. The tribute reads: “In loving memory of Jack, our sweetest companion and forever friend. You are still in our hearts and our lives every day.”

## Build locally

Install Xcode with its macOS SDK, then run from this directory:

```sh
./build.sh
open "build/Jack's PDF.app"
```

The script uses `/Applications/Xcode.app/Contents/Developer` unless `DEVELOPER_DIR` is already set. It builds for the current Mac's architecture (`arm64` on Apple silicon), uses release optimization, and creates a locally ad-hoc-signed app with App Sandbox and the hardened runtime. It does not use an Apple ID, Developer ID certificate, provisioning profile or signing team.

Optional build settings:

```sh
BUILD_DIR="/absolute/path/to/build" ./build.sh
ARCH=arm64 ./build.sh
```

The build output is local and is not notarized for public binary distribution. Nothing is uploaded or published by the build script. Native Swift, AppKit and PDFKit supply the application and rendering; there is no Rust dependency or third-party runtime.

## Tests

```sh
./test.sh
```

This compiles and runs two independent executables in `build/tests` (or `$BUILD_DIR/tests`). `DocumentSupportTests` checks source protection, exports, vector/text/forms, scanned-image preservation, invalid destinations, password handling, history, natural folder order and snapshot cleanup. `ReaderViewTests` checks native layout, fit and manual zoom, rotation, scrolling, read-only forms/accessibility, and blocked print/action/context-menu paths. The reader checks need a normal macOS graphical login session, and briefly show a generated-document window for animation checks.

Tests create their own PDF fixtures. They do not use personal documents. They are functional checks, not a performance benchmark or a substitute for trying representative PDFs in the signed app.

## Privacy and source release

See [SECURITY.md](SECURITY.md) for local storage, file access and original-file safeguards. The app contains no telemetry, tracking, network entitlement or automatic updater. The source contains Nikhil Sharma's creator credit; publishing it does not require adding account or signing details.

Released under the [MIT licence](LICENSE). Copyright © 2026 Nikhil Sharma. The repository includes the intended app artwork and memorial photo; camera and editing metadata has been removed from the public photo without changing its decoded pixels.

## Large-file loading

The app uses an APFS copy-on-write snapshot when available, keeping the original separate without reading the entire PDF into RAM. Unsupported filesystems use a background copy with a 1 MiB buffer. PDFKit renders the file-backed snapshot on demand. An optional generated 200 MiB snapshot/isolation test can be run with `PDF_LARGE_SNAPSHOT_TEST=1 ./test.sh`.

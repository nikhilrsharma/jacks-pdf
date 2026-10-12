# Privacy and file safety

Jack's PDF is a local macOS app. It is created by Nikhil Sharma with OpenAI ChatGPT models. There is no analytics SDK, account service, tracking endpoint, automatic updater or network entitlement.

## Permissions and local storage

The signed app enables App Sandbox and the hardened runtime. Its entitlements allow user-selected files and persistent app-scoped bookmarks. File access comes from standard Open/Save dialogs and a folder picker for neighbouring PDFs. Full Disk Access, Contacts, Photos, camera and microphone permissions are not requested.

The app's local preferences contain at most ten recent file paths and any available security-scoped bookmarks, plus up to ten folder bookmarks. Stored bookmarks request read-only access. History metadata is retained even when a bookmark cannot be saved. Unavailable recent files can be located again through the standard macOS file picker or removed from history; failed or canceled opens do not discard the current PDF. Reopening a recent PDF never requires a new folder grant. **File → Open Recent → Clear History** removes the stored recent entries and folder bookmarks. A currently open document and its active access remain available until the document is closed. Passwords are retained only as needed in process memory and are not persisted in history.

A private temporary snapshot gives PDFKit a stable file to read, even if another application changes the original. Snapshot directories use owner-only permissions (0700); PDF files use 0600. Snapshots are removed when their document is released. The next snapshot creation removes abandoned snapshot folders left by a previous process, while file locks protect active snapshots. This is normal file deletion, not secure erasure. Temporary export files are cleaned up after success or failure.

## Viewing and saving

Normal mouse, keyboard, accessibility and embedded-action paths do not expose editable PDF form widgets, annotations or printing. Text selection/copy remains available when allowed by the document. PDF rendering and parsing are provided by macOS PDFKit; the app is not a separate PDF parser security boundary.

The source is opened for reading and is never used as an export destination. Before saving, the app checks the source's filesystem identity and change markers. It rejects the original path, resolved symbolic-link paths and hard links to the original. Other destination files must be regular files; directories and symbolic links cannot be replaced.

Exports start from the original private snapshot and apply only the requested page rotations. The finished PDF is reopened and checked before a coordinated replacement places it at the user-selected destination. Source and destination identities are checked again during this operation. The standard save dialog provides replacement confirmation for other existing files.

The exporter retains native PDF objects and disables image downsampling, conversion to JPEG and annotation burn-in. Automated fixtures verify native text/vector resources, existing form values/flags, source-byte preservation, and unchanged scanned-image dimensions and decoded pixels. PDFKit may reorganize PDF structure, compression or metadata; byte-for-byte output equivalence is not promised. Exporting signed or specialized PDFs has not been validated as preserving their signatures or specialized conformance.

Encrypted PDFs can be viewed after unlocking. Their rotated export is rejected rather than producing a copy with changed protection.

## Signing and public release

The local build uses ad-hoc signing (`codesign --sign -`) and does not access an Apple ID or embed a Developer ID certificate, team identifier or provisioning profile. The downloadable binary is ad-hoc signed and is not notarized by Apple. Creator attribution is limited to Nikhil Sharma's name.

The public repository uses the MIT licence and contains reviewed source, synthetic test code, documentation and intended artwork. Private documents, history/bookmarks, build logs, credentials and signing material are excluded. The public memorial photo retains its decoded pixels but has camera/editing metadata removed. The build script performs no publication or upload.

Security concerns can be investigated locally with a minimal synthetic PDF that reproduces the issue; do not include private documents or passwords in a public issue report.

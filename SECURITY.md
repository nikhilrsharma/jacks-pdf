# Privacy and file safety

Jack's PDF is a local macOS app. It is created by Nikhil Sharma with OpenAI ChatGPT models. There is no analytics SDK, account service, tracking endpoint, automatic updater or network entitlement.

## Permissions and local storage

The signed app enables App Sandbox and the hardened runtime. Its entitlements allow user-selected files and persistent app-scoped bookmarks. File access comes from standard Open/Save dialogs and a folder picker for neighbouring PDFs. Full Disk Access, Contacts, Photos, camera and microphone permissions are not requested.

Recent-file paths and available security-scoped bookmarks, plus up to 10,000 folder approvals, are stored in `Application Support/Jack's PDF/library.enc` within the private app container. AES-256-GCM encrypts and authenticates the whole file with a fresh nonce per save. Paths, filenames, permission data and usage order are inside the ciphertext. The directory uses mode 0700 and the file uses 0600; the file is excluded from normal backups where macOS honours that flag.

A random 256-bit key is held in the local login Keychain. Its access-control list initially trusts only the creating app; it is never relaxed to bypass update prompts. No cloud synchronization is requested. Ad-hoc signed updates can require explicit Keychain approval, and a locked keychain can also require user interaction. Missing keys, rejected access and invalid ciphertext are reported without overwriting the encrypted store or falling back to plaintext. Older `recentPDFs` and `readOnlyFolders` preferences are removed only after migration has been encrypted and read back successfully. If migration fails, the old data remains for recovery; it is not falsely reported as encrypted.

Keep at most ten recent PDFs, newest first, and 10,000 folder approvals, replacing the least recently used approval at the limit. Stored bookmarks request read-only access. History survives bookmark-creation failure. Reopening a recent PDF does not force a new folder grant; unavailable entries can be located again or removed. There is no time-based expiry. Only the current folder is actively accessed, not all 10,000 at once.

**File → Open Recent → Clear History** requires explicit confirmation with Cancel as the default. It removes saved recent entries and folder approvals and ends active folder navigation, while preserving the loaded document and its rotations. This forgets the app’s saved access; it does not revoke permissions held by other apps or delete PDFs. Passwords for encrypted PDFs stay only in process memory. Clearing and migration are ordinary deletion, not secure erasure of old disk blocks or backups. Encryption protects stored metadata at rest, not the visible app or a compromised process in an unlocked session.

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

# Jack's PDF Privacy Policy

Last updated: November 6, 2026

Jack's PDF is a local PDF reader for Mac, created by Nikhil Sharma. The app does not collect or transmit your PDFs, reading history or other personal information to the developer. It has no account system, advertising, analytics or tracking service.

## Documents and permissions

PDF reading, rotation and export take place on your Mac using Apple's system frameworks. The app uses the standard macOS Open and Save dialogs to access files you choose. Optional access to a containing folder enables the PDF count and keyboard navigation between files in that folder. Declining folder access still allows the selected PDF to be read.

The app does not request Full Disk Access, Contacts, Photos, camera or microphone permissions. It has no network entitlement and does not upload or synchronise documents. If you choose a file stored by a cloud or network provider, that provider and macOS may handle its availability separately from Jack's PDF.

## Information stored on your Mac

The app remembers the last 10 successfully opened PDFs and up to 10,000 folder approvals. These records include filenames, paths, saved permission references and their usage order. They are stored in the app's private container, encrypted and authenticated using AES-256-GCM. The random encryption key is stored in the local macOS login Keychain; the app does not request cloud synchronisation for that key.

This encryption protects the saved history and permission records. It does not encrypt your original PDFs or hide documents displayed on screen. If Keychain access fails or saved data cannot be decrypted, the app reports the problem and leaves the existing encrypted data unchanged.

The selected PDF order is also retained locally. The PDF-order preference contains only the chosen mode, not filenames, folder paths or document timestamps. Passwords used to open encrypted PDFs are kept only in memory and are not saved to history.

The app makes private temporary copies for stable PDF viewing and safe export. It removes released snapshots and failed export files, and cleans up abandoned snapshots on a later document load. Temporary files use owner-only filesystem permissions. This is ordinary cleanup, not a guarantee of secure erasure from disk or backups.

## Retention and your choices

History and folder approvals have no time-based expiry. Older recent files leave the list as new files are opened. At the folder-approval limit, the least recently used approval is replaced.

Choose **File > Open Recent > Clear History** to forget saved recent files and folder approvals. The app first asks for explicit confirmation. This clears the app's saved references and ends its active folder navigation; it does not delete PDFs or change access held by other apps. The history-encryption key and the non-sensitive PDF-order preference are retained. Clearing records is not secure erasure of old disk blocks or backups.

## External websites and support

Opening a support or privacy-policy link uses your browser. Visiting GitHub or another website is governed by that service's privacy policy and your browser settings. The app does not attach your PDFs, history or folder approvals to those links.

If you choose to submit a support report on GitHub, the information you post is handled by GitHub and may be public. Share only the details needed to describe the issue; do not include private PDFs, passwords, personal paths or other sensitive information. See [GitHub's privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

App Store purchases, downloads and system diagnostics are handled by Apple under Apple's policies and your system settings. Jack's PDF does not include its own payment processing or diagnostic-upload service.

## Questions and updates

Use the [Jack's PDF support page](Support.md) for help or privacy questions. Material changes to these practices will be reflected in this policy with an updated date.

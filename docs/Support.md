# Jack's PDF Support

Jack's PDF is a focused PDF reader for Apple-silicon Macs running macOS 14 or later. It opens one PDF at a time and supports continuous reading, folder navigation and saving rotated copies.

## Open and navigate

Choose **Open PDF** in the empty reader or **File > Open PDF**. You can also use Finder's **Open With > Jack's PDF**.

- **Up / Down:** scroll the document.
- **Left / Right:** open the previous or next PDF in an approved folder.
- **PDF x of y:** choose **Filename (A–Z)** or **Creation date & time**. In creation order, Left moves to newer PDFs and Right to older ones. Navigation stops at either end.
- **Click a page:** make it the active page for Fit and Rotate, including when several pages are visible at low zoom.
- **Jack's PDF > Shortcuts:** view every available keyboard shortcut.

Folder access is optional. The standard macOS folder picker grants access needed to count and open neighbouring PDFs. If you decline it, the selected PDF remains readable. Use **Browse folder** to approve access later. If the counter says **Folder unavailable**, its menu offers **Allow Folder Access**. If the current file was removed or replaced, reopen it before continuing folder navigation.

## Zoom and rotate

**Fit** adjusts the active page to the window width. The manual slider ranges from 20% to 200%; Fit can use a scale outside that range when needed. Zoom does not reflow PDF text.

**Rotate** turns the active page clockwise by 90 degrees. Its dropdown also offers **Rotate all pages**. To keep the result, choose **File > Save As** and select a different filename. The source PDF is protected. Replacing another existing destination requires the normal macOS confirmation.

Save a rotated copy before switching PDFs if you want to keep the rotation. A successful switch discards unsaved rotations without changing the original. Closing the app window or quitting with unsaved rotations offers Save As, Discard and Cancel.

## Recent files and privacy

**File > Open Recent** contains the last 10 successfully opened PDFs. If a file moved or access is no longer available, use **Locate File** in the recovery dialog. Cancelling or failing to open a file preserves the history entry.

History and up to 10,000 saved folder approvals are encrypted locally. **Clear History** asks for explicit confirmation before forgetting both history and folder access. It does not delete your PDFs. Read the [Privacy Policy](Privacy-Policy.md) for details.

## Keychain messages

At startup, the app reads its own history-encryption key from macOS Keychain. macOS may ask for approval or an unlock when access requires confirmation, including after a signing-identity change or when the login Keychain is locked. Handle the system prompt directly on your Mac and restart the app if instructed. Do not share your password in a support report.

If the key is missing or saved history cannot be verified, the app leaves existing saved data unchanged. Report the displayed error before removing app data or Keychain entries; deleting the encryption key can make saved history unreadable.

## Supported scope

Jack's PDF supports reading and page rotation. It has no printing, form filling, annotation editing, text editing, text search or OCR. Embedded PDF links and actions are inactive. Text selection and copying depend on the PDF's permissions.

Password-protected PDFs can be read after entering their password. Saving rotated copies of encrypted PDFs is currently unavailable. Export preserves native PDF content without rasterizing pages or downsampling images, but preservation of digital signatures and specialised PDF conformance is not guaranteed.

To change your default PDF app, select a PDF in Finder, open **Get Info**, choose Jack's PDF under **Open with**, then use **Change All**. Finder's thumbnail preferences are separate; choosing Jack's PDF does not change them.

## Report a problem or ask a question

Use the [public GitHub issue tracker](https://github.com/nikhilrsharma/jacks-pdf/issues). Include:

- Your macOS version and app version from About.
- The steps that lead to the problem and what you expected.
- The exact error text, with personal details removed.
- A small, non-private sample PDF, only if it is needed to reproduce the issue.

GitHub issues are public. Do not upload confidential documents, passwords, personal file paths, addresses or account details. Review screenshots before attaching them. The developer does not receive app documents or history automatically.

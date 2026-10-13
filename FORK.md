# OPDS version-check fork

Based on AndyHazz/bookshelf.koplugin v5.4.3. Fork version: 5.4.3-opds.4.

Tapping a downloaded OPDS book checks its acquisition on the server. Matching
copies open directly. Different copies offer **Update** or **Open local copy**.
Offline, failed, cancelled, redirected, or ambiguous-format checks open the local
copy without an update prompt. Books without a download keep the format picker.
The detail dialog's Open button and existing-file download action use the same
check. Local-library books are unaffected.

The first check streams the server file and compares its content with the existing
file, without replacing it. This can transfer the full book once. PDF comparison
ignores only the regenerated XMP MetadataDate. EPUB comparison ignores ZIP container
timestamps/compression and compares decompressed members (32 MiB maximum per member;
unsupported comparisons open locally without prompting). An EPUB check uses a
scratch archive that is removed afterwards. A matching
strong HTTP ETag is then saved with the URL and local file size/timestamps, allowing
later checks to use HEAD only. For Calibre-Web/CWA acquisition URLs and UUIDs, the
authenticated metadata endpoint provides a stable format modification time and size.
After a successful content comparison, that revision allows a small metadata request
to replace repeated acquisitions, even when CWA regenerates export ETags. Library
updates must go through Calibre/CWA so its modification timestamp remains accurate.
Changed or missing validators trigger another content
comparison; metadata-only changes do not prompt if the content still matches.
Servers without stable revisions or strong ETags require a full comparison on each open. Servers must
honor their HTTP validators; this is not a background sync or a shelf refresh.

Checks run in a cancellable subprocess and reuse the catalog's authentication and
KOReader proxy. Credentials are gated to the catalog origin; version checks do not
follow redirects. No credentials are stored in the version cache. Cancelled
updates and failed atomic replacements preserve the original book.

The updater targets this fork so an upstream update does not silently remove the
change. Install future builds from this fork's releases or its
`opds-version-check` developer branch. The original plugin directory/name is kept
for compatibility with existing settings and download mappings.

Restart KOReader after installation. To revert, restore the backed-up plugin
directory and restart; the extra `opds_verified_versions` setting is harmless to
upstream. Do not delete books or their `.sdr` directories when reverting.

Validation: `LUA=luajit sh tests/run.sh`. The version suites cover exact matching,
same-size differences, changed/weak/missing ETags, local edits, network/auth errors,
redirects, truncated responses, acquisition ambiguity, UI prompts and cancellation.

## Automatically open downloads

Under **Bookshelf → Settings → Behavior**, enable **Open OPDS downloads
automatically** to skip the “Read it now?” prompt after a successful download.
This applies to articles/books and accepted updates. It is off by default; turning
it off restores the prompt. The persisted boolean flag is
`opds_auto_open_downloads` in Bookshelf's settings store. Failed or cancelled
downloads never open a book, and a closed/replaced shelf cannot launch the reader.
The downloaded marker refreshes before opening, and queued input is suppressed.

## Resolve single-item folders before display

A shelf waits for uncertain single-item folders to resolve before publishing its
book tiles. A folder such as News containing one article therefore appears as that
article on the first content render; it does not flash as a folder first. Cached
children resolve without a network request. Folders known to contain several items
remain folders, and partially fetched child feeds are never mistaken for one book.

On an uncached page, a cancellable loading state covers the lookup. Resolution runs
in a subprocess with short request timeouts and a bounded batch. Results are stored
together before the page is released; covers load afterwards. Offline, failed or
cancelled lookups release normal folder navigation, and passive repaints do not
retry them. Deliberate navigation or refresh permits another attempt. This replaces
the folder-preserving behavior of opds.3.

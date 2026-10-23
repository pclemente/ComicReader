# Web browsing and comic downloads

Version 1.6 adds a globe button in the library and Command-Shift-B on Mac.
The browser opens inside the adaptive navigation controller, preserving the
existing iPhone, iPad, Mac and iPhone Duo safe-area behavior.

## Free browsing and the Plus workflow

Browsing, saved websites, website session retention and private browsing are
free. The existing non-consumable Plus purchase adds the app's supported-file
download, validation, duplicate detection and collection import workflow.
It is one purchase for iPhone, iPad and Mac, with a €9.99 base price in Spain;
the App Store supplies the customer's local price. Existing Plus owners receive
the website import tools without another purchase. Files imports, direct Finder
reading on Mac, local transfers, reading and iCloud synchronization remain free.

Open the library's globe button to browse. **More** contains saved-site and
website-data controls, private browsing and **Import Current Comic** for a PDF
already displayed in the browser. **Get Plus** in the library explains the
upgrade; purchase and restore remain available on the same screen. The release
announcement is dismissible, and free browsing does not require an upgrade.

Use a website that provides downloadable PDF, CBZ/ZIP or classic CBR/RAR
files. On a supported download, choose Library Root or a collection. The
Downloads screen reports progress and supports cancellation. A failed or
cancelled transfer can be resumed when WebKit supplies resumable data;
otherwise start the download again from its website. Open Comic is available
after import, including if Plus is later refunded or revoked.

The normal download queue lives in memory across browser dismissal. It is
not an across-launch download service and does not promise background
completion when the operating system suspends or terminates the app. Private
transfers are cancelled when their private session ends. An imported comic
is a normal library file; ending a private session does not delete it.

## Website sessions and privacy

WebKit's default data store retains normal cookies and website storage. The
app does not copy passwords or cookies into a separate downloader. Private
browsing uses a nonpersistent WebKit data store. Website data can be cleared
for a selected site or for the entire normal browser, independently of saved
website shortcuts. A website can keep a reader signed in through its cookies
and storage, subject to that website's own expiry and security rules. ComicReader
does not store a separate password vault or promise that every sign-in flow works
inside the browser.

Saved shortcuts are local. Query strings and fragments are stripped before
persistence; automatic last-website storage keeps only the origin. There is
no browsing-history log or analytics SDK. Website operators independently
receive requests when the user visits their sites, under their own policies.
Private browser state and download resume data are never intentionally
persisted by ComicReader. Comic imports follow the user's existing free
iCloud sync preference.

## File integrity and security boundaries

`WKDownload` retains the website's authentication context. The importer uses
hidden staging, checks file signatures and readable comic pages, hashes file
contents, and moves a completed file atomically into the library. Identical
contents reuse an existing comic. Different contents sharing a name receive
a unique filename; existing comics are never overwritten. Collection names
are confined to one visible library directory and symlinks are rejected.

Validation and hashing run off the main thread. Purchase state and
cancellation are checked again before import. No URL credentials, server
tokens or source URLs are saved in the download history. HTTPS is the default;
the only transport exception enables local networking for personal servers.
Certificate failures are not bypassed.

Automatic archive validation decodes a first-page thumbnail and limits that
page's uncompressed extraction to 96 MiB, checking both archive metadata and
bytes produced. Failed extraction removes partial temporary output. Existing
reader imports keep their previous behavior. This check establishes that the
first page is readable; it does not inspect every page in an archive.

Some sites require an external browser for sign-in, and protected readers
may not provide downloadable files. The browser provides Open in Safari for
such sites, but cannot transfer a Safari login back into WebKit. Unsupported,
encrypted, corrupt or empty comic archives can be rejected. No DRM removal,
comic catalogue or bundled content is provided.

## App Store review requests

After meaningful reading use, ComicReader may ask Apple’s native StoreKit UI
to request a review. It does not show a sentiment dialog or require a Plus
purchase. Eligibility requires at least three reading sessions of 60 seconds
or more on three distinct days and 10 total minutes of foreground reading.
Requests are limited to one attempt per app version, with at least 90 days
between attempts and no more than three attempts in any 365-day period.
StoreKit decides whether an attempted request is shown.

Eligibility and request history are stored only on the device. Reading time
uses `systemUptime` and accumulates only during foreground reader segments, so
background time is excluded. The privacy manifest declares System Boot Time
reason `35F9.1` for this elapsed-time measurement. ComicReader does not send
this state or use it for analytics.

## Release preparation

The next App Store submission must describe the browser and download workflow
in review notes and accurately answer the unrestricted-web-access age-rating
question. Duo remains the marketing headline. The existing one-time Plus
product is retained. No third-party analytics project, SDK or credentials are
needed for this release. The draft 1.6 metadata does not change the live 1.5
listing or its screenshots.

## Validation

`CRWebImportTests` covers validation, staging, duplicates, collisions,
cancellation and collection confinement. `CRBrowserSiteStoreTests` covers
URL validation, credential/query removal, local persistence and private
storage. `CRWebBrowserUITests` uses a loopback publisher fixture and a real
HttpOnly WebKit cookie, redirects and StoreKit Test to exercise the user
workflow. Execution results are recorded with the 1.6 candidate validation.
The native Mac browser journey remains incomplete; see the exact failures and
isolated diagnostic workflow in [Mac browser validation](MacBrowserValidation.md).

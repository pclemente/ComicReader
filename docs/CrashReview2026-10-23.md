# Production crash review — 23 October 2026

This review correlates App Store Connect crash counts, Xcode Organizer crash
groups, archived symbols, release history, and the current source. It does not
contain private crash-report identifiers.

## Result

One production defect is confirmed: the old **Add Files** action indexed an
empty `NSDataDetector` result and raised `NSRangeException`. The defect exists
in versions 1.0.1 and 1.1 and is already removed from the current app. Commit
`1fd4356` replaced that path with `UIDocumentPickerViewController`; versions
1.4 and later contain the fix. No additional production-code change is
justified by the available crash evidence.

A much larger family of UIKit assertion groups is strongly correlated with
version 1.1's incomplete incoming-document URL configuration. Version 1.1
advertised PDF, CBR, and CBZ document types but had neither document roles nor
an incoming URL handler. Commit `1fd4356` added both. Organizer does not expose
the assertion description, so this remains a strong source correlation rather
than a confirmed root cause.

## Evidence sources and limits

- App Store Connect crash totals cover 24 July through 21 October 2026.
- Xcode Organizer was refreshed for ComicReader. Its range menu offers **Last
  Day**, **Last Two Weeks**, and **Last Year**; it does not offer Last 90 Days.
  The broader Organizer review therefore used Last Year.
- No ComicFlow `.ips`, `.crash`, or `.xccrashpoint` file was present in macOS
  DiagnosticReports, MobileDevice crash logs, or the local Xcode product cache.
  The absence of local files is not evidence of zero crashes.
- Organizer device counts identify devices within a group. They are not crash
  counts, and counts from different groups must not be added as unique users.
- Sampled reports are capped by Organizer; five visible reports do not mean a
  group occurred only five times.

The App Store Connect totals are:

| iOS version | Crashes |
| --- | ---: |
| 1.1 | 225 |
| 1.0.1 | 8 |
| 1.0, 1.2, 1.3, 1.4, 1.4.1, 1.5 | — |

The dashes are App Store Connect's displayed value and are not treated as a
proved zero.

Organizer listed two groups in Last Two Weeks and 36 groups in Last Year. The
largest Last Year groups were:

| Organizer signature | Devices |
| --- | ---: |
| `UIApplication _applicationOpenURLAction... + 1364` | 104 |
| `LibraryViewController(IBActions) purchase: + 108` | 90 |
| `LibraryViewController(IBActions) purchase: + 148` | 81 |
| `UIApplication _applicationOpenURLAction... + 1444` | 62 |
| `UIApplication _applicationOpenURLAction... + 1348` | 20 |

## Confirmed Add Files crash

Both purchase-named groups have this exception path:

```text
CFThrowFormattedException
-[__NSArrayM objectAtIndex:]
-[LibraryViewController(IBActions) purchase:]
```

The method name is historical and misleading: the Settings XIB wired the
**Add Files** button to `purchase:`. The old implementation detected links in
`_addressLabel.text` and unconditionally evaluated:

```objc
NSRange addressMatchRange = [[matches objectAtIndex:0] range];
```

When the web server was off or startup had not produced an address, the label
contained no link, `matches` was empty, and index zero raised the reported
exception.

The two binary mappings are:

- Version 1.0.1, commit `d831ad04`, offset `+148`,
  `Classes/LibraryViewController.m:943`.
- Version 1.1, commit `7f8fb910`, offset `+108`,
  `Classes/LibraryViewController.m:1324`.

The different offsets reflect the two binaries; the `objectAtIndex:` frame and
the sole compiled indexing expression make the source attribution
unambiguous. In the Last Two Weeks group, four sampled version 1.1 reports were
from an iPad Pro 12.9-inch (2nd generation) on iOS 17.7.11 and one was from an
iPad (5th generation) on iOS 16.7.16.

Commit `1fd4356` replaced the address parsing and Safari presentation with the
system document picker. The current implementation is in
`Classes/LibraryViewController.m` under
`-[LibraryViewController(IBActions) purchase:]`; selected URLs go through
`-[AppDelegate importComicAtURL:]`. The UI test
`testSettingsAndFilesPickerWithServerOff` explicitly opens and cancels the
picker with the server disabled. No further fix is needed for this crash.

### Reproduction on the affected builds

1. Run version 1.0.1 or 1.1 with the transfer server off, or before a server
   address has populated the settings label.
2. Open Settings and select **Add Files**.
3. `NSDataDetector` returns no link match and the app raises an out-of-bounds
   exception at `matches[0]`.

The current app should present the Files picker instead.

## Incoming-document UIKit assertion family

Nine Last Year groups use the symbol
`-[UIApplication _applicationOpenURLAction:payload:origin:]` with offsets
`+852`, `+1168`, `+1240`, `+1344`, `+1348`, `+1364`, `+1368`, `+1380`, and
`+1444`. The largest three of these account for 104, 62, and 20 devices.
Several address-only UIKit groups have the same assertion-shaped stack on
other iOS versions.

A symbolicated version 1.1 sample shows:

```text
objc_exception_throw
-[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:]
__58-[UIApplication _applicationOpenURLAction:payload:origin:]_block_invoke
-[UIApplication _applicationOpenURLAction:payload:origin:]
-[UIApplication _callInitializationDelegatesWithActions:forCanvas:payload:fromOriginatingProcess:]
```

The initialization-delegate frame points to a cold-launch incoming URL action.
The second Last Two Weeks group, `UIKitCore + 9200828`, has the same general
CoreFoundation/Foundation/UIKitCore assertion shape, version 1.1, and five
sampled reports from an iPad mini 2 on iOS 12.5.8. Its Last Year group lists 13
devices.

The version 1.1 configuration advertised PDF, CBR, and CBZ under
`CFBundleDocumentTypes` and set `LSSupportsOpeningDocumentsInPlace`, but each
document declaration omitted `CFBundleTypeRole`. The app also implemented no
`application:openURL:` or scene URL-context callback. Commit `1fd4356` added
`CFBundleTypeRole = Viewer` for all three types and introduced a scene
lifecycle. The current `ComicSceneDelegate` handles both cold-launch
`connectionOptions.URLContexts` and later `scene:openURLContexts:`, then sends
validated file URLs to `importComicAtURL:`.

That before-and-after path is a strong match, but Organizer did not provide
UIKit's assertion description. It is therefore not enough to state that the
missing role or callback caused every group. Version 1.1's only direct outbound
`UIApplication openURL` call is the fixed App Store rating URL; it does not fit
the initialization-delegate stack as well as incoming document launch.

Current unit coverage validates accepted and rejected import URLs, duplicate
names, file-reference URLs, Inbox handling, and unsupported schemes. Several
UI tests launch fixture URLs through XCTest. If this family appears in version
1.5 or later, the next useful evidence is the raw assertion description plus a
cold- and warm-launch Files test for PDF, CBZ, and CBR. A speculative code
change without that evidence is not warranted.

## Other historical groups

The remaining groups do not establish a current app defect:

- `_UISceneSettingsDiffActionPerformChangesWithTransitionContext + 16` lists
  five devices. All five inspected samples are version 1.1 on iOS 26.6 or
  26.6.1 and contain only system scene-transition frames plus `main`. The app
  moved to an explicit scene lifecycle in version 1.4, but the available stack
  does not identify a source-level cause.
- `CGDataProviderCopyData + 240` is a single version 1.0.1 report. Its stack
  reaches `CreateRenderedPDFPage` and `LibraryUpdater` while generating a PDF
  cover. `CGDataProviderCopyData + 376` has four version 1.0.1 reports from one
  iPad on iOS 13.6, without a visible app frame in the samples. There is no
  current-version recurrence to guide a safe PDF change.
- The single-device QuartzCore allocation group is version 1.0.1 and exposes
  no app frame. The single-device libdispatch group contains three version
  1.0.1 reports on iOS 13.6 and terminates on a worker thread without an app
  frame.
- The version 1.5 zero-dimension guard in `ZoomView.layoutSubviews` prevents
  invalid zoom calculations, and thumbnail layer updates now return to the
  main thread. Both are sensible defensive changes, but no downloaded
  production stack ties either change to one of these groups.
- Documented UI-test assertions, simulator stalls, install failures, and
  result-bundle finalization failures are tooling evidence, not production app
  crashes.

## Fix decision

No production source was changed during this crash review. The confirmed Add
Files crash and the most plausible incoming-document launch problem are both
covered by the document-picker, document-role, scene URL, and import work first
released in 1.4 and retained in 1.5. The useful follow-up is to monitor crash
groups by app version after 1.5 adoption and investigate only a group that
contains a 1.4/1.5 binary or a new app frame.

<p align="center">
<img src="https://github.com/pclemente/ComicReader/blob/main/Resources/Assets.xcassets/AppIcon.appiconset/167.png">
</p>

Overview
========

**ComicReader is a comic reader for iPhone, iPad and Mac, designed for comic fans with large collections.**

ComicReader is an open-source continuation of ComicFlow, one of the first open-source comic readers for iPad. The entire source code and graphic assets are available for anyone to inspect or contribute to. The original project is hosted at https://github.com/swisspol/ComicFlow and is now read-only, so this project brings it to modern Apple devices and current versions of Xcode. Reading and all existing import and transfer features remain free, and contributions are welcome.

See [ComicReader on the App Store](https://apps.apple.com/app/id1597314495).

Optional iCloud synchronization of your own comics, read
status and current page is free for everyone across iPhone, iPad and Mac. Sync starts off, requires explicit
consent and uses your personal iCloud storage. Text from the current page can
also be recognised, selected, copied and shared for free.

**ComicReader Plus** remains a one-time purchase for app-specific features:
current-comic Search & Quotes, custom Reading Lists with automatic Smart Queues, named Page Bookmarks and
renderer-only Image Filters. Search builds a persistent local page index for the
comic being read; saved quotes can be edited, shared and opened at their source
page. Search indexes, quotes, lists and bookmarks stay on this device. Search does
not cover the whole library, and text recognition may be incomplete. Image
Filters include Clear Ink, Grayscale and Warm Paper, never modify comic files,
and always allow returning to Original rendering.
Smart Queues group Continue Reading, Unread and Read Again from the current library state; they are not separate stored lists. Plus includes a free visual preview of its image filters.
Restore Purchases is included; there is no subscription or bundled comic
content. See [Plus setup and release validation](docs/PlusUpgrade.md) and the
[monetization decision](docs/MonetizationReview.md).

Building and testing
====================

Open `ComicFlow.xcodeproj` in Xcode 27 and select the shared `ComicFlow` scheme. ComicReader supports iPhone and iPad on iOS/iPadOS 15 or later, plus Mac Catalyst on macOS 12 or later. Run Product → Test on an iPad simulator for the regression suite.

See [the regression and compatibility review](docs/RegressionReview.md) for restored behavior, build commands, and validation details.

License
=======

ComicFlow is copyright 2010-2014 Pierre-Olivier Latour and available under [GPL v3 license](http://www.gnu.org/licenses/gpl-3.0.txt). See the [LICENSE](LICENSE) file in the project for more information. It was later modified to mantain it by me https://pabloclementeperez.com/ and released under the same license.

**IMPORTANT:** ComicFlow includes some other open-source projects and such projects remain under their own license.

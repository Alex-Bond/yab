---
name: image-search
description: Find images, thumbnails and original source pages using Google Images in Yab.
sites: []
keywords: [image search, google images, find images, photo search, thumbnail, поиск картинок, найди картинки, найди изображения]
---

# Image search

Search in a task tab using `https://www.google.com/search?udm=2&q=` plus the encoded query.
Use the user's language and requested subject; optional `safe=active` enables SafeSearch.
Read `google-search` for navigation, consent and unusual-traffic handling.

Read result titles and source links with snapshot/text. Screenshot when the visual content matters.
Open promising results to inspect the image and its source page. Record only metadata actually
exposed there: title, source page URL, original image URL, thumbnail URL and width/height.
Use `eval` to read visible image/link attributes when refs do not expose those values; do not
invent original URLs or infer original dimensions from a displayed thumbnail. Some results load
only after scrolling or selecting the thumbnail.

Show a small relevant selection with links to the source pages. Label a thumbnail as a thumbnail;
prefer the original URL when the user needs an asset. Verify any requested reuse license on the
source page: a Google filter or a licensable label is only a hint. Download only files needed by
the user's task, using Yab's download flow, and preserve attribution where supplied.

Yab has no `imageSearch` global. Use the existing browser tools; a captcha is the user's:
`handoff` at once, never try to solve it.

# Public menu OCR proof

A small test of Apple's built-in Vision text reader. This is a macOS command-line benchmark, not an iPhone app. It needs no Apple account, signing, API key or paid runner.

The manual GitHub Actions job uses a standard macOS 15 runner and refuses to run unless the repository is public. Standard runners are [free for public repositories](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). It runs only when manually requested. It prints at most 2 MB of JSON into ordinary workflow logs, which [do not count against artifact storage](https://docs.github.com/en/billing/concepts/product-billing/github-actions). No artifacts or caches are uploaded. Public logs normally remain for 90 days. An account refusal must stop the run, never enable billing.

The runner downloads three original public menu PDFs from the URLs in `sources.json`, checks their frozen SHA256 hashes, renders the entire first page at the listed 1300-pixel-long-edge size, and recognizes the image. It never reads embedded PDF text. No local menu files, camera recordings, annotations, account details or signing material belong in this repository.

`VisionMenu.swift` first checks an asymmetric generated PDF, 2x enlargement, OCR coordinates, PDF rotation and lossless JSON text formatting. Every real page uses accurate Vision revision 3 and minimum text height 0. The current controlled baseline leaves the SDK's language selection, automatic detection and correction defaults untouched, and records their actual getters before recognition. All three menus use the same policy. No remembered default values or per-menu hints are inserted.

The earlier custom five-language/correction-off profile is retained at commit `3a827eaa0aa6f9dbb709b630aa739c517fe0fb50`, with its complete failed results kept locally. Apple's guide restricts mixing Chinese with languages other than English. This next baseline tests the standard language policy; it does not assume that policy caused the earlier orientation failure. No source document, annotation, price filter or confidence floor is changed by this comparison.

All raw first-choice lines, native confidences and approximate word boxes are returned. There is no price classification or custom digit/separator repair in this benchmark; the standard Apple correction setting is recorded explicitly. A separate fresh request captures the language defaults before any PDF download, and every page must match that snapshot during local analysis. A failed download, changed PDF or unavailable default language stops the job.

The runtime diagnostic found the default `en_US` and supported `en-US`. The compatibility guard compares canonical language identifiers, with a self-check for that equivalent spelling and refusal of other unsupported languages. Raw getters and actual request settings remain untouched; this repairs validation, not recognized text or amounts.

The JSON goes back to the local existing price filter and frozen by-eye truth: 109 prices and 27 eligible generic values. Keep every miss and wrong value. Values never choose their matching physical location. The PDFs are the same source content as the web tests; Quartz rendering differs from Poppler, so this is not an identical-pixel engine comparison. Word boxes can cover an entire word, and confidence is not a correctness probability. Rendering alignment must be checked before scoring; no threshold is fitted to the answers.

Local Mac check: compile the Swift file with the command in `.github/workflows/vision.yml`, then run `vision-menu --self-test` and `vision-menu sources.json`. Windows cannot execute Apple's frameworks. The prior profile compiled, passed its strengthened self-checks and returned complete JSON on macOS 15; this changed language-policy baseline awaits its own Mac execution and scoring. No iPhone result is implied.

A good result would justify a separate native iPhone scanner proof. It would not establish live camera accuracy, overlay stability, phone speed or free sideload compatibility. No app or current website is deployed by this workflow.

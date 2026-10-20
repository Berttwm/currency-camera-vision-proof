# Public menu OCR proof

A small test of Apple's built-in Vision text reader. This is a macOS command-line benchmark, not an iPhone app. It needs no Apple account, signing, API key or paid runner.

The manual GitHub Actions job uses a standard macOS 15 runner and refuses to run unless the repository is public. Standard runners are [free for public repositories](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). It runs only when manually requested. It prints at most 2 MB of JSON into ordinary workflow logs, which [do not count against artifact storage](https://docs.github.com/en/billing/concepts/product-billing/github-actions). No artifacts or caches are uploaded. Public logs normally remain for 90 days. An account refusal must stop the run, never enable billing.

The runner downloads three original public menu PDFs from the URLs in `sources.json`, checks their frozen SHA256 hashes, renders the entire first page at the listed 1300-pixel-long-edge size, and recognizes the image. It never reads embedded PDF text. No local menu files, camera recordings, annotations, account details or signing material belong in this repository.

`VisionMenu.swift` first checks an asymmetric generated PDF, OCR coordinate conversion and PDF rotation. Every real page uses the same accurate Vision revision 3 configuration, automatic language detection and no language correction. All raw first-choice lines, native confidences and approximate word boxes are returned. There is no price classification or number repair in this benchmark. A failed download, changed PDF or unsupported configured language stops the job.

The JSON goes back to the local existing price filter and frozen by-eye truth: 109 prices and 27 eligible generic values. Keep every miss and wrong value. Values never choose their matching physical location. The PDFs are the same source content as the web tests; Quartz rendering differs from Poppler, so this is not an identical-pixel engine comparison. Word boxes can cover an entire word, and confidence is not a correctness probability. Rendering alignment must be checked before scoring; no threshold is fitted to the answers.

Local Mac check: compile the Swift file with the command in `.github/workflows/vision.yml`, then run `vision-menu --self-test` and `vision-menu sources.json`. Windows cannot execute Apple's frameworks. Compilation and runtime remain unverified until the first approved Mac run.

A good result would justify a separate native iPhone scanner proof. It would not establish live camera accuracy, overlay stability, phone speed or free sideload compatibility. No app or current website is deployed by this workflow.

# Corpus Pilot v1 Fixture

This fixture is the canonical pilot contract baseline for corpus-scale VI evidence processing in `comparevi-history`.

Source:

- upstream consumer proof run `23206547436`
- repository: `LabVIEW-Community-CI-CD/labview-icon-editor-demo`
- ref: `develop`

Seed targets frozen by this baseline:

- `Tooling/deployment/VIP_Post-Install Custom Action.vi`
- `Tooling/deployment/VIP_Pre-Install Custom Action.vi`

Frozen contract expectations:

- one `comparevi-history/downstream-processing-manifest@v1`
- one `comparevi-history/corpus-page@v1` page with deterministic `page-ordinal` continuation
- one `comparevi-history/corpus-index@v1` summary aligned to that page
- stable target ordering, target ordinals, and page partitioning for page size `2`
- stable per-target path/status fields needed by the downstream processor
- no downstream requirement to scrape markdown or HTML surfaces for deterministic processing

The golden contract test reads only the JSON receipts under `corpus/` and fails closed if the baseline drifts.

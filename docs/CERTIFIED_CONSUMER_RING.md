# Certified Consumer Ring

`comparevi-history` is operated as a certified downstream platform, not only as a reusable workflow repository.

The machine-readable source of truth for the current ring is
[`tools/policy/consumer-certification-ring.json`](../tools/policy/consumer-certification-ring.json).

## Support Tiers

- `certified`
  - Required for recurring platform certification.
  - Must pass both the `v1` moving-tag lane and the latest immutable-tag lane.
  - Failure is a platform blocker.
- `proving`
  - Runs on the same certification surface but is advisory.
  - Used for admission, template evolution, and downstream drift discovery.
  - Failure does not block the platform baseline by itself.
- `experimental`
  - Not currently part of the standing ring.
  - May use the platform, but is outside the recurring certification contract.

## Current Ring

- `ni/labview-icon-editor`
  - Tier: `certified`
  - Scope: `required`
  - Role: canonical external consumer for release and published-facade proof
- `LabVIEW-Community-CI-CD/labview-icon-editor-demo`
  - Tier: `proving`
  - Scope: `advisory`
  - Role: org-owned admission and proving surface

## Operating Model

- `published-consumer-validation.yml` is the reusable/manual primitive for one consumer.
- `consumer-certification-ring.yml` is the scheduled/platform supervisor for the full ring.
- A platform change is complete when:
  - `main` remains green
  - the certified consumer ring passes on the current baseline
  - the next immutable release is validated against the certified consumer(s)

## Evidence

- The current certified branch-tip run is tracked in
  [`tools/policy/consumer-certification-ring.json`](../tools/policy/consumer-certification-ring.json).
- Ring runs upload:
  - per-consumer certification ledger receipts
  - one aggregated certification-ring ledger for the whole run

# idle-finder

A scheduled, **read-only** Lambda that reports resources which commonly accrue
cost while sitting idle, so a human can review and reclaim them.

## What it scans

| Category | Idle signal |
|----------|-------------|
| EBS volumes | Volume in the `available` state (not attached to any instance) |
| Elastic IPs | Address with no `AssociationId` (allocated but unused) |
| EBS snapshots | Self-owned snapshot older than the configured age; optionally only those whose source volume no longer exists |

Each finding carries an approximate monthly cost derived from the resource size
and a documented blended rate, so the report can be prioritised. The figures are
for triage, not billing reconciliation.

## Safety model

The function only issues `describe`/`get` calls. It never detaches, deletes, or
otherwise mutates a resource — it emits a report and a summary. Deletion stays a
deliberate human action.

Any resource carrying one of the configured **exclusion tag keys** (default
`finops:keep`) is omitted from the report, so intentionally-retained resources
are never listed.

## Output

A JSON report is written to the report bucket under a date-partitioned key
(`idle-resources/year=/month=/day=/…json`) and a short summary is published to
the shared cost-alert SNS topic.

## Configuration

Behaviour is driven entirely by environment variables — see the module
docstring in `handler.py` for the full list (report location, snapshot age,
orphaned-only mode, exclusion tag keys, and per-category price overrides).

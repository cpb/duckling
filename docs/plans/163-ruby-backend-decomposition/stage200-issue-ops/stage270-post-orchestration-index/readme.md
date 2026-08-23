# stage270 — post the orchestration index

Renders the index comment on the parent issue: pick order, gates, the two
findings the original plan lacked, the ownership rule, and the full slice table
with both issue numbers per slice.

Run it last — the table needs every number in the ledger.

## Comment idempotency

GitHub has no comment upsert, so the body carries an HTML marker
(`<!-- duckling-plan:orchestration-index -->`). The stage looks for that marker
among existing comments and PATCHes in place if found, appends if not.
Rerunning after any issue is added or renumbered refreshes the table rather
than stacking a second copy.

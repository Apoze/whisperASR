# E20 worker evidence

Ticket: #71. Base: `9768f968d0cc042f884f499951a06b4415c9f2b1`.

- `final-light-tests.log`: raw output for the 73 ticket-adjacent XCTest cases;
  67 passed and 6 opt-in tests skipped.
- `final-full-tests.log`: raw unfiltered XCTest output; 386 tests ran with
  48 opt-in skips and the two known E13 assertion failures below.
- `provenance.json`: exact commands and frozen development input identity.
- `worker-smoke.json`: raw authorized eight-cue DEV smoke evidence. The worker exited 0
  after 27.433 s, peaked at 10,663,466,936 physical-footprint bytes, observed no
  memory-pressure transition, and added no swap.
- `worker-runtime/worker.log`: raw worker stdout/stderr (empty; SHA-256 is recorded
  in `provenance.json`). Process 31191 was confirmed absent after the run.

The final unfiltered suite executes 386 tests with 48 opt-in skips and two pre-existing
E13 failures. Both compare stale `contextBytes` values written before
`conversationContextByCueID` added 32 encoded bytes: development `94120/94152`,
holdout `86610/86642`. No #71 file touches E13 or the glossary selector.

No holdout input is opened by this experiment.

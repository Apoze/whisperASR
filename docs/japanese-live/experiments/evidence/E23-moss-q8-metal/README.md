# E23 MOSS q8 / Metal evidence

- `final/`: final evidence bundle, raw transcripts, raw stderr and the retained
  validator-only false negative.
- `residency-default-failure/`: complete raw outputs plus the exit-6 Metal
  residency teardown backtraces.
- `cache-provenance.tsv`: all 20 SwiftPM checkout revisions used by the runner.
- `source-tree.json`: source/config snapshot taken before the run.
- `preflight.json` and `light-tests.log`: fail-closed preflight evidence.
- `full-swift-test.log`: final 424-test local suite.
- `artifact-hashes.tsv`: SHA-256 inventory of this directory, excluding itself.

The audio excerpts, 941 MiB model, local CMake archive and compiled runner remain
ignored under `.build/`; their exact hashes and provenance are recorded in the
JSON evidence.

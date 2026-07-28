# View-snapshot goldens

Committed golden PNGs for the View-snapshot gate (`ViewSnapshotTests`).

**These are generated on CI, not locally.** Font hinting, antialiasing, and
default-font resolution differ between a dev Mac and the `macos-26` runner, so a
golden recorded locally would spuriously fail verification on CI. The loop:

1. Land the infra + a test that names a golden (the test passes locally by
   recording an `Issue` when the golden is absent — it can't fabricate one).
2. Run the **snapshot-record** workflow on CI (`SNAPSHOT_RECORD=1`), which
   renders each View and writes its `.png` here.
3. Commit the artifact that workflow produces.
4. From then on the verify job compares each render against the committed
   golden with a small per-pixel tolerance.

To re-record after an intentional visual change, re-run the record workflow and
commit the updated PNGs. See `Tests/PortalTests/Support/ViewSnapshot.swift`.

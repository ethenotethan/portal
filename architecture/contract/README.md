# The `hermes.architecture` contract

`architecture_contract.py` is the contract between an architecture compiler, the
Harness gateway (`architecture.describe`) and every renderer of the document.
It is **vendored byte-for-byte** from Harness (`tui_gateway/architecture_contract.py`)
and pinned by digest in `pins.json`; `architecture-document-v1.schema.json` is
its JSON Schema export. A change to the contract lands in both repositories in
lock-step: bump the pin here in the same PR that vendors the new copy.

Required sections: `components`, `interplay`, `extraction`, `ci`, `inventory`,
`evidence_metadata`. Optional: `stores`, `externals`, `layers`, `edges`, `behavior`.

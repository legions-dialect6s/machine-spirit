# MachineSpiritKit

The UI-free core of MachineSpirit.app: the Node model (group+action duality
native), the lossless Leader Key importer/serializer with its canonical
round-trip gate, derived inertness via injectable probes, the radial and
tidy-tree layouts, and the `GraphViewState` sidecar type.

**The gate:** `swift test` — headless, must be green on every commit.

**Losslessness boundary:** duplicate keys inside a single JSON object are not
representable through the JSONDecoder/dictionary path (the decoder silently
keeps one value). Leader Key never emits them; if one ever appears, import
fails loudly with `ImportError.duplicateKey` rather than silently dropping —
see the guard in `Importer.swift`.

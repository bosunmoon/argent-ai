# Architectural Decisions

## ADR-0001

### Decision

Argent AI will support multiple pluggable vision backends.

### Reason

Allows experimentation with Apple Vision, Ollama, Frigate, YOLO, and 
future models without changing the API.

---

## ADR-0002

### Decision

Home Assistant will communicate only through REST.

### Reason

Keeps Argent AI independent of Home Assistant internals and allows other 
clients to use the same API.

---

## ADR-0003

### Decision

Image analysis will be a two-stage pipeline:

1. Object detection
2. Natural-language reasoning

### Reason

Greatly reduces inference time while improving reliability.

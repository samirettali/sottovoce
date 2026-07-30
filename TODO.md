# TODO

- [ ] **Selected-text transforms** — rewrite the currently selected text in any
  app through an AI prompt: global hotkey → grab selection → LLM rewrite →
  replace in place (like macparakeet's Transforms or superwhisper's modes).
  Needs an LLM provider setting, a prompt library UI, and a second hotkey;
  parked because terminal-based agents already cover most of this workflow.
- [ ] **Explore a Wispr-style self-learning dictionary** — observe the user's
  manual corrections right after an insertion and automatically turn recurring
  fixes into replacement rules. Open questions: how to observe corrections
  without invasive monitoring (Accessibility text diffing?), how to avoid
  false positives, where to store learned rules. Design exploration first;
  may end up out of scope for privacy/complexity reasons.

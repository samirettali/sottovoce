# TODO

- [ ] **Vocabulary pipeline** (design approved) — local text cleanup applied
  between the API and insertion, in three stages: filler removal (toggle +
  editable list, conservative defaults), custom replacements ("from → to",
  case-insensitive, whole-word, multi-word phrases) for recurring mishearings
  that keywords don't prevent, then whitespace/capitalization normalization.
  Live-typing mode needs a word-boundary holdback: type only up to the last
  safe boundary, keeping the last K words back (K = longest rule in words) so
  rules can match before text hits the target app; flush on next text and on
  the final completed transcript. Paste mode just runs the pipeline over the
  whole transcript. Rules stored as JSON in UserDefaults; UI in the
  Transcription tab (or a dedicated Vocabulary tab if it grows).
- [ ] **Snippets** (approved) — trigger phrase → longer text expansion ("mail
  signature" → full block). Same matching machinery as the vocabulary
  pipeline's replacements; implement together with it.

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

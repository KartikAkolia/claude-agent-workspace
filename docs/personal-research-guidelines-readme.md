# Personal Research & Writing Guidelines

Standing guidelines for how research is conducted, sourced, and written up. Consolidates `docs/personal-research-guidelines.md` and the "Research standards" section of `CLAUDE.md` (Kartik's global preferences), and adds a concrete checklist for spotting AI-generated or AI-assisted text drawn from Wikipedia's "Signs of AI writing" essay. Use this as the working reference; update the two source files first if the underlying standard changes, then reflect the change here.

## Methodology

- Find content relevant to the subject under investigation before writing anything.
- Correlate supporting information into the primary subject rather than treating it as a separate tangent.
- Cross-reference findings across multiple authoritative sources where possible, rather than relying on one.

## Source Selection

Only established, trusted, authoritative sources qualify:

- Official organizations, standards bodies, and regulatory authorities.
- Academic institutions and peer-reviewed publications.
- Established industry publications with editorial oversight.
- Recognized subject-matter experts with verifiable credentials.
- Reputable vendors and professional organizations.

## Detecting AI-Generated or AI-Assisted Content

The existing exclusion criteria (no citations, generic unsupported claims, repetitive filler, unverifiable claims, no identifiable author, poor factual consistency) are the baseline. The following, more specific tells are drawn from Wikipedia's "Signs of AI writing" essay ([en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing)) and sharpen that baseline when screening a source or reviewing a draft.

### Vocabulary tics

A high density of words like *delve, boasts, crucial, meticulous(ly), intricate/intricacies, pivotal, showcase, testament, fostering, bolstered, enhance, garner,* and *align with* is a flag, especially clustered in one passage. So is avoidance of plain "is/are" in favor of *serves as, stands as, marks, functions as,* or *boasts/features/offers a* in place of "has."

### Content-level tics

- Undue emphasis on significance or legacy: "stands/serves as," "a crucial/pivotal role," "underscores its importance," "indelible mark," "evolving landscape."
- Puffery: "boasts a," "vibrant," "rich," "profound," "groundbreaking," "renowned," "nestled," "in the heart of."
- Vague weasel attribution: "industry reports," "observers cited," "experts argue," "several sources" — implying consensus without naming who.
- Formulaic "Despite [positive framing]... faces challenges..." sections followed by speculative future-improvement language.
- Hedged connection language ("in connection with," "associated with") in place of a direct, checkable claim.
- "Not just X, but also Y" parallel-contrast constructions used rhetorically rather than to convey real contrast.

### Structural and formatting signs

Inline-header vertical lists, skipped heading levels, overuse of top-level headings, and abrupt thematic breaks between sections. Markdown syntax leaking into a context that expects something else, or broken/malformed markup.

### Tool-specific artifacts

Leftover fragments from the generating tool are a hard tell: `contentReference` / `oaicite` / `turn0search0`-style markers (ChatGPT), `[cite: 1]` (Gemini), `grok_card` (Grok), lenticular brackets or dagger symbols (DeepSeek), `attached_file` (Perplexity).

### Sourcing and citation problems

Invalid or unrelated DOIs, invalid ISBNs, book citations with no page number or URL, and references to categories or templates that don't exist. These are the same shape of failure as "content with no identifiable author or citations," just at the level of an individual footnote.

## Verification Requirements

Before using any source:

- Verify the author or publishing organization.
- Confirm the presence of citations or supporting evidence.
- Cross-check key claims against an independent authoritative source.
- Assess whether the content is original analysis rather than repackaged material.
- Confirm the source holds itself to editorial or peer-review standards.

## Plagiarism and Attribution

- No plagiarized content.
- Every significant claim traces back to an authoritative source.
- Prefer primary sources over secondary summaries.
- Attribute throughout, not just in a closing bibliography.

## Output Expectations

Research output should be evidence-based, cite authoritative sources, distinguish fact from analysis from opinion, document provenance, and flag uncertainty, limitations, or conflicting viewpoints rather than smoothing over them.

## Sources

- `docs/personal-research-guidelines.md` — the standing guideline this document consolidates.
- `CLAUDE.md` (`C:\Users\Kartik\Downloads\CLAUDE.md`) — "Research standards" section, same standard in Kartik's global preferences.
- [Wikipedia: Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing) — source for the AI-writing-tell specifics above; a living community essay, not a peer-reviewed source, so treat its examples as a screening heuristic rather than a definitive test.

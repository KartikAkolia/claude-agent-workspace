---
name: engineering-system-design
description: Design systems, services, and architectures. Trigger with "design a system for," "how should we architect," "system design for," "what's the right architecture for," or when the user needs help with API design, data modeling, or service boundaries.
---

# System Design

## 1. Requirements before design

Get functional requirements (what it does) and non-functional requirements (scale, latency, consistency, availability needs) explicit before proposing a shape. A design optimized for scale the system will never hit is premature; one that ignores scale it will hit is a rewrite waiting to happen. If the user hasn't stated non-functional requirements, ask rather than assume "web scale."

## 2. High-level shape

Propose the major components and what each owns, before drilling into any one of them. Service boundaries should follow data ownership and change-rate — things that change together and are owned by the same team belong together; things with different scaling or consistency needs belong apart.

## 3. Data model

What's stored, where, and why there (not just "a database" — which consistency/availability trade-off does this data need). Call out what's normalized vs. denormalized and why.

## 4. API/contract design

Define the boundary between components precisely: inputs, outputs, error modes, and who owns backward compatibility. Prefer contracts that let each side evolve independently over ones that require synchronized deploys.

## 5. Failure and scaling

For each component: what happens when it's slow, down, or overloaded — does the failure stay contained or cascade? What's the actual bottleneck at scale (not a guess — reason from the data model and access patterns)?

## 6. State the trade-offs explicitly

Every real design decision costs something. Say what this design makes easy, what it makes hard, and what would force a revisit (a specific scale threshold, a new requirement) — don't present it as a free win. If one option is clearly better given the stated constraints, recommend it directly rather than listing options neutrally.

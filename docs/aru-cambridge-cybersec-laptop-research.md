# ARU Cambridge Cybersecurity course — laptop research

Laptop-buying research for someone joining ARU Cambridge University's Cybersecurity-type course, done to that course's stated hardware requirements. Explicitly **not** related to Kartik's own Greenwich course (P12069, BSc Hons Computer Science, Year 0) or the `estuary/` study material for it — a separate person, separate course, separate purchase decision. Kept here as a record of the research and its sourcing, not as an ongoing project doc.

## Course requirements, as given

| Component | Minimum Spec |
|---|---|
| CPU | Intel Core i5-i7-i9 / AMD equivalent, 6-8 cores, 12-16 threads |
| RAM | 8GB DDR4 minimum, 16GB recommended (Windows alone uses 4GB) |
| Storage | 512GB SSD minimum (SSD is faster than HDD) |
| OS | Windows 10 or higher / Linux if preferred |
| GPU | Not required, but a discrete GPU may speed up some modules |
| Monitor | One built-in screen is fine; a second monitor is preferred for running multiple tasks |

Stated use: VM deployment, network simulation, penetration testing, and document writing. That combination argues for x86 (Intel/AMD) over ARM (Snapdragon X) — pentesting tooling and mainstream hypervisors assume x86 — and for RAM/storage that can be upgraded later, since VM-heavy coursework tends to outgrow whatever the minimum spec was written around.

## Research standards applied

Sourced against `docs/personal-research-guidelines.md`: established outlets with editorial oversight and named reviewers (NotebookCheck, RTINGS, Tom's Hardware, PCWorld, Thurrott, LaptopMedia, ExpertReviews, Principled Technologies), cross-checked where more than one outlet covered the same model, e-commerce listings (Amazon/eBay/PriceSpy/idealo) used only for price data rather than as review evidence. No relaxation of the guidelines was needed — every claim below traces to a named outlet. Where a UK price couldn't be confirmed live (page timeouts, dynamic pricing), that's flagged explicitly rather than presented as fact.

## High-end pick: Lenovo ThinkPad T14 Gen 6 (AMD, Ryzen AI 7 PRO 350)

16GB/512GB configuration.

| Requirement | Course Minimum | This laptop | Met? |
|---|---|---|---|
| CPU | 6-8 cores, 12-16 threads | Ryzen AI 7 PRO 350, 8 cores / 16 threads | Yes, top of range |
| RAM | 8GB min, 16GB recommended | 16GB DDR5-5600, socketed (upgradeable) | Yes — note: course spec says DDR4, this is the newer DDR5 |
| Storage | 512GB SSD minimum | 512GB NVMe SSD | Yes, at the floor, not headroom |
| OS | Windows 10+ or Linux | Windows 11 Pro; good Linux driver support for dual-boot | Yes |
| GPU | Not required | Integrated Radeon 860M only | Yes |
| Monitor | Second monitor preferred | 14" built-in + 2x Thunderbolt 4 + 1x HDMI | Yes |

Weight 1.38 kg. Battery described as "good, all-day" by NotebookCheck's review. RAM and SSD are both user-replaceable, per NotebookCheck's teardown notes — useful if 16GB turns out tight for concurrent VMs later. UK price: £1,725 list direct from Lenovo (config 21QJCTO1WWGB3); £1,585–1,749 via third-party retailers (eBay, resellers) for comparable specs. NotebookCheck's own review flags a PC-industry supply crunch pushing next-gen ThinkPad pricing up, which is part of why this outgoing generation still represents good value — but it also means the price found here isn't guaranteed to hold; worth re-checking live pricing (Currys Business, Lenovo outlet, eBay UK) before buying.

Runner-up considered at this tier: Framework Laptop 13 (Ryzen AI 7 350, same 8c/16t) — best-in-class repairability and official Linux support, but its own reviewers (Tom's Hardware) call out battery life as the weak point by name against this class of machine, clocking ~9h11m in endurance testing versus competitors offering several more hours. Ruled out as the primary pick specifically because battery life is one of the two things (alongside price/performance) this search was optimizing for.

## Mid-range alternatives (price/performance priority)

The T14 Gen 6 above was flagged by the requester as the high-end option; these three sit lower on price while still clearing the CPU/RAM/storage floor.

| Model | CPU (cores/threads) | RAM / Storage | Weight | Battery | UK Price | Upgradeable | Price confidence |
|---|---|---|---|---|---|---|---|
| Lenovo ThinkPad E14 Gen 6 (AMD) | Ryzen 7 7735U, 8c/16t | 16GB DDR5 (2x SO-DIMM) / 512GB (2x M.2) | 1.42 kg | 47Wh — "under average" per NotebookCheck | £700–900 (anchored: Gen 5 equivalent £729.58, Gen 7 successor £734.99) | Yes — most upgradeable option found, including a second open M.2 slot the pricier T-series doesn't have | High — confirmed retailer anchors |
| HP ProBook 445 G11 | Ryzen 7 7735U, 8c/16t | 16GB / 512GB | Not confirmed | Best of the three — ~14h on a light/web-browsing load, independently measured (Principled Technologies) to beat the ThinkPad E14 Gen 6 head-to-head | Est. £700–900 (typical ProBook 445 positioning) | Not confirmed | Medium — live UK price page timed out before a figure was captured |
| Acer Swift Go 14 (SFG14-41) | Ryzen 7 7730U, 8c/16t | 16GB LPDDR4X — literal DDR4 match to the course spec / 512GB | Not confirmed | Not confirmed for this exact config | Est. ~£850, extrapolated from a €980 NotebookCheck data-sheet price for a near-identical spec | No | Low — UK store page timed out before a figure was captured |

Recommendation at this tier: **ThinkPad E14 Gen 6 AMD**. It's the only one of the three with a confirmed UK price anchor and a named independent verdict — NotebookCheck's review title calls it "highly upgradeable and affordable" (84% score) — and it carries over the ThinkPad keyboard/durability/security features from the T14 pick at roughly half the price. The trade-off, stated by NotebookCheck rather than assumed: a dimmer, lower-color-gamut screen and a smaller battery than the T14. Neither matters much for VM work, pentesting, or document writing the way it would for colour-sensitive or media work.

HP ProBook 445 G11 is the better pick specifically if battery life matters more than the last confirmed pound of price — it's the only one of the three independently shown to beat the ThinkPad E14 on runtime, but its own UK price wasn't confirmed live in this session.

## Open items

- Confirm live UK pricing for the HP ProBook 445 G11 and Acer Swift Go 14 (SFG14-41) directly — both timed out on fetch during this session and are carried above as estimates, not verified figures.
- Re-check ThinkPad T14 Gen 6 AMD pricing before purchase given NotebookCheck's own note about near-term ThinkPad price increases.
- If 16GB turns out tight during actual VM-heavy coursework, both the T14 Gen 6 and E14 Gen 6 have user-accessible RAM slots to upgrade later; the HP ProBook and Acer Swift Go were not confirmed either way in this session.

## Sources

- [NotebookCheck — ThinkPad T14 Gen 6 AMD review](https://www.notebookcheck.net/AMD-Ryzen-AI-meets-classic-ThinkPad-Lenovo-ThinkPad-T14-Gen-6-AMD-laptop-review.1222690.0.html)
- [NotebookCheck — ThinkPad T14 Gen 6 AMD spec sheet](https://www.notebookcheck.net/Lenovo-ThinkPad-T14-Gen-6-AMD.1185577.0.html)
- [NotebookCheck — ThinkPad E14 Gen 6 AMD review](https://www.notebookcheck.net/Highly-upgradeable-and-affordable-Lenovo-ThinkPad-E14-Gen-6-AMD-laptop-review.953041.0.html)
- [Tom's Hardware — Framework Laptop 13 (Ryzen AI 300) review](https://www.tomshardware.com/laptops/ultrabooks-ultraportables/framework-laptop-13-amd-ryzen-ai-300-series-review)
- [Tom's Hardware — ASUS Zenbook S14 review](https://www.tomshardware.com/laptops/asus-zenbook-s14-review-lunar-lake-ultra-7-258v)
- [LaptopMedia — Dell Pro 14 Plus (PB14250) review](https://laptopmedia.com/review/dell-pro-14-plus-pb14250-review-is-plus-the-new-premium-cracking-dells-code/)
- [NotebookCheck — Dell Pro 14 Plus (PB14255) review](https://www.notebookcheck.net/Finally-embracing-AMD-for-the-pro-series-Dell-Pro-14-Plus-PB14255-laptop-review.1179867.0.html)
- [RTINGS — Best Business Laptops of 2026](https://www.rtings.com/laptop/reviews/best/by-usage/business)
- [Principled Technologies — HP ProBook 445 G11 comparative report](https://www.principledtechnologies.com/clients/reports/HP/ProBook-445-competitive-1124/)
- [PriceSpy UK — ThinkPad T14 Gen 6 pricing](https://pricespy.co.uk/s/lenovo-thinkpad-t14-gen-6/)
- [PriceSpy UK — ThinkPad E14/T14 pricing](https://pricespy.co.uk/s/lenovo-t14-laptop/)
- [idealo.co.uk — ThinkPad E14 Gen 7 pricing](https://www.idealo.co.uk/compare/206292680/lenovo-thinkpad-e14-g7.html)
- [Frame.work — Laptop 13](https://frame.work/laptop13)
- [ExpertReviews — Acer Swift Go 14 review](https://www.expertreviews.co.uk/technology/laptops/acer-swift-go-14-review)
- [Acer UK — Swift Go 14 SFG14-41 product page](https://store.acer.com/en-gb/acer-swift-go-14-ultra-thin-laptop-sfg14-41-silver)
- [HP UK — ProBook 445 product page](https://www.hp.com/gb-en/shop/product.aspx?id=a23frea&opt=abu&sel=ntb)

# Pet AI Asset Generation — Status & Continuation Brief

**Last updated:** 2026-04-28
**Purpose:** Authoritative tracking doc for the v4.0 pet redesign asset pipeline. New sessions pick up from here.

> **For Claude (new session):** Start by reading this file, then `docs/plans/2026-04-27-v4.0-pet-redesign-design.md`. The 36-breed expansion is currently the active workstream. Use the existing PixelLab batch submission pattern documented below — do NOT re-derive it from scratch.

---

## 1. PixelLab Subscription State

- **Tier:** Pixel Apprentice — `$12/mo`, 2000 generations/month
- **Activated:** 2026-04-28
- **Quota used:** 1/2000 (after fox elder test) + ~2 (totoro/hamster baby resubmits) — verify on next login
- **Fast queue speed:** ~1–3 min per generation (vs free slow tier 8+ hours)
- **Account page:** Shows "Pixel Apprentice ✓ Active" after page refresh

**Critical lesson learned:** Free slow queue is unworkable for batch work (8+ hr/gen). 6 free-tier items submitted earlier got stuck; resubmitting on fast tier is the only path. Don't wait on slow queue again.

---

## 2. Stuck-Item Resubmission Status

The 6 items submitted on free tier before subscription still show loading spinners and never complete. Plan: resubmit each on fast tier (cost: 6 of 2000 quota).

| # | Item | Status | Output |
|---|---|---|---|
| 1 | totoro baby | ⏳ in-progress (resubmitted) | pending — verify completion + export to `species-zips-stages/totoro-baby.zip` |
| 2 | hamster baby | ✅ done (~1 min on fast tier) | `species-zips-stages/hamster-baby.zip` |
| 3 | hamster adult | ⏳ pending resubmit | → `species-zips-stages/hamster-adult.zip` |
| 4 | fox baby | ⏳ pending resubmit | → `species-zips-stages/fox-baby.zip` |
| 5 | fox adult | ⏳ pending resubmit | → `species-zips-stages/fox-adult.zip` |
| 6 | totoro elder | ⏳ pending resubmit | → `species-zips-stages/totoro-elder.zip` |

**Bonus already done:** `species-zips-stages/fox-elder.zip` (fast-tier test, ~3.5 min).

---

## 3. Existing Asset Inventory

### Adults — `species-zips/`
bear, bird, cat, dog, dragon, frog, ghost, octopus, rabbit, slime, totoro

### Lifecycle stages — `species-zips-stages/`
- bear-cub, bear-elder
- bird-elder, bird-hen, bird-rooster
- cat-baby, cat-elder
- dog-baby, dog-elder
- dragon-elder, dragon-hatchling
- fox-elder
- frog-elder, frog-tadpole
- hamster-baby
- octopus-baby, octopus-elder
- rabbit-baby, rabbit-elder
- slime-baby, slime-elder

**Convention:** adults → `species-zips/{species}.zip`; baby/elder/special → `species-zips-stages/{species}-{stage}.zip`.

---

## 4. Approved 36-Breed Expansion Plan

User approved on 2026-04-28 (`great`). Each breed has 3–5 sub-varieties × 3 stages (baby/adult/elder) ≈ 324–540 generations total. Fits 2000/month quota.

> **Open question:** User previously said *"海中生物先不出現"* but the approved list includes octopus/crab/jellyfish under 水族. **Re-confirm before generating water species.**

### 🐾 哺乳類 (18)
| # | Breed | Sub-varieties |
|---|---|---|
| 1 | 貓 (cat) | 波斯 / 孟加拉 / 虎斑 / 三花 / 暹羅 |
| 2 | 狗 (dog) | 柴犬 / 牧羊犬 / 臘腸犬 / 拉布拉多 / 哈士奇 |
| 3 | 兔 (rabbit) | 荷蘭兔 / 安哥拉 / 垂耳 / 獅子兔 |
| 4 | 倉鼠 (hamster) | 黃金 / 三線 / 一線 / 白熊 |
| 5 | 狐狸 (fox) | 紅狐 / 北極狐 / 銀狐 |
| 6 | 刺蝟 (hedgehog) | 棕刺 / 白刺 / 巧克力色 |
| 7 | 熊 (bear) | 棕熊 / 黑熊 / 北極熊 / 熊貓 |
| 8 | 浣熊 (raccoon) | 標準 / 極地白 |
| 9 | 水獺 (otter) | 河獺 / 海獺 |
| 10 | 狼 (wolf) | 灰狼 / 白狼 / 黑狼 |
| 11 | 牛 (cow) | 乳牛 / 黃牛 / 高地牛 |
| 12 | 豬 (pig) | 粉豬 / 黑豬 / 麝香豬 / 野豬 |
| 13 | 羊 (sheep) | 綿羊 / 山羊 / 美利奴 |
| 14 | 鹿 (deer) | 梅花鹿 / 白尾鹿 / 麋鹿 |
| 15 | 松鼠 (squirrel) | 紅松鼠 / 灰松鼠 / 飛鼠 |
| 16 | 馬 (horse) | 棕馬 / 黑馬 / 斑馬風 |
| 17 | 樹懶 (sloth) | 二趾 / 三趾 |
| 18 | 紅貓熊 (red panda) | 標準 / 雪松鼠版 |

### 🐦 鳥類 (6)
| # | Breed | Sub-varieties |
|---|---|---|
| 19 | 雞 (bird/chicken) | 公雞 / 母雞 / 烏骨雞 |
| 20 | 鴨 (duck) | 綠頭 / 鴛鴦 / 黃鴨子 |
| 21 | 貓頭鷹 (owl) | 雪鴞 / 草鴞 / 角鴞 |
| 22 | 企鵝 (penguin) | 帝企鵝 / 國王 / 冠企鵝 |
| 23 | 鸚鵡 (parrot) | 金剛 / 玄鳳 / 虎皮 |
| 24 | 鴿 (pigeon) | 灰鴿 / 白鴿 / 信鴿 |

### 🐸 兩棲爬蟲 (4)
| # | Breed | Sub-varieties |
|---|---|---|
| 25 | 青蛙 (frog) | 樹蛙 / 牛蛙 / 箭毒蛙 |
| 26 | 烏龜 (turtle) | 陸龜 / 水龜 / 海龜 |
| 27 | 蜥蜴 (lizard) | 鬃獅蜥 / 變色龍 / 守宮 |
| 28 | 蛇 (snake) | 球蟒 / 玉米蛇 / 牛奶蛇 |

### 🌊 水族 (3 — ⚠️ re-confirm)
| # | Breed | Sub-varieties |
|---|---|---|
| 29 | 章魚 (octopus) | 紫 / 紅 / 藍環（保留 legacy） |
| 30 | 螃蟹 (crab) | 寄居蟹 / 招潮蟹 / 帝王蟹 |
| 31 | 水母 (jellyfish) | 月亮 / 箱子 / 螢光 |

### 🪄 奇幻 (5)
| # | Breed | Sub-varieties |
|---|---|---|
| 32 | 龍 (dragon) | 西方 / 東方 / 火 / 冰 |
| 33 | 史萊姆 (slime) | 普通綠 / 透明 / 火 / 水 / 金屬 |
| 34 | 龍貓 (totoro) | 白 / 灰 / 大 / 小 |
| 35 | 鳳凰 (phoenix) | 火 / 冰 / 光 |
| 36 | 獨角獸 (unicorn) | 白 / 彩虹 / 黑暗 |

**幽靈 (ghost)** 已內建單階段，不算入 36 breeds。

---

## 5. PixelLab Submission Pattern (Vadimsadovski-style chibi babies)

Reused for every breed/stage. Run via Playwright in PixelLab editor.

```javascript
// 1. Open Quadruped template selector
const quad = Array.from(document.querySelectorAll('div')).find(el =>
  el.textContent.includes('Quadruped') &&
  el.textContent.includes('Four-legged') &&
  el.textContent.length === 51 &&
  window.getComputedStyle(el).cursor === 'pointer'
);
quad.click();

// 2. Configure selects:
//    [0] = skeleton (Cat / Bear / etc.)
//    [2] = 'flat shading'
//    [3] = 'low detail'

// 3. Click "Sidescroller" + "32px" buttons

// 4. Fill description textarea with breed prompt

// 5. Set 5 proportion sliders:
//    - head, arms, legs, shoulders, hips
//    - Baby chibi: head 1.7–1.8, arms/legs 0.3–0.4, shoulders/hips 1.0–1.5
//    - Adult: head 1.0–1.3, arms/legs 1.0, shoulders/hips 1.0–1.3
//    - Elder: head 1.4, arms/legs 0.5, shoulders/hips 1.5

// 6. Click "Generate Character"
// 7. Click "Continue in background" to free UI for next submission
```

**Skeleton choices observed:**
- Cat skeleton: cat / dog / fox / hamster / rabbit / small mammals
- Bear skeleton: bear / panda / totoro / large round creatures

**Per-stage proportion presets** (from earlier successful runs):
- Baby chibi totoro: head=1.8, arms=0.3, legs=0.3, shoulders=1.5, hips=1.5
- Adult fox: head=1.0, arms=1.0, legs=1.0, shoulders=1.0, hips=1.0
- Elder fox: head=1.4, arms=0.5, legs=0.5, shoulders=1.5, hips=1.5
- Baby fox kit: head=1.6, arms=0.4, legs=0.4, shoulders=0.7, hips=0.7
- Adult chubby hamster: head=1.3, arms=0.3, legs=0.3, shoulders=1.3, hips=1.3

---

## 6. Active Tasks (TaskList state — refresh in new session)

| # | Task | Status |
|---|---|---|
| 70 | Phase 2 整合 + grounding fix | ✅ completed |
| 71 | Phase 3: 章魚 → 龍貓 改造 (production keep both) | ⏳ pending |
| 72 | Write v4.0 production 升級 design doc | ✅ completed (committed `2f8be96`) |
| 73 | Phase 3 prototype: 跑 3 個龍貓 stages | ⏳ pending |
| 74 | 擴張 14 種新 species (hamster/fox/etc) | 🔄 in-progress |
| 75 | 36 breeds 擴張規劃 + 執行 | 🔄 in-progress |

---

## 7. Open Decisions

1. **水族類 inclusion** — user previously said "海中生物先不出現" but approved list includes 章魚 / 螃蟹 / 水母. Re-confirm before generating.
2. **鳥類 sub-variant UX** — nested submenu vs flat 4-button picker (currently rooster/hen handled as separate cards). Deferred until UI work begins.
3. **v4.0 production migration** — 5.5–7 week project, design doc done, no plan doc yet.
4. **Production octopus + totoro coexistence** — both must remain; species data needs additive change, not replacement.

---

## 8. Recommended New-Session Entry Points

**If continuing asset generation:**
1. Open PixelLab editor in Playwright
2. Verify totoro baby resubmit completed → export to `species-zips-stages/totoro-baby.zip`
3. Resubmit remaining 4 stuck items (hamster adult, fox baby, fox adult, totoro elder) using §5 pattern
4. Begin 36-breed Batch 1 (recommend 哺乳類 cat/dog sub-varieties first — highest user value)

**If switching to implementation:**
1. Read `docs/plans/2026-04-27-v4.0-pet-redesign-design.md`
2. Use `superpowers:writing-plans` to convert design doc → step-by-step plan
3. Then `superpowers:subagent-driven-development` to execute

**If addressing open decisions:** Ask user to confirm §7 items 1–4 before committing more quota or code.

# Pet AI Asset Generation — Status & Continuation Brief

**Last updated:** 2026-04-29 (session 3 ended — autonomous-run handoff doc for new session, see §8)
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

## 2. Stuck-Item Resubmission Status — ✅ ALL DONE (2026-04-28 session 2)

| # | Item | Status | Output |
|---|---|---|---|
| 1 | totoro baby | ✅ done | `species-zips-stages/totoro-baby.zip` (8 dir × 96px) |
| 2 | hamster baby | ✅ done | `species-zips-stages/hamster-baby.zip` |
| 3 | hamster adult | ✅ done | `species-zips-stages/hamster-adult.zip` |
| 4 | fox baby | ✅ done | `species-zips-stages/fox-baby.zip` |
| 5 | fox adult | ✅ done | `species-zips-stages/fox-adult.zip` |
| 6 | totoro elder | ✅ done | `species-zips-stages/totoro-elder.zip` |
| bonus | fox elder | ✅ done (earlier) | `species-zips-stages/fox-elder.zip` |

Quota burned this session: 4 generations (hamster adult / fox baby / fox adult / totoro elder).

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

### 🌊 水族 (排除 — 2026-04-28 session 2 確認)
使用者再次確認「海中生物先不出現」。章魚 legacy adult 保留，但**不**生成新的章魚子品種、螃蟹、水母。
36 breeds 實際執行範圍縮減為 33 breeds（哺乳 18 + 鳥 6 + 兩棲爬蟲 4 + 奇幻 5）。

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

### Batch 1 progress (2026-04-28 session 2)
- ✅ **cat 5 子品種 × 3 stages = 15 zips** (persian / bengal / tabby / calico / siamese × baby / adult / elder)
- ✅ **dog 5 子品種 × 3 stages = 15 zips** (shiba / collie / dachshund / labrador / husky × baby / adult / elder)

### Batch 2 progress (2026-04-28 session 2 cont.)
- ✅ **rabbit 4 子品種 × 3 stages = 12 zips** (dutch / angora / lop / lionhead × baby / adult / elder)
  - Note: lionhead variety leans more lion-like than rabbit-like; prompt "lion mane" was too dominant. Acceptable for now.
- ✅ **hamster 4 子品種 × 3 stages = 12 zips** (golden / winterwhite / campbell / white × baby / adult / elder)
  - Note: winterwhite adult/elder shows red color artifacts where stripes were prompted. Acceptable structure.
- ✅ **fox 3 子品種 × 3 stages = 9 zips** (red / arctic / silver × baby / adult / elder)

Session 2 quota burned: ~75 / 2000 (4 stuck + 15 cat + 15 dog + 12 rabbit + 12 hamster + 9 fox + ~8 retries).
Cumulative on subscription: ~76 / 2000 (server showed 70/2000 at start of session 3).

### Batch 2 progress (2026-04-28 session 3)
- ✅ **hedgehog 3 子品種 × 3 stages = 9 zips** (brown / white / chocolate × baby / adult / elder)
  - Note: 白刺 (white) variety has weak spine definition (white-on-white low contrast); looks more like a soft round albino mammal than clearly a hedgehog. Acceptable, similar trade-off to rabbit-lionhead.
  - 棕刺 + 巧克力 stages clearly read as hedgehog with visible spine pattern.
- ✅ **bear 4 子品種 × 3 stages = 12 zips** (brown / black asiatic / polar / panda × baby / adult / elder)
  - Note: 棕熊 baby came out fox-orange instead of warm brown — model over-saturated "warm brown" prompt. Acceptable.
  - 黑熊 baby is lighter than adult/elder (less true-black). White V-chest mark visible across stages.
  - 北極熊 elder has yellowish-cream tint as prompted.
  - 熊貓 reads as iconic black-and-white panda across all 3 stages — strongest identification.
- ✅ **raccoon 2 子品種 × 3 stages = 6 zips** (standard masked / arctic albino white × baby / adult / elder)
  - Note: 標準 stages show clear black bandit-mask + ringed tail — strong raccoon identity.
  - 極地白 (arctic) stages lose the mask + ringed-tail features when going albino; reads as a chubby pink-eyed white cat instead. Same trade-off pattern as hedgehog 白刺 / hamster winterwhite.
- ✅ **otter 2 子品種 × 3 stages = 6 zips** (river / sea × baby / adult / elder)
  - Note: 河獺 adult initial submit silently failed (Generate click swallowed during page transition); resubmitted successfully. Same happened to 河獺 elder. **Lesson: increase post-Quadruped delay from 500ms to 800ms — keeps the form stable enough to receive Generate click.**
  - 河獺 baby + elder read as otter; adult came out too dog-like.
  - 海獺 baby + adult correctly chunky; elder skews more sloth/kinkajou-like.
- ✅ **wolf 3 子品種 × 3 stages = 9 zips** (grey timber / white arctic / black melanistic × baby / adult / elder)
  - Strongest batch in session 3 — all 9 read clearly as wolves with proper canine silhouette + ear shape + yellow/blue eyes.
  - Skeleton: dog (canid). Worked great with the husky/timber-wolf prompt mix.
  - Black variety reads slightly charcoal-grey rather than pure jet-black, but identity is preserved.
- ✅ **cow 3 子品種 × 3 stages = 9 zips** (Holstein dairy / yellow Taiwan / Scottish Highland × baby / adult / elder)
  - Skeleton: bear (large quadruped from the 5 available skeletons).
  - All 9 read clearly as cattle with distinct variety identity.
  - Holstein 3 stages have iconic black-and-white spots; yellow Taiwan stages have warm tan coats with red collar bell; Highland stages have shaggy ginger-red bangs and curved horns visible from adult.
- ✅ **pig 4 子品種 × 3 stages = 12 zips** (pink domestic / black domestic / Vietnamese pot-bellied / wild boar × baby / adult / elder)
  - Skeleton: bear. All 12 read clearly as pigs with distinct varieties.
  - Wild boar baby has the iconic light-cream horizontal piglet stripes; adult shows visible white tusks.
  - Pot-bellied two-tone (dark grey back / pink belly) reads correctly though the saggy-belly silhouette isn't extremely exaggerated.
  - Strong batch.
- ✅ **sheep 3 子品種 × 3 stages = 9 zips** (woolly white / mountain goat / Merino × baby / adult / elder)
  - Skeleton: bear. All 9 read clearly with distinct identity.
  - 綿羊 stages classic fluffy white wool with black face; elder yellowed nicely.
  - 山羊 adult has iconic backward-curving horns + long white beard — strong goat identity.
  - 美利奴 reads as chunky thick-fleece sheep, slightly pink-cream tone (stands out from 綿羊).
- ✅ **deer 3 子品種 × 3 stages = 9 zips** (sika / white-tailed / moose × baby / adult / elder)
  - Skeleton: horse (slender ungulate body — the right shape for deer/moose).
  - 梅花鹿 stages have iconic tan + white spots (baby/adult/elder all show spotting).
  - 白尾鹿 adult has clear branching antlers + white tail flag.
  - 麋鹿 adult shows characteristic palmate paddle-shaped antlers + droopy nose + dewlap.
- ✅ **squirrel 3 子品種 × 3 stages = 9 zips** (red / grey / flying × baby / adult / elder)
  - Skeleton: cat (small mammal).
  - 紅松鼠 stages have iconic bright orange-red coat + huge bushy tail — strongest identity.
  - 灰松鼠 stages clearly grey with bushy tail.
  - 飛鼠 (flying squirrel) patagium skin-flap feature did NOT render at 32px — they look like generic brown small mammals / squirrel pups. Same kind of small-feature limitation as raccoon-arctic mask. Acceptable.
- ✅ **horse 3 子品種 × 3 stages = 9 zips** (chestnut / black / zebra × baby / adult / elder)
  - Skeleton: horse. Strong batch — all 9 read clearly with distinct identity.
  - 棕馬 chestnut coat + dark mane visible; 黑馬 sleek jet-black with flowing mane.
  - 斑馬 black-and-white stripe pattern preserved across all 3 stages — strongest horse-batch identity.
- ✅ **sloth 2 子品種 × 3 stages = 6 zips** (two-toed / three-toed × baby / adult / elder)
  - Skeleton: bear. Round chunky body + cream face + smile reads as sloth across all 6.
  - 三趾 stages have visible darker eye-mask stripes (best identity differentiator).
  - 二趾 vs 三趾 toe-count detail does NOT render at 32px — claws appear as standard short arms.
  - Same small-feature limitation as flying squirrel patagium / raccoon arctic mask.
- ✅ **red panda 2 子品種 × 3 stages = 6 zips** (standard rusty / chinese snow-frosted × baby / adult / elder) — **last mammal!**
  - Skeleton: cat. All 6 read clearly as red pandas.
  - 標準 stages have iconic rusty-red coat + white-tipped ears + ringed bushy tail.
  - 雪松 (snow-frosted) variant has paler/whiter accents but same red panda silhouette — clearly distinct from 標準.

🎉 **MAMMALS COMPLETE: 18/18 species, 113 zips total in session 3.** 🎉

### Birds phase started (session 3 cont.)
- ✅ **duck 3 子品種 × 3 stages = 9 zips** (mallard / mandarin / yellow rubber-duck × baby / adult / elder)
  - Skeleton: cat (per user instruction — quadruped + cat works great for birds)
  - 綠頭 mallard 3 stages all show iconic green head + grey body
  - 鴛鴦 mandarin adult shows iconic orange crest + colorful pattern (most striking)
  - 黃鴨子 stages classic rubber-duck yellow
  - **Cat skeleton confirmed working for birds** — no need to switch to humanoid
- ✅ **owl 3 子品種 × 3 stages = 9 zips** (snowy / barn heart-face / horned eagle × baby / adult / elder)
  - Skeleton: cat. All 9 read clearly as owls.
  - 雪鴞 pure white + yellow eyes; 草鴞 tan body + iconic heart-shaped white face;
  - 角鴞 mottled brown + prominent ear tufts (most distinctive variety).

### Birds phase continued (session 4 — autonomous run)
- ✅ **penguin 3 子品種 × 3 stages = 9 zips** (emperor / king / crested rockhopper × baby / adult / elder)
  - Skeleton: cat. All 9 read clearly as penguins with proper bird silhouette.
  - 帝企鵝 (emperor) baby grey downy fluff; adult shows orange chest patch (small but present); elder faded properly.
  - 國王 (king) baby brown downy (most distinct baby variety); adult shows iconic teardrop orange ear patches + chest gradient; elder retains identity.
  - 冠企鵝 (crested) baby yellow tufts visible; adult prominent yellow eyebrow tufts + red eyes are iconic; elder thinning crest.
- ✅ **parrot 3 子品種 × 3 stages = 9 zips** (macaw / cockatiel / budgie × baby / adult / elder)
  - Skeleton: cat. All 9 read clearly as parrots with distinct varieties.
  - 金剛 (macaw) iconic vivid red body with blue + yellow wing accents — strongest variety identity.
  - 玄鳳 (cockatiel) adult yellow head crest + orange cheek patch unmistakable; elder skews more cockatoo-pale.
  - 虎皮 (budgie) bright green-and-yellow body across stages, faded olive in elder.
  - Note: macaw-elder silently failed first submission (UI returned success but card never appeared); 1× retry needed. **Possible cause: post-Generate page transition swallowed the request.** Retry succeeded.
- ✅ **pigeon 3 子品種 × 3 stages = 9 zips** (grey city / white dove / brown homing × baby / adult / elder)
  - Skeleton: cat. All 9 read clearly as pigeons / doves with distinct varieties.
  - 灰鴿 (grey city) classic urban pigeon look with iridescent purple-pink neck collar visible in adult.
  - 白鴿 (white dove) pristine snow-white across baby/adult; elder shows yellowing-cream tint as prompted.
  - 信鴿 (brown homing) mottled grey-brown plumage distinct from grey variety; baby a touch sparrow-like but identifiable.
  - Increased post-Quadruped delay 800ms→1000ms and post-prompt delay 500ms→700ms based on macaw-elder lesson; no silent fails this batch.

Session 4 quota burned: 28 generations (penguin 9 + parrot 9 + 1 retry + pigeon 9).
Cumulative on subscription: ~235 / 2000.

### PixelLab fast tier behavior observed
- **Concurrent limit: 3 background jobs (Tier 1)**. 4th + returns HTTP 429.
- **Pacing**: 120s between submissions reliably stays under cap; 75s sometimes hits 429.
- **Wizard URL**: `/create-character/new?prompt=...` (advanced editor surfaces here, not on `/editor` which is Pixelorama painter).
- **Form fields**: Quadruped → reveals skeleton dropdown (Bear/Cat/Dog/Horse/Lion). Use Cat for small mammals (cat/fox/hamster), Bear for large round (totoro).
- **Quick presets**: Chibi (head 1.0, hip 1.0?) for baby/elder; Cartoon for adult.
- **Sliders**: drag/click events on Chakra slider track unreliable — quick presets are more reliable than direct slider manipulation.

---

## 7. Open Decisions

1. ~~**水族類 inclusion**~~ — ✅ resolved 2026-04-28: exclude 水族, keep legacy octopus only.
2. **鳥類 sub-variant UX** — nested submenu vs flat 4-button picker (currently rooster/hen handled as separate cards). Deferred until UI work begins.
3. **v4.0 production migration** — 5.5–7 week project, design doc done, no plan doc yet.
4. **Production octopus + totoro coexistence** — both must remain; species data needs additive change, not replacement.

---

## 8. Recommended New-Session Entry Points

### 🚨 AUTONOMOUS RUN INSTRUCTIONS (next session — do NOT pause between batches) 🚨

**User has authorized continuous execution. Do NOT stop to ask "繼續嗎?" between batches. Plough through everything below in one go, committing each batch as it completes. Only pause for blocking errors (subscription expired, real 429 backoff, broken wizard flow).**

Last completed: **owl 3×3 = 9 zips** (session 3, 2eabc58).
Skeleton convention: **all birds use Quadruped + Cat skeleton** (confirmed working). Reptiles likely the same (cat for small, bear for large). Fantasy will need case-by-case decisions but default to bear for large/round and cat for small.

**Execution queue — run all of these in order, commit per species:**

1. **penguin** 3×3 = 9 — 帝企鵝 (Emperor, large with orange chest patch) / 國王 (King, similar but smaller) / 冠企鵝 (Crested with yellow eyebrow tufts) — skeleton: cat
2. **parrot** 3×3 = 9 — 金剛 (Macaw, vibrant red/blue) / 玄鳳 (Cockatiel grey + orange cheek) / 虎皮 (Budgie green/yellow striped) — skeleton: cat
3. **pigeon** 3×3 = 9 — 灰鴿 (grey city pigeon) / 白鴿 (white dove) / 信鴿 (homing pigeon, mottled grey-brown) — skeleton: cat
4. **turtle** 3×3 = 9 — 陸龜 (tortoise, dome shell) / 水龜 (red-eared slider, green) / 海龜 (sea turtle with flippers) — skeleton: cat
5. **lizard** 3×3 = 9 — 鬃獅蜥 (bearded dragon, spiky chin) / 變色龍 (chameleon, curled tail + zigzag eyes) / 守宮 (gecko, sticky toe pads, light) — skeleton: cat
6. **snake** 3×3 = 9 — 球蟒 (ball python, brown patterns) / 玉米蛇 (corn snake, orange+red) / 牛奶蛇 (milk snake, red-black-yellow bands) — skeleton: cat
7. **dragon** 4×3 = 12 — 西方 (western with bat wings) / 東方 (eastern long serpentine) / 火 (fire/red) / 冰 (ice/blue) — skeleton: bear (legacy `dragon-elder` / `dragon-hatchling` / `dragon` exist as starting reference; new variants use those as style anchor)
8. **slime** 5×3 = 15 — 普通綠 (standard green) / 透明 (transparent) / 火 (fire-orange) / 水 (water-blue) / 金屬 (metallic-silver) — skeleton: bear (legacy `slime` adult + `slime-baby` + `slime-elder` exist)
9. **totoro** 4×3 = 12 — 白 (white small) / 灰 (grey medium) / 大 (large dark) / 小 (chibi tiny) — skeleton: bear (legacy `totoro` adult + `totoro-baby` + `totoro-elder` exist)
10. **phoenix** 3×3 = 9 — 火 (fire red-orange flame body) / 冰 (ice blue crystalline) / 光 (light yellow with halo) — skeleton: cat (mythical bird, treat like owl)
11. **unicorn** 3×3 = 9 — 白 (classic white with golden horn) / 彩虹 (rainbow mane) / 黑暗 (dark/cursed black with red eyes) — skeleton: horse

**Total remaining: 81 generations × 180s ≈ 4.5 hours.** Quota allows it (~207 used / 2000 budget).

**Operational protocol per batch:**
- Create N tasks (TaskCreate) for the breed × stages
- For each task: TaskUpdate in_progress → click Create → wizard JS (Quadruped + skeleton + flat shading + low detail + Sidescroller + 32px + Chibi for baby/elder, Cartoon for adult) → fill prompt → Generate → wait 180s → next
- After all N submitted: wait 240s, reload, batch-export via `button[aria-label="Export character as ZIP"]`
- Rename `.playwright-mcp/` → `species-zips-stages/{species}-{variety}-{stage}.zip`
- Build `unzip -p east.png` → magick scale 4× → 3×N grid for visual check
- Read grid, write 3-line variety quality summary
- TaskUpdate completed for the N tasks
- Update STATUS.md (move species to "done", update cumulative quota)
- Commit: `feat(pet-design): add {species} N sub-varieties × 3 stages (M zips)` with co-author trailer

**After all 11 batches:** Update STATUS to declare Batch 2 fully complete (mammals + birds + reptiles + fantasy = 33 species, ~440 zips total cumulative).

**Operational notes for next session:**
- Open `/create-character` in Playwright (kill any stale Chrome on `mcp-chrome-84ff974` first if browser-already-in-use error appears).
- Submit one breed at a time with 180s pacing between submissions; 120s sometimes hits 429.
- After Generate, inline JS waits for "Continue in background" button (≤30s) and clicks it.
- Each download lands in `.playwright-mcp/`; renames map prompt prefix → `species-zips-stages/{species}-{variety}-{stage}.zip`.
- Visual check: `unzip -j` rotations/east.png from each zip into a tmp dir, compose 3-col grid for review.

**Cumulative quota: ~207 / 2000.** Plenty left.

**Session 3 confirmed wizard flow (works end-to-end):**
- `/create-character` page → click "Create" button (top of form area) → redirects to `/create-character/new` (the wizard).
- The legacy URL `/create-character/new?prompt=...` redirects to signin for some reason — go via the Create button instead.
- Wizard structure: Quadruped button reveals 4 dropdowns (skeleton / outline / shading / detail). Set via React-aware setter:
  ```js
  const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set;
  setter.call(sel, val); sel.dispatchEvent(new Event('change', { bubbles: true }));
  ```
- Quick presets used: **Chibi** for baby + elder, **Cartoon** for adult. Slider direct-manipulation skipped.
- After Generate → "Continue in background" appears within ~3-5s; click via `Array.from(document.querySelectorAll('button')).find(b => b.textContent.trim() === 'Continue in background').click()`.
- Each card on `/create-character` has `button[aria-label="Export character as ZIP"]` — bulk-download via JS loop with 800ms gap.
- Download filenames truncate prompt to ~50 chars with hyphens; rename map: prompt-prefix → `species-zips-stages/{species}-{variety}-{stage}.zip`.

### If switching to implementation
1. Read `docs/plans/2026-04-27-v4.0-pet-redesign-design.md`
2. Use `superpowers:writing-plans` to convert design doc → step-by-step plan
3. Then `superpowers:subagent-driven-development` to execute

**If addressing open decisions:** Ask user to confirm §7 items 2–4 before committing more code (item 1 已 resolved).

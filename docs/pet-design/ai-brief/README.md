# PeerDrop 寵物 AI 生圖 Brief（v2 cat 擴充版）

本目錄是給 AI 圖像生成工具（Midjourney / Retro Diffusion / PixelLab.ai / Stable Diffusion + Pixel LoRA）使用的「設計委託書」。目標：以 PeerDrop 已上架的 v0 cat 為風格錨點，請 AI 產出細節更豐富的精靈圖，再回灌到原型 (`cat-v2.json`)。

> **為什麼這樣做？**
> 過去試過 5+ 個 CC0 第三方素材包，都不是太缺 chibi 味、就是動作太少、就是不夠 ProHama 風。v0 cat 是 PeerDrop 自家 IP、線上版已驗證、使用者也認可這個方向，所以直接以 v0 為基準擴充，遠比繼續試素材有效率。

---

## 0. 目錄結構

```
ai-brief/
├── README.md                       ← 你正在看這個
├── package.json                    ← 共用 web-prototype 的 sharp（symlink 過去）
├── scripts/
│   ├── render-v0-references.mjs    ← 把 v0 cat 渲成參考 PNG
│   └── import-ai-sprite.mjs        ← 把 AI 輸出回灌成 cat-v2.json（骨架）
├── references/                     ← 喂給 AI 的參考圖（已產生）
│   ├── hero-reference.png          ← ★ 主要參考圖（512×512）
│   ├── baby-sheet.png              ← baby 6 個狀態橫條
│   ├── child-sheet.png             ← child 6 個狀態橫條
│   └── {state}-{1x|4x|16x|32x}.png ← 個別狀態的多種放大版
└── raw-output/                     ← 從 AI 工具下載的原圖丟這裡
    └── {state-name}/{frame-N}.png
```

執行 render：

```bash
cd docs/pet-design/ai-brief
node scripts/render-v0-references.mjs
```

> Sharp 已經透過 `node_modules` symlink 連到 `../web-prototype/node_modules`，不用另外 `npm install`。

---

## 1. Visual Identity（風格錨點）

主要參考：[`references/hero-reference.png`](references/hero-reference.png)（512×512，由 16×16 v0 idle frame 0 用最近鄰 32× 放大）

### 比例
- **Chibi（Q 版）**：頭部約佔身高 **60–70%**
- 整體輪廓：橢圓身體 + 圓頭，沒有腰身
- 四肢短小、不寫實

### Palette（嚴格遵守，AI 輸出後會 quantize 到這組）

| Idx | Hex        | 用途                               |
|----:|------------|------------------------------------|
| 0   | transparent| 背景、空像素                       |
| 1   | `#3A2418`  | 深棕色 outline（所有輪廓線）       |
| 2   | `#F0A040`  | 主毛色（暖橘）                     |
| 3   | `#FFE6BE`  | 奶油色腹部 / 嘴邊                  |
| 4   | `#FFFFFF`  | 高光、星星粒子                     |
| 5   | `#1A1A1A`  | 眼睛黑點                           |
| 6   | `#D67B26`  | 陰影 / 耳內                        |
| 7   | `#FF8FAA`  | 粉色腮紅                           |

### Key Features（必有）
- **圓頭**：頂部小三角形耳朵（兩個像素的角）
- **大眼睛**：黑色單點 + 奶油色高光像素（`#1A1A1A` + `#FFE6BE`）
- **小嘴**：1–2 像素，不畫鼻子
- **奶油色腹部**：胸口到肚子的色塊
- **飽滿尾巴**：身體右下延伸出去
- **粉色腮紅**：兩頰各一小撮（happy 狀態尤其明顯）
- **無鬍鬚**：這是 PeerDrop 貓的招牌簡化特徵，**不要加**

### 風格參考
- **ProHama**（https://prohama.com/category/animals/）— kawaii、無鬍鬚、輪廓粗
- **Tamagotchi** — 16×16 / 32×32 像素風、單色塊、minimal
- **Neko Atsume** — 大眼、肉肉的身材、可愛觸發

### 嚴格禁止
- 寫實貓的解剖（細長身體、明顯鼻樑、肌肉線條）
- 照片質感、3D 渲染、軟邊
- 硬邊銳利的動漫風（這個是 **kawaii pixel**，不是 anime）
- 外星生物比例（過長四肢、巨型尾巴）
- 狗鼻子（突出的長鼻吻部）
- 鬍鬚

---

## 2. 動作清單（12 個 state）

最終目標解析度：**32×32**（v0 是 16×16，4× 像素數提供更多細節空間）。AI 工具通常會輸出 512×512 或 1024×1024，我們用 nearest-neighbor 在後處理階段降取樣。

每個 state 都要產出 2–4 frame，便於後續做循環動畫。

| #  | State        | Frames | 觸發時機                       | 動作描述                                                       |
|---:|--------------|------:|--------------------------------|----------------------------------------------------------------|
| 1  | `idle`       | 4     | 預設                           | 緩慢呼吸（身體上下 1 px）、偶爾尾巴擺動                        |
| 2  | `walking`    | 4     | 移動                           | 側面 4 frame 走路循環、前後腳交替                              |
| 3  | `running`    | 4     | 興奮入場                       | 步幅較大、身體前傾、尾巴往後                                   |
| 4  | `sit`        | 1     | 休息                           | 坐姿、後腳收起、前腳並攏、平靜                                 |
| 5  | `sleep`      | 2     | 閒置 30s+                      | 蜷曲側躺、眼閉成 `―`，「Z」泡泡由 render layer 額外加，不畫進精靈圖 |
| 6  | `stretch`    | 3     | 隨機 idle                      | 打哈欠 → 拱背伸展 → 放鬆                                       |
| 7  | `groom`      | 3     | 隨機 idle                      | 抬手 → 舔手 → 甩頭                                             |
| 8  | `eat`        | 4     | 餵食                           | 低頭、尾巴翹起、咀嚼動作                                       |
| 9  | `happy`      | 2     | 連線成功 / 傳輸完成            | 尾巴上揚、輕跳、眼睛瞇成 `^^`                                  |
| 10 | `tapReact`   | 2     | 直接點擊                       | 驚嚇 frame（眼睛變大）→ 回穩                                   |
| 11 | `scared`     | 2     | 傳輸失敗                       | 蹲低、耳朵往後、身體縮小                                       |
| 12 | `bellyUp`    | 2     | 連續點擊 5 次以上              | 翻肚、四腳朝天、信任姿勢                                       |

---

## 3. AI 工具 Prompt 範本

> 三組 prompt 都已經把風格鎖死，產圖時只要把 `[STATE-DESCRIPTION]` 換掉，並上傳 `references/hero-reference.png` 當圖像參考即可。

### 3.1 Midjourney v6+

```
chibi pixel art cat, orange fur with cream belly, dark brown outline, large round black eyes with cream highlight, small triangular ears, oval body, plump tail, no whiskers, kawaii Tamagotchi style, ProHama inspired, [STATE-DESCRIPTION], side-view, transparent background, 32x32 sprite, pixel-perfect, no anti-aliasing --style raw --ar 1:1 --niji 6
```

> Discord 操作：先 `/imagine` 上傳 `hero-reference.png` → 等到 link 生成 → 把 link 貼在 prompt 最前面（Midjourney 預設前置圖會作為 image reference）。

### 3.2 Retro Diffusion / PixelLab.ai

```
Subject: chibi cat, orange & cream fur, oversized round head, big black eyes, no whiskers
Style: 32x32 pixel art, Tamagotchi/ProHama kawaii aesthetic, dark brown outline, flat colors, side-view facing right
Action: [STATE-DESCRIPTION]
Output: transparent BG, 4-frame animation, nearest-neighbor only
Reference: [attach hero-reference.png]
```

> Retro Diffusion (https://retrodiffusion.ai) 與 PixelLab.ai 的網頁介面都有獨立 image reference 欄位，把 `hero-reference.png` 拖進去即可。

### 3.3 Stable Diffusion + Pixel Art LoRA

```
Positive: pixel art, chibi cat, orange fur, cream belly, 32x32, [STATE-DESCRIPTION], side-view, dark brown outline, transparent background, kawaii, big eyes, ((no whiskers)), <lora:pixel-art-style:0.8>
Negative: realistic, anti-aliased, blurry, signature, watermark, text, anime, sharp edges, photorealistic, 3D render, deformed, distorted
Settings: Steps 30, CFG 7, Sampler DPM++ 2M, 512×512 → downscale 16×
```

> 推薦的 LoRA：`pixel-art-style`（CivitAI 上有多個版本，挑下載量高的就好）。

---

### 3.4 12 個 state 的 `[STATE-DESCRIPTION]` 對照表

直接把右欄整段貼回上面三個 prompt 的 `[STATE-DESCRIPTION]` 位置：

| State        | `[STATE-DESCRIPTION]` 內容                                                                  |
|--------------|---------------------------------------------------------------------------------------------|
| `idle`       | standing relaxed, tail gently swaying, breathing softly, eyes half-closed in calm           |
| `walking`    | mid-stride side-view, front-right paw forward, back-left paw lifted, tail balanced behind   |
| `running`    | full gallop, body leaning forward, all paws off ground briefly, tail streaming back         |
| `sit`        | sitting on haunches, front paws together, tail curled around feet, calm posture             |
| `sleep`      | curled up on side, tail wrapped around body, eyes closed as small horizontal lines          |
| `stretch`    | front paws extended forward, back arched up, mid-yawn with mouth slightly open              |
| `groom`      | one front paw raised to face, tongue out licking paw, body tilted slightly                  |
| `eat`        | head down to ground, tail raised high, mouth open mid-chew, small food crumb visible        |
| `happy`      | tail straight up, slight upward bounce, eyes squinted in joy, pink blush prominent          |
| `tapReact`   | startled mid-jump, eyes wide and round, ears alert, body tense                              |
| `scared`     | crouched low, ears flattened back, tail tucked under, body small and compact                |
| `bellyUp`    | rolled onto back, all four paws in air, belly exposed, eyes content and trusting            |

---

## 4. Workflow（從生圖到回灌）

1. **打開 AI 工具**：Midjourney（Discord）/ Retro Diffusion（retrodiffusion.ai）/ PixelLab.ai / Stable Diffusion WebUI。
2. **上傳參考圖**：把 `references/hero-reference.png` 當 image reference 丟進去（多數 pixel-art 工具都支援）。
3. **貼 Prompt**：從 §3 挑一個工具的範本，把 §3.4 對應 state 的 `[STATE-DESCRIPTION]` 填進去。
4. **生 4–8 個候選**：通常 1 個 prompt 跑 4–8 變體，挑最像 ProHama 風 / 最忠於 hero-reference 的。
5. **下載 PNG**：通常 512×512 或 1024×1024。
6. **歸檔**：存到 `docs/pet-design/ai-brief/raw-output/{state-name}/{frame-N}.png`，例如：
   ```
   raw-output/idle/01.png
   raw-output/idle/02.png
   raw-output/idle/03.png
   raw-output/idle/04.png
   ```
   檔名順序就是動畫播放順序（`sort()` 用的是字典序，所以建議補零：`01`, `02` 而不是 `1`, `2`）。
7. **跑 importer**：
   ```bash
   cd docs/pet-design/ai-brief
   node scripts/import-ai-sprite.mjs \
     --state idle \
     --stage baby \
     --frames 4 \
     --size 32 \
     --input-dir raw-output/idle
   ```
   - 自動降取樣到 32×32（nearest-neighbor）
   - 自動 quantize 到 `palettes.json` 的 `default` palette
   - 寫到 `cat-v2.json`（不存在會自動建立，已存在會 merge 對應 state）
8. **進原型驗證**：重啟 web prototype dev server，切換到 v2 sprite 檢查。
9. **Iterate**：
   - 哪個 state 看起來不對 → 重生
   - Pixel-perfect 的小毛邊 → 用 Aseprite / Piskel 手動修

---

## 5. 後處理工具

| 工具          | 價格         | 用途                                    | URL                                |
|---------------|-------------|----------------------------------------|------------------------------------|
| **Aseprite**  | $20 一次性   | 業界標準 pixel art 編輯器、修細節必備   | https://aseprite.org              |
| **Piskel**    | 免費，瀏覽器 | 簡單、零安裝，適合快速修圖              | https://piskelapp.com             |
| **PNGquant**  | 免費 CLI     | Palette quantization、檔案減肥          | https://pngquant.org              |

> 建議入手：Aseprite（一次買斷終身可用，等同於 pixel art 圈的 Photoshop）。

---

## 6. 預算與時間

### 工具訂閱
- **Midjourney**：$10 / 月（Basic plan，~200 張快速圖）
- **Retro Diffusion**：$0.10–$0.50 / 圖（無訂閱也能用，按張收費）
- **PixelLab.ai**：$5 / 月起
- **Stable Diffusion + LoRA**：本機跑免費（前提是有 GPU）；雲端 ~$0.05 / 圖

### 時間估算（每個 state）
- 生 3–5 候選 + 挑一張 + Aseprite 微調 ≈ 10–30 分鐘
- 12 個 state × 平均 20 分鐘 ≈ **3–6 小時**完整跑一輪

### 成本總計
- 用訂閱：**$5–30**（Midjourney 一個月份 + Aseprite 一次性）
- 純按張收費：**$5–15**（Retro Diffusion 大概 30–60 張 final pick）

---

## 7. Q&A / 已知議題

- **Q：AI 出來的色號怎麼辦？** → 不用管，importer 會 quantize 到 default palette。但如果輸出整體偏色（例如 AI 一直畫成紫色貓），請改 prompt 強化 `orange fur`，或改用 `--palette` 指定其他 palette key。
- **Q：要不要先把參考圖混色？** → 不用。`hero-reference.png` 已經是純色塊 + 硬邊，AI 模型很容易抓到風格。
- **Q：可以一次生 sprite-strip 嗎？** → 可以，但 importer 目前只支援「每個 frame 一個 PNG」。如果 AI 輸出 4 frame 連在一起，請手動切開、或之後擴充 importer 支援 strip 切片。
- **Q：32×32 會不會太大？** → v0 是 16×16，32×32 是 4× 像素數，仍維持 pixel art identity，但細節空間更多（例如可以畫出眼睛高光、嘴角微笑、肉墊）。如果之後覺得太肥大，importer 用 `--size 24` 也行。

---

## 8. Importer 腳本說明

`scripts/import-ai-sprite.mjs` 是骨架程式，CLI 介面如下（執行 `--help` 也會印出）：

```
Required:
  --state       Animation state key
  --input-dir   Directory of source PNGs (one per frame, sorted by filename)

Optional:
  --stage       baby | child  (default: baby)
  --frames      Number of frames to read; default = all PNGs in input-dir
  --size        Output canvas size in pixels (default: 32)
  --palette     Palette key from palettes.json (default: default)
  --out         Output JSON path (default: ../cat-v2.json)
  --help        Show this message
```

它做的事：
1. 從 `--input-dir` 讀 PNG（按檔名字典序排序）
2. 用 `sharp` 的 nearest-neighbor 降取樣到 `--size × --size`
3. Alpha < 128 → 0（透明）；其餘 → 找 default palette 中歐式距離最近的色 index
4. 輸出 2D index 陣列
5. Merge 進 `cat-v2.json`（不存在會 init，已存在會保留其他 state）

**重要：這是骨架，還沒有用真實 AI 輸出測過。** 預期之後需要微調：
- Palette quantization（也許要 dithering、或改用 perceptual color space）
- Alpha 門檻（目前寫死 128）
- 是否要先 crop 透明邊框再降取樣
- AI 輸出 sprite-strip 時的切割邏輯

第一次跑完真實生圖後，請把實測問題回報，我們再迭代。

---

## 9. 下一步（給使用者）

1. 跑過 §4 的 workflow，至少先試 1 個 state（建議從 `idle` 開始，因為它要 4 frame，能驗證整個 pipeline）。
2. 把生出來的 `cat-v2.json` 接到 web prototype，視覺確認沒問題。
3. 把 12 個 state 全部跑完。
4. 用 Aseprite 修細節。
5. 最後用既有的 `scripts/export-sprite.mjs` 反向流程，把 JSON 轉回 Swift `CatSpriteData.swift`，整合進 iOS app。

如果第一輪跑下來發現某個工具特別合或不合、或 prompt 要調整，回報給 Claude 一起更新這份 brief。

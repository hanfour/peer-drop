# Pet Species-Specific Behavior Design

**Date:** 2026-04-14
**Status:** Approved

## Overview

讓 10 種寵物各自擁有獨特的行為模式、物理規則、離開/回來動畫、以及聊天室互動方式，取代現有的通用行為系統。

## Architecture: Hybrid Data Profile + Behavior Override (方案 C)

基礎用 `PetBehaviorProfile` 資料結構定義物理規則和基本參數，每種寵物透過 `PetBehaviorProvider` 協議 override 複雜行為。共用邏輯放在 protocol extension default 實作。

### Core Protocol

```swift
protocol PetBehaviorProvider {
    var profile: PetBehaviorProfile { get }
    func nextBehavior(physics: PetPhysicsState, personality: PetPersonality, elapsed: TimeInterval) -> PetAction
    func exitSequence(from position: CGPoint, screenBounds: CGRect) -> PetAnimationSequence
    func enterSequence(screenBounds: CGRect) -> PetAnimationSequence
    func chatBehavior(messageFrames: [CGRect], petPosition: CGPoint) -> ChatPetAction
    func modifyPhysics(_ state: inout PetPhysicsState, deltaTime: TimeInterval)
}
```

### PetBehaviorProfile

```swift
struct PetBehaviorProfile {
    let physicsMode: PetPhysicsMode
    let gravity: CGFloat
    let canClimbWalls: Bool
    let canHangCeiling: Bool
    let canPassThroughWalls: Bool
    let baseSpeed: CGFloat
    let movementStyle: MovementStyle  // .walk, .hop, .fly, .slither, .float, .bounce
    let idleDurationRange: ClosedRange<TimeInterval>
    let moveDurationRange: ClosedRange<TimeInterval>
    let uniqueActions: [PetAction]
    let exitStyle: PetExitStyle
    let enterStyle: PetEnterStyle
    let chatStyle: PetChatStyle
}
```

### PetPhysicsMode

```
.grounded   — 受重力，地面/牆壁（貓、狗、兔、熊）
.flying     — 無重力，可停棲（鳥、龍）
.floating   — 無重力，無碰撞，穿牆（幽靈）
.bouncing   — 受重力，彈跳（青蛙、史萊姆）
.crawling   — 低重力，可附著任何表面（章魚）
```

## Physics Rules Per Species

| 寵物 | physicsMode | gravity | 可爬牆 | 可掛天花板 | 可穿牆 | movementStyle | baseSpeed |
|------|------------|---------|--------|-----------|--------|--------------|-----------|
| 貓 | .grounded | 800 | ✅ | ✅ | ❌ | .walk | 70 |
| 狗 | .grounded | 800 | ❌ | ❌ | ❌ | .walk | 80 |
| 兔 | .grounded | 800 | ❌ | ❌ | ❌ | .hop | 75 |
| 鳥 | .flying | 0 | ❌ | ❌ | ❌ | .fly | 90 |
| 青蛙 | .bouncing | 800 | ✅ | ✅ | ❌ | .hop | 60 |
| 熊 | .grounded | 800 | ❌ | ❌ | ❌ | .walk | 45 |
| 龍 | .flying | 0 | ❌ | ❌ | ❌ | .fly | 100 |
| 章魚 | .crawling | 400 | ✅ | ✅ | ❌ | .slither | 50 |
| 幽靈 | .floating | 0 | ❌ | ❌ | ✅ | .float | 55 |
| 史萊姆 | .bouncing | 600 | ❌ | ❌ | ❌ | .bounce | 40 |

## Unique Actions Per Species (41 new actions)

### 貓
- `.scratch` — 磨爪
- `.stretch` — 伸懶腰
- `.groom` — 舔毛
- `.nap` — 打盹蜷縮

### 狗
- `.dig` — 挖洞
- `.fetchToy` — 叼玩具跑
- `.wagTail` — 搖尾巴
- `.scratchWall` — 抓牆

### 兔
- `.burrow` — 挖洞鑽入
- `.nibble` — 啃東西
- `.alertEars` — 豎耳警戒
- `.binky` — 開心跳躍扭身

### 鳥
- `.perch` — 停棲
- `.peck` — 啄食
- `.preen` — 整理羽毛
- `.dive` — 俯衝
- `.glide` — 滑翔

### 青蛙
- `.tongueSnap` — 吐舌抓蟲
- `.croak` — 鼓腮叫
- `.swim` — 游泳姿態
- `.stickyWall` — 黏牆

### 熊
- `.backScratch` — 靠牆抓癢
- `.standUp` — 站立
- `.pawSlam` — 拍地
- `.bigYawn` — 大哈欠

### 龍
- `.breathFire` — 噴火 + 粒子
- `.hover` — 盤旋
- `.wingSpread` — 展翅
- `.roar` — 咆哮

### 章魚
- `.inkSquirt` — 噴墨 + 粒子
- `.tentacleReach` — 伸觸手
- `.camouflage` — 變色淡化
- `.wallSuction` — 吸附牆面

### 幽靈
- `.phaseThrough` — 穿牆
- `.flicker` — 隱身閃現
- `.spook` — 驚嚇彈出
- `.vanish` — 完全隱身

### 史萊姆
- `.split` — 分裂成小塊
- `.melt` — 融化攤平
- `.absorb` — 吸收周圍
- `.wallStick` — 黏牆滑落

## Exit/Enter Animation System

### PetAnimationSequence

```swift
struct PetAnimationSequence {
    let steps: [PetAnimationStep]
}

struct PetAnimationStep {
    let action: PetAction
    let duration: TimeInterval
    let positionDelta: CGPoint?
    let scaleDelta: CGFloat?
    let opacityDelta: CGFloat?
    let particles: [PetParticle]?
}
```

### Exit/Enter Per Species

| 寵物 | 離開 | 回來 |
|------|------|------|
| 貓 | 走向畫面深處，scale 1.0→0.3，耗時 3s | 遠處小點出現，scale 0.3→1.0 走近 |
| 狗 | `.dig` 2s → 沉入地面底部 | 地面冒出土堆粒子 → 從下方彈出 |
| 兔 | `.burrow` 1.5s → 鑽入地面 | 地面震動 → 從洞口跳出 |
| 鳥 | `.glide` 飛向邊緣加速離開 | 從邊緣飛入減速停棲 |
| 青蛙 | 連續 3 跳越來越高跳出畫面 | 從畫面外跳入落地彈跳 |
| 熊 | `.walk` 慢慢走出側邊 4s | 從側邊慢慢走入 |
| 龍 | `.wingSpread` 1s → 往上加速飛出 | 從天空俯衝降落 |
| 章魚 | `.inkSquirt` 噴墨雲 → opacity 0 | 墨霧粒子出現 → opacity 漸入 |
| 幽靈 | `.flicker` 閃爍 3 次 → 漸出 | 半透明出現 → 實體化 |
| 史萊姆 | `.melt` 攤平 2s → 消失 | 地面水灘 → 逐漸凝聚 |

### Trigger Rules

- 自發離開：idle 超過 30-60s
- 自發回來：離開後 15-45s 隨機返回
- 離開期間不可互動，UI 顯示「○○ 出去散步了」
- personality 影響：independence 高 → 更常離開更久；energy 高 → 動畫更快

## Chat Room Interaction System

### ChatPetAction & ChatPetPosition

```swift
struct ChatPetAction {
    let targetMessageIndex: Int?
    let position: ChatPetPosition
    let action: PetAction
    let duration: TimeInterval
    let particles: [PetParticle]?
}

enum ChatPetPosition {
    case onTop(offset: CGFloat)
    case beside(side: HorizontalEdge)
    case stickedOn(side: Edge)
    case wrappedAround
    case behind
    case above(height: CGFloat)
    case between(upperIndex: Int)
    case leaningOn(side: HorizontalEdge)
    case coiled
    case dripping
}
```

### Chat Behavior Per Species

| 寵物 | 行為 | 位置 | 觸發 |
|------|------|------|------|
| 貓 | 跳上訊息（貓跳台），打盹/伸懶腰 | `.onTop` | 新訊息 / 隨機 |
| 狗 | 嗅聞訊息 / 咬角落 | `.beside` | 新訊息 |
| 兔 | 在訊息間彈跳 | `.between` | 持續 |
| 鳥 | 停棲訊息頂端 / 飛過 | `.onTop` / `.above` | 隨機 |
| 青蛙 | 黏在訊息泡泡側面 | `.stickedOn` | 跳到時 |
| 熊 | 靠在訊息旁打盹 | `.leaningOn` | 靜止時 |
| 龍 | 盤繞訊息 | `.coiled` | 隨機 |
| 章魚 | 觸手纏繞訊息 | `.wrappedAround` | 靠近時 |
| 幽靈 | 從訊息後方穿出 | `.behind` | 隨機 |
| 史萊姆 | 從訊息上方滴下 | `.dripping` | 隨機 |

### Chat Integration Rules

- 訊息座標：GeometryReader 收集可見訊息 frame
- 滾動跟隨：附著訊息時隨滾動移動
- 訊息消失：附著訊息滾出時跳到下一個可見訊息
- 互動頻率：新訊息到達 60% 觸發，靜止 10s 後隨機選擇
- 不干擾閱讀：z-order 在訊息之上，opacity 0.85，tap 穿透到訊息

## Integration with Existing System

### Modified Files

- `PetEngine.swift` — 新增 `behaviorProvider` 屬性，init 根據 body 建立 provider
- `PetPhysicsEngine.swift` — 從 provider.profile 讀取物理規則，呼叫 modifyPhysics
- `PetBehaviorController.swift` — nextBehavior 委託給 provider
- `FloatingPetView.swift` — 離開/回來動畫、景深效果、穿牆效果、chatMode
- `PetAction.swift` — 新增 41 個 action case
- `SpriteDataRegistry.swift` — 新增動作 sprite sheet 查詢，未實作的 fallback 到近似動作

### New Files

| 路徑 | 用途 |
|------|------|
| `Pet/Behavior/PetBehaviorProvider.swift` | 協議 + default extension + Profile |
| `Pet/Behavior/PetBehaviorProviderFactory.swift` | 工廠 |
| `Pet/Behavior/CatBehavior.swift` | 貓行為 |
| `Pet/Behavior/DogBehavior.swift` | 狗行為 |
| `Pet/Behavior/RabbitBehavior.swift` | 兔行為 |
| `Pet/Behavior/BirdBehavior.swift` | 鳥行為 |
| `Pet/Behavior/FrogBehavior.swift` | 青蛙行為 |
| `Pet/Behavior/BearBehavior.swift` | 熊行為 |
| `Pet/Behavior/DragonBehavior.swift` | 龍行為 |
| `Pet/Behavior/OctopusBehavior.swift` | 章魚行為 |
| `Pet/Behavior/GhostBehavior.swift` | 幽靈行為 |
| `Pet/Behavior/SlimeBehavior.swift` | 史萊姆行為 |
| `Pet/Model/PetExitStyle.swift` | 離開/回來列舉 |
| `Pet/Model/PetAnimationSequence.swift` | 動畫序列結構 |
| `Pet/Model/ChatPetAction.swift` | 聊天室互動結構 |

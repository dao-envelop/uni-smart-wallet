# Аудит безопасности: всё, что изменилось после аудита 2026-07-18 (v2.0.0 и post-release)

**Дата:** 2026-09-04
**Проект:** `uniswap-smart-wallet` (Envelop V2 / unisafe LP-менеджеры)
**Ревизия:** ветка `master`, коммит `359cefe`
**Фокус:** потеря средств / несанкционированный вывод / **компрометация оператора** (модель угроз
прежняя, см. §1).

> English version: [`AUDIT-REPORT.en.md`](./AUDIT-REPORT.en.md).

---

## 1. Что покрыто и почему

Последний аудит (`audits/2026-07-18`) смотрел коммит `84a36b2`. С тех пор в `src/` изменилось два блока,
и **ни один из них не проходил ревью**:

| Диапазон | Задачи | Что появилось |
|---|---|---|
| `84a36b2 → v2.0.0` | 031, 032, 033, 034, 035, 036, 039, 040, 041 | оракульный гейт операторских свопов (`_guardSwap`, `IPriceOracle.check → bool`), `ChainlinkPriceOracle` (+ L2 sequencer, heartbeat), фабрика с `keccak(initData)` в соли, отказ от zero-L add, `UniLens`, дескриптор |
| `v2.0.0 → 359cefe` | 042, 043, 044, 045, 047, 048, 051, 052 | `OpenVolatileLPManager` (хуки разрешены), `moveLiquidity` (кросс-пул в одном unlock), `FeesCollected` на пяти путях, `operatorList`/`operatorCount`, `MAX_POOLS 8 → 32`, `rangeOf` public, `UniLens.oracleStatus/stableRanges/operators` |

Аудитировался весь текущий `src/` (16 файлов, ~3.2 k строк), с упором на перечисленные изменения.

**Модель угроз (без изменений).** Внешний вызывающий не достаёт value-функции. Реальные акторы:
**(a) скомпрометированный оператор** (`onlyAuthorized`: `allocate`/`allocateFrom`/`reinvest`/`claimFees`,
Volatile `recenter`/`moveLiquidity`); (b) поведение токена; (c) ошибки учёта. Владелец, вредящий себе, —
не находка. Для `OpenVolatileLPManager` хук считается доверенным по конструкции (task_043) — находки там
только про полноту описания принятого риска.

## 2. Методология

1. Обновлены скилы аудитора (`ethskills` 1.1.0 → актуально, `uniswap-hooks` 1.6.0 → актуально, все шесть
   маркетплейсов обновлены); загружен мастер-индекс `evm-audit-skills` и чек-листы: general,
   precision-math, erc20, defi-amm (в т. ч. Dacian CLM), oracles (Chainlink/Cyfrin/Sigma Prime),
   access-control, erc721, dos; плюс `v4-security-foundations` (Uniswap).
2. Полное чтение `src/` и диффов обоих диапазонов; семантика v4 сверена по вендоренному
   `lib/v4-hooks-public/lib/v4-core`.
3. Единственный кандидат уровня HIGH **подтверждён исполняемым PoC** в Foundry
   (`test/Audit20260904SwaplessDrainPoC.t.sol`, 2 теста, оба зелёные = атака работает) и **сверен с
   публичными базами инцидентов** (§4, «Сверка»). Это сильнее, чем голосование верификаторов в прошлом
   отчёте: здесь есть числа.
4. Для рекомендованного фикса **измерена цена в байтах** (EIP-170 — главное ограничение проекта).
5. Базовая линия: `forge build --sizes` (Stable 24,098 / Volatile 24,355 / Open 24,295 B),
   `forge test` — 263 passed, 4 skipped (fork, нет `BASE_RPC`); с PoC — 265 passed.

## 3. Результат

| ID | Severity | Статус | Заголовок |
|---|---|---|---|
| **H-1** | **HIGH** | **ПОНИЖЕН, НЕ ЗАКРЫТ** (task_053; см. [fix-review/FIX-REVIEW.md](fix-review/FIX-REVIEW.md)) | Скомпрометированный оператор выводит principal **без единого свопа**: swapless `recenter`/`moveLiquidity` кладут ликвидность по искажённой spot-цене; `moveLiquidity` позволяет выбрать самый тонкий пул из конфига |
| M-1 | MEDIUM | Подтв. | Общий `ChainlinkPriceOracle` — единственный корень доверия операторской защиты для всех менеджеров; его владелец мгновенно и без границ отключает защиту (`maxDeviationBps ≤ 9999`, произвольный агрегатор) |
| L-1 | LOW | Подтв. | Утверждение «owed ≤ desired by construction» неверно на 1 wei (v4 округляет add вверх); swapless move/recenter полного объёма при нулевом idle ревертит |
| L-2 | LOW | Подтв. | `moveLiquidity` не делает пред-проверок, которые есть у `withdrawTo`/`recenter` (неизвестный salt → `UnknownPool(0)`, over-pull → паника v4) |
| L-3 | LOW | Подтв. | `ChainlinkPriceOracle`: нет проверки `minAnswer`/`maxAnswer` (circuit-breaker при flash-crash); одношаговый `Ownable` |
| L-4 | LOW | Подтв. | `OpenVolatileLPManager`: перечень принятых рисков неполон — нет `afterAddLiquidityReturnDelta` (хук снимает произвольную сумму с idle при каждом add) и знакового допущения в `_guardedSwap` |
| I-1 | INFO | — | Семантика `FeesCollected` изменилась (5 путей, gross): даунстрим не должен читать его как «доставлено на баланс» |
| I-2 | INFO | — | `operatorList` не ограничен; `_clearOperators` при трансфере NFT — самонанесённый gas-DoS |
| I-3 | INFO | — | Форк-тесты (4) пропускаются без `BASE_RPC`; новые пути (move, fee-events) без покрытия на живом v4 |

> **Статус на 2026-09-06.** Фикс (task_053) проверен отдельным аудитом —
> [`fix-review/FIX-REVIEW.md`](fix-review/FIX-REVIEW.md). H-1 **понижен, но не закрыт**: убыток за
> операцию упал с 44,5 % до 47 bps, однако граница действует на операцию, а не в сумме — 60 операций в
> одной транзакции выносят 24,84 % портфеля (R-2). На `OpenVolatileLPManager` атака воспроизводится
> полностью: хук двигает цену между гейтом и `modifyLiquidity` (R-1, HIGH). Всего 15 находок,
> исполняемые PoC — в [`fix-review/poc/`](fix-review/poc/).

**Вывод по компрометации оператора.** После task_031/032 оператор действительно не может провести
невыгодный **своп** внутри менеджера. Но task_031 записал предпосылку: «swapless operator ops … stay
unrestricted — L is sized from desired amounts, so owed ≤ desired and there is **no value-loss vector**».
Она неверна. Ограничение *количества* не ограничивает *цену*, по которой principal кладётся в пул: оператор
искажает spot-цену своим капиталом, кладёт principal по ней и торгует обратно через свежую
концентрированную ликвидность менеджера. PoC: **−22.4 %** портфеля за один `moveLiquidity`,
**−44.5 %** за один `recenter`; оракул не участвует вообще. Это тот же класс, что H-VOL-1, и та же
пред-условие (оператор скомпрометирован) — поэтому HIGH, не CRITICAL.

---

## 4. HIGH

### H-1 — Swapless-операции оператора кладут principal по искажённой spot-цене (sandwich на add)

**Severity: HIGH · ПОДТВЕРЖДЕНО исполняемым PoC.**
**Location:**
`src/VolatileLPManager.sol:264-287` (`_addLiquidityAt` — читает `getSlot0`, оракул не спрашивает),
`:298-346` (`_handleRecenter`, шаг 3 без гейта), `:371-398` (`moveLiquidity`/`_handleMove`),
`src/BaseLPManager.sol:351-359` (`_guardSwap` — вызывается только из своп-путей).
Задокументированная предпосылка: `tasks/task_031_operator_swap_safety.md:14`.

**Механизм.**
1. Оператор (или флеш-заём) сдвигает spot-цену **любого сконфигурированного пула** — своим капиталом,
   без участия менеджера. Стоимость — комиссии + slippage против *чужой* ликвидности пула; в тонком пуле
   это копейки.
2. Оператор вызывает `recenter` (или `moveLiquidity` из глубокого пула в этот тонкий) с
   `swapAmountIn == 0`, узким диапазоном у искажённой цены и `minLiquidity = 0`. Ни один из этих путей не
   заходит в `_guardSwap`: `_addLiquidityAt` сайзит L от `getSlot0` и кладёт.
3. Оператор торгует цену обратно. Ликвидность менеджера, сконцентрированная у искажённой цены,
   *покупает* накачанный токен по накачанной цене (или продаёт дешёвый — зависит от стороны). Разница
   уходит атакующему; менеджеру остаётся позиция вне диапазона в «неправильном» токене.
4. `moveLiquidity` (task_051) **расширяет радиус**: раньше `recenter` был заперт в пуле позиции (обычно
   глубоком), теперь principal можно перенести в самый тонкий пул из owner-fixed набора, где искажение
   дешевле всего. Комментарий в `moveLiquidity` («degradation of yield, not theft — nothing leaves the
   manager») верен буквально (токены не переводятся) и неверен экономически.

**PoC** (`test/Audit20260904SwaplessDrainPoC.t.sol`, оракул не задан, ни одного свопа менеджера):

| Тест | Сценарий | Потеря менеджера | Прибыль оператора |
|---|---|---|---|
| `test_H1_..._swaplessMoveIntoSkewedPool` | позиция 500/500 в глубоком пуле A (L=1e24); пул B тонкий (L=2e21); памп B до tick +6000 (+82 %); `moveLiquidity` всего в B, диапазон [5940, 6060]; дамп обратно до tick 0 | **22.41 %** (1000e18 → 775.8e18) | +223.6e18 |
| `test_H1_..._swaplessRecenterAtSkewedPrice` | позиция в B; памп; `recenter` в односторонний диапазон [5880, 5940] под ценой; дамп | **44.49 %** | +444.3e18 |

Прибыль ≈ потере: экстракция, а не «деградация». Доля ограничена глубиной пула и размером сдвига,
повторяема на каждой позиции — как у H-VOL-1.

**Почему это не принятый C-H1 и не закрытый H-VOL-1.** C-H1 (Stable) ограничен idle+fees; здесь —
principal. H-VOL-1 закрыт для *свопов*; здесь своп не нужен. Stable-продукт затронут в пределах C-H1
(`allocate`/`reinvest` оператора тоже кладут по spot без гейта, но только idle/fees).

**Сверка с базами уязвимостей.** Тот же паттерн, что:
- **Gamma Strategies, 2024-01-04, Arbitrum, ≈$4.6 M** — депозит в Hypervisor по манипулированной цене
  пула; порог отклонения был слишком широк ([Verichains](https://blog.verichains.io/p/gamma-protocol-exploit-analysis),
  [Neptune Mutual](https://neptunemutual.com/blog/how-was-gamma-protocol-exploited/)). У нас порога нет вовсе.
- **Beefy CLM, Cyfrin (critical)** — `setPositionWidth`/`unpause` разворачивали ликвидность по `slot0`
  без `onlyCalmPeriods` TWAP-проверки: «attacker … forcing the protocol's liquidity to be deployed into an
  unfavorable range», затем trade back ([Dacian, CLM Vulnerabilities](https://dacian.me/concentrated-liquidity-manager-vulnerabilities)).
- Чек-лист `evm-audit-defi-amm` → «Drain protocol via sandwich attack on owner functions missing TWAP
  check» и «Slippage enforced on intermediate operation, not final amount»; Solodit-категория
  «Sandwich / price manipulation» ([Cyfrin, Solodit checklist #11](https://www.cyfrin.io/blog/solodit-checklist-explained-11-sandwich-attacks)).
Отличие от инцидентов: у нас триггер — привилегированный оператор, а не любой пользователь, поэтому HIGH.

**Remediation (с измеренной ценой в байтах; исходники после замера откачены):**

| Вариант | Что делает | Δ Volatile | Δ Open | Вердикт |
|---|---|---|---|---|
| **A (рекомендуется)** | В `_addLiquidityAt` после `getSlot0` — `_guardSwap(byOwner, key, true, 0, 0)`; `byOwner` протянут в `_addLiquidityV`/`_addLiquidityAt`. Оракул трактует `amountIn == 0` как «проверь spot `getSlot0` пула против референса в обе стороны». Интерфейс `IPriceOracle` **не меняется**; сейчас `ChainlinkPriceOracle.check` на `amountIn == 0` возвращает `false` — т. е. на старом оракуле операторские add просто фейл-клозятся, пока не задеплоен новый | **+24 B** (24,379; запас 197) | +24 B (запас 257) | влезает |
| B | Новый метод `checkSpot(key, sqrtPriceX96)` в `IPriceOracle` + `_guardSpot` в базе | +235 B (24,590; **−14 B**) | +235 B (запас 46) | не влезает без трима |
| C | `recenter`/`moveLiquidity` → `onlyOwnerNFT` | ≈0 | ≈0 | закрывает вектор ценой продукта (нет быстрого recentering ботом) |

Для A нужна новая версия `ChainlinkPriceOracle` (spot-ветка: `sqrtP² / 2^192` против
`answerIn/answerOut` с учётом decimals, обе стороны в пределах `maxDeviationBps`) и тесты по образцу
`VolatileLPManagerOperatorSwapGuard.t.sol`. Остаточный риск после A — экстракция в пределах
`maxDeviationBps`, как и у своп-гейта. Клоны неапгрейдимы: фикс = новая имплементация в allowlist
фабрики + миграция; до этого владельцам с ботами-операторами стоит понимать, что операторская
экспозиция сейчас = principal, ограниченный глубиной пулов набора.

---

## 5. MEDIUM

### M-1 — Общий оракул: владелец оракула без границ и задержки отключает операторскую защиту всех менеджеров
**Location:** `src/oracle/ChainlinkPriceOracle.sol:85-98` (`setFeed`, `setMaxDeviationBps`),
`:111-115` (`_setMaxDeviation`: единственная граница — `< 10_000`).

Один экземпляр оракула (протокольный) прописывается во множество менеджеров через `setPriceOracle`.
Его `Ownable`-владелец может (а) поднять `maxDeviationBps` до 9999 — гейт становится формальностью,
(б) подменить агрегатор любой валюты на контракт с нужным ответом. Ни таймлока, ни верхней границы, ни
двухшаговой передачи владения. Компрометация «ключ оракула + ключ оператора» = дренаж principal во всех
менеджерах разом, при том что владельцы менеджеров считают операторов «безопасными». Дизайн осознанный
(протокол курирует), но это trust-model-факт, который нигде не проговорён для владельца менеджера.
**Рекомендация:** `Ownable2Step`; константная верхняя граница `maxDeviationBps` (напр. ≤ 1_000);
для `setFeed`/`setMaxDeviationBps` — таймлок или хотя бы отдельное событие + описание в `UniLens.oracleStatus`
как «доверие к владельцу оракула»; владельцу менеджера — возможность зафиксировать собственный оракул.

## 6. LOW

### L-1 — «owed ≤ desired by construction» неверно на 1 wei
**Location:** `src/VolatileLPManager.sol:259-262, 276`, `src/StableLPManager.sol:199-202, 216`.
`getLiquidityForAmounts` округляет L вниз, но v4 при add округляет owed **вверх** (`getAmount0Delta(…,
roundUp=true)`), так что owed может быть `desired + 1` на сторону. Наблюдено в первом прогоне PoC:
`moveLiquidity` всего освобождённого объёма при нулевом idle падает
`ERC20InsufficientBalance(mgr, 0, 1)`. Следствия: swapless move/recenter «всего» требует ≥1 wei idle на
каждую сторону; `allocateFrom` может ложно ревертнуть `UnexpectedStableSpend` на 1 wei чужого стейбла.
**Рекомендация:** поправить комментарии; в `_handleRecenter`/`_handleMove` сайзить от `freed - 1` или
ловить 1 wei из idle явно; в тестах — кейс «idle = 0».

### L-2 — `moveLiquidity` без пред-проверок, которые есть у соседей
**Location:** `src/VolatileLPManager.sol:371-383`. `withdrawTo` проверяет `UnknownPosition`/
`DeltaExceedsLiquidity`, `recenter` — `UnknownPosition`; `moveLiquidity` — только `liquidity == 0`.
Неизвестный `fromSalt` → `_indexOf(PoolId(0))` → `UnknownPool(0)`; over-pull → арифметическая паника
внутри v4/`_positions[..].liquidity -= liq`. Средства не страдают, но бот/UI получают нечитаемую
причину, и инвариант «внешний вход валидирует, unlock исполняет» нарушен. **Рекомендация:** те же две
проверки, что в `withdrawTo` (≈30 B).

### L-3 — `ChainlinkPriceOracle`: нет `minAnswer`/`maxAnswer`, одношаговый `Ownable`
**Location:** `src/oracle/ChainlinkPriceOracle.sol:148-162`. При flash-crash ниже `minAnswer` фид отдаёт
floor вместо реальной цены (Venus/Blizz — LUNA); оракул «поручится» за операторский своп по неверному
референсу в пределах отклонения. У большинства современных фидов границы отключены, но проверка
дёшева: читать `aggregator.minAnswer()/maxAnswer()` через `try` и считать ответ на границе «нет
референса». `Ownable2Step` — см. M-1.

### L-4 — `OpenVolatileLPManager`: перечень принятых рисков неполон
**Location:** `src/OpenVolatileLPManager.sol:27-47`, `src/VolatileLPManager.sol:222-228`.
В списке (1) remove-delta, (2) brick, (3) swap-delta. Нет: **(4)** `AFTER_ADD_LIQUIDITY_RETURNS_DELTA` —
`_addLiquidityAt` игнорирует `callerDelta`, а `_settleManaged` платит всё, что скажет PoolManager, т. е.
хук снимает произвольную сумму с idle при каждом add («owed ≤ desired» для этого продукта не действует);
**(5)** в `_guardedSwap` `uint256(uint128(-inDelta))` при положительном `inDelta` (хук-рибейт больше
входа) молча оборачивается в огромное число — full-fill guard проходит всегда. Оба — в рамках «хук
доверен», но владелец, выбирающий имплементацию, должен видеть их в том же списке.

## 7. INFO

- **I-1** `FeesCollected` теперь эмитится из `_skimFees` на всех пяти путях и всегда **gross** (до
  10 % скима). На reinvest/recenter/top-up комиссия компаундится, а не доставляется на баланс.
  Индексаторы (stablelp-ui история, mcp-lp) не должны трактовать событие как «claim на баланс»; поле
  «net» отсутствует — считать `× 0.9` или читать `ProtocolFeeTaken`.
- **I-2** `operatorList` без верхней границы; `_clearOperators` при трансфере NFT линейный. Только
  владелец может его раздуть — самонанесённый DoS трансфера; cap (напр. 16) стоил бы ~20 B.
- **I-3** 4 форк-теста скипаются без `BASE_RPC`; `moveLiquidity` и fee-events на живом v4 не гонялись.

## 8. Проверено и признано корректным (для истории)

- `_hooksAllowed()` — `pure`-предикат, константно сворачивается; Stable/Volatile байт-в-байт по размеру;
  без сеттера ([H-7]/[M-7] закрыты).
- Утверждение task_044 «ре-энтри через хук невозможен»: проверено — `PoolManager.unlock` во время
  колбэка → `AlreadyUnlocked`; `unlockCallback` за `NotPoolManager`; все value-входы `nonReentrant`;
  `_mint` без `onERC721Received`. Остаток — только read-only reentrancy view-функций (UI-уровень).
- `byOwner` в payload unlock’а доверен корректно: PoolManager вызывает колбэк только у `msg.sender` с
  теми же данными.
- `_skimFees(key, salt, fees)` — только событие, логика скима не изменилась; двойной вызов в
  recenter/reinvest защищён `(f0|f1) != 0`.
- `operatorList` splice / `_clearOperators` — согласованы; слот хранения тот же (`_operatorList` →
  `operatorList`), апгрейдов нет.
- `MAX_POOLS = 32`: все циклы ограничены конфигом владельца; `initialize` ~4.8 M gas; `_settleManaged`
  ≤ 64 валют.
- `moveLiquidity`: реестр консистентен, включая `add.salt == fromSalt` (полный pull + новый диапазон;
  частичный + `RangeMismatch`); `_settleManaged` один раз; `ZeroLiquidity` на нулевом pull.
- `LPManagerFactory` без изменений с v2.0.0; L-FAC-1 закрыт (`keccak(initData)` в соли).
- `ChainlinkPriceOracle._read`/`_sequencerUp`: staleness, `updatedAt` в будущем, `answer ≤ 0`,
  sequencer down/grace — корректно, fail-closed для оператора.
- Solidity 0.8.26 / cancun / PUSH0: целевые сети (Ethereum, Arbitrum, Base, Unichain) поддерживают.

## 9. Что дальше

1. Завести `tasks/task_053` на H-1 (вариант A + новая `ChainlinkPriceOracle` со spot-веткой + тесты
   по `VolatileLPManagerOperatorSwapGuard.t.sol`; PoC-тест из этого аудита должен начать **падать**
   с `OperatorSwapUnverified`).
2. M-1/L-3 — в тот же деплой оракула (`Ownable2Step`, cap на `maxDeviationBps`, `minAnswer/maxAnswer`).
3. L-1/L-2 — в ближайший релиз Volatile (≈40 B суммарно, запас после A — ~150 B).
4. L-4/I-1 — правки NatSpec и заметка для stablelp-ui / mcp-lp.

# task_053 — spot-гейт на операторские add: закрыть H-1 (swapless-дренаж principal)

**Репозиторий:** `uniswap-smart-wallet` · **Ветка:** `audit/2026-09-04` (поверх `5308a39`, там же лежат
отчёт и PoC)
**Закрывает:** `audits/2026-09-04/AUDIT-REPORT.md` — **H-1** (HIGH, PoC), **M-1** (MEDIUM), **L-3** (LOW)
**Опровергает предпосылку:** `tasks/task_031_operator_swap_safety.md:13-15`

## Зачем

После task_031/032 оператор не может провести невыгодный **своп** внутри менеджера. Но гейт
`_guardSwap` (`src/BaseLPManager.sol:351-359`) привязан к операции «своп», а не к свойству «операция
размещает principal по текущей цене». Add-путь `_addLiquidityAt` (`src/VolatileLPManager.sol:263-286`)
сайзит ликвидность из `getSlot0` (`:274`) и не спрашивает никакого референса.

Отсюда H-1: оператор накачивает spot **любого сконфигурированного пула** своим капиталом (или
flash-loan'ом), вызывает swapless `recenter`/`moveLiquidity` с узким диапазоном у искажённой цены, и
торгует обратно через свежую концентрированную ликвидность менеджера. PoC
(`test/Audit20260904SwaplessDrainPoC.t.sol`): **−22,4 %** портфеля за один `moveLiquidity`, **−44,5 %**
за один `recenter`; ни одного свопа менеджера, оракул не участвует вообще.

Три уточнения, которые определили состав задачи:

1. **Атака атомарна.** Накачка, операция менеджера и разворот укладываются в одну транзакцию
   оператора-контракта (три отдельных `unlock`, потому что `moveLiquidity` открывает свой; капитал на
   накачку берётся flash-loan'ом). Арбитражники в это окно не попадают, «пул восстановят до того, как
   оператор успеет» — не работает. Ограничений на оператора-контракт в менеджере нет.
2. **Ограничение количества ≠ ограничение цены.** `owed ≤ desired by construction` верно и бесполезно:
   оно не говорит ничего о том, по какой цене principal конвертируется в позицию. Убыток возникает не в
   момент add, а когда цена возвращается.
3. **Клиентские флоры не помогают по построению.** `minLiquidity` в `stablelp-ui`/MCP не ноль, а
   `est × (1 − 50 bps)` (`stablelp-ui/src/lib/planner/recenter.ts:94`), но `est` считается из **той же**
   цены пула и против диапазона, выведенного из **того же** тика — флор сравнивает наблюдение с самим
   собой и проходит при любом искажении, которое держится между чтением и включением. Параметр,
   посчитанный по цене пула, не может ограничить манипуляцию ценой пула. Референс нужен **on-chain, в
   момент исполнения**.

## Что делать — вариант A из отчёта

Отчёт мерил три варианта; A выбран:

| Вариант | Δ Volatile | Вердикт |
|---|---|---|
| **A** — `_guardSwap(byOwner, key, true, 0, 0)` в add-пути; оракул трактует `amountIn == 0` как spot-check | **+24 B** (24 379, запас 197) | **делаем** |
| B — новый `checkSpot(key, sqrtPriceX96)` в `IPriceOracle` + `_guardSpot` в базе | +235 B (**−14 B** за EIP-170) | не влезает и не даёт новой гарантии: та же проверка, только `slot0` читает менеджер, а не оракул. TOCTOU нет ни там, ни там — обе в одной транзакции |
| C — `recenter`/`moveLiquidity` → `onlyOwnerNFT` | ≈0 | убирает продукт (нет быстрого ре-центрирования ботом) и не закрывает владельческий путь |

### 1. `src/oracle/ChainlinkPriceOracle.sol` — новая версия контракта

Клоны неапгрейдимы, оракул — нет: деплоится новый экземпляр, менеджеры переключаются
`setPriceOracle`. Файл тот же, контракт тот же, ABI-поверхность сохраняется (см. п. 1.5).

**1.1 Spot-ветка.** `immutable IPoolManager POOL_MANAGER` (новый аргумент конструктора) +
`using StateLibrary`. В `check` (`:118-145`) вместо `amountIn == 0 ⇒ return false` (`:133`):

* `sqrtP = POOL_MANAGER.getSlot0(key.toId())`; `sqrtP == 0` ⇒ `return false` (менеджер fail-close'ит);
* цена пула: `mulDiv(sqrtP, sqrtP, Q96)` → `mulDiv(priceX96, WAD * 10**dec0, Q96 * 10**dec1)`.
  Формулу **не изобретать** — она уже есть и сверена с живыми пулами на четырёх сетях:
  `script/PriceDeviation.s.sol:109-112` (`_v4Price`). Двухшаговый split обязателен: `sqrtP² / 2^192`
  одним выражением переполняет uint256;
* референс: `mulDiv(a0, 10**fd1 * WAD, a1 * 10**fd0)` — `PriceDeviation.s.sol:115-125` (`_chainlinkPrice`);
* отклонение: `mulDiv(|pool − ref|, 10_000, ref)` (`:142-145`, `_absDiffBps`), **в обе стороны**,
  против `maxSpotDeviationBps`. Выход ⇒ `revert SpotPriceOutOfBounds(poolPrice, refPrice)`; внутри ⇒
  `return true`;
* `zeroForOne` в spot-ветке не используется (проверка симметрична) — сказать это в natspec;
* порядок проверок сохранить: `_sequencerUp()` → `_read` обеих сторон → ветвление.

**Сентинель `amountIn == 0` однозначен**, проверено по всем вызовам: `_guardedSwap` вызывается только
при `swapAmountIn > 0` (`VolatileLPManager.sol:204,320`; `StableLPManager.sol:191,292`), а full-fill
guard (`VolatileLPManager.sol:225`) гарантирует `|inDelta| ≥ amountIn > 0`. Своп-путь в spot-ветку не
попадает. Единственная аномалия — L-4 (положительный `inDelta` от хук-рибейта в Open) — даёт максимум
uint256, а не ноль.

**1.2 Отдельный `maxSpotDeviationBps`, дефолт 50 bps.** Не переиспользовать 100 bps от свопа:
там допуск подбирался как `базис + fee пула + буфер`, потому что сравнивается **выход после
комиссии**. У spot-цены комиссии в допуске нет. Базис по снимку 2026-07-20
(`tasks/oracle_maxdeviation_analysis.md`): 0–3 bps на стейбл-парах, до ~33 bps на ETH/WBTC. Именно
`d − fee` решает, выгодна ли атака: при 50 bps на 0,30 %-пуле остаётся ~0,2 %, на 1 %-пуле атака
убыточна. Новое storage-поле + сеттер + событие `MaxSpotDeviationSet`.

Перед деплоем — **перепрогнать** `script/PriceDeviation.s.sol` по четырём сетям (RPC и команды в
`tasks/oracle_maxdeviation_analysis.md`) и взять высокий перцентиль, а не один снимок.

**1.3 M-1 — границы владельца оракула.** Сегодня владелец одного протокольного оракула, прописанного во
множество менеджеров, мгновенно и без задержки снимает защиту всех: `_setMaxDeviation` проверяет
только `bps < 10_000` (`:112`), `setFeed` принимает любой агрегатор.

* `Ownable` → `Ownable2Step` (`:31,78`). `owner()` сохраняется, поэтому
  `script/SetOracleFeeds.s.sol:61-62` не ломается; ручная передача владения становится двухшаговой —
  отметить в `script/README.md`;
* константный потолок `MAX_DEVIATION_CAP = 1_000` (1 %) — проверять **в обоих** сеттерах допусков
  вместо `< 10_000`.

**1.4 L-3 — minAnswer/maxAnswer.** При flash-crash ниже `minAnswer` фид отдаёт floor вместо реальной
цены (Venus/Blizz на LUNA), и оракул поручится за операцию по неверному референсу.

* в `setFeed` (`:85-93`), рядом с уже существующим кэшированием `aggregator.decimals()` (`:89`),
  прочитать границы через `try` (proxy → `aggregator()` → `minAnswer()`/`maxAnswer()`) и закэшировать;
  недоступны ⇒ нули = «границ нет»;
* в `_read` (`:148-162`): ответ на границе ⇒ `ok = false` ⇒ для оператора fail-closed;
* `Feed` (`:36-41`) занимает ровно один слот и границы туда не влезают — **отдельный mapping**.
  Саму `feeds` и её 4-tuple форму не трогать (см. ниже).

**1.5 ABI-совместимость — жёсткое требование.** `UniLens.oracleStatus` (`src/UniLens.sol:200-234`)
пробует оракул через `IChainlinkOracleView`, и **`maxDeviationBps()` — это детектор `isChainlinkLike`**
(`:214`): исчезнет — лензa отрапортует оракул как не-Chainlink и обнулит всё остальное, фронт покажет
«оракул не настроен». Сохранить без изменений: `maxDeviationBps()`, `sequencerUptimeFeed()`,
`sequencerGracePeriod()`, `feeds(Currency) → (aggregator, heartbeat, feedDecimals, tokenDecimals)`
(4-tuple завязан ещё и на `SetOracleFeeds.applyFeeds`, `script/SetOracleFeeds.s.sol:85`).
`IAggregatorV3` (`ChainlinkPriceOracle.sol:11-17`) импортируется из `script/PriceDeviation.s.sol:13` —
не переименовывать и не переносить.

`src/interfaces/IPriceOracle.sol` **не меняется**: правится только natspec — `amountIn == 0` означает
spot-check.

### 2. Менеджеры — протянуть `byOwner` в add-путь

`byOwner` уже доезжает до `_allocateLegV` и `_handleRecenter`; недостающее звено — ровно последний шаг.

**`src/VolatileLPManager.sol`:**

* `_allocateLegV(leg, byOwner)` (`:201`) → `_addLiquidityV(leg, key)` (`:234`) → `_addLiquidityAt(…)`
  (`:263`): добавить параметр `bool byOwner` обеим;
* `_handleRecenter` (`:298`) → `_addLiquidityAt` (`:324`): передать;
* в `_addLiquidityAt` сразу после `getSlot0` (`:274`) — `_guardSwap(byOwner, key, true, 0, 0)`;
* `_handleMove` (`:390-396`) идёт через `_allocateLegV` — покрывается сам;
* комментарий `:262` предупреждает «kept in its own frame — the stack is tight without via-ir»: лишний
  параметр может задеть stack-too-deep, при необходимости обернуть тело в блок.

**`src/StableLPManager.sol`** — то же (C-H1: операторские `allocate`/`reinvest` тоже кладут по spot,
пусть и только idle+fees; делаем единообразно, запас 478 B позволяет):

* `_allocateLeg(leg, byOwner)` (`:182`) → `_addLiquidity(…)` (`:203-238`, `getSlot0` на `:213`);
* `_handleReinvest` (`:274`) → `_addLiquidity` (`:303`);
* обе функции `virtual` — менять сигнатуру с оглядкой на переопределения.

**`src/OpenVolatileLPManager.sol`** правок не требует (переопределяет только `_hooksAllowed`,
`ORACLE_TYPE`, `symbol`, `_productName`, `_defaultName`), но это **второй независимый бюджет EIP-170**.

**Комментарии-предпосылки поправить** — сейчас они утверждают ровно то, что опровергнуто:
`VolatileLPManager.sol:262` («owed ≤ desired … no separate owed-cap is needed»), `:25`, `:48`,
`StableLPManager.sol:23` и особенно natspec `moveLiquidity` `:371-383` («degradation of yield, not
theft — nothing leaves the manager»: верно буквально, неверно экономически).

### 3. Размеры (EIP-170) — гейт задачи

База на `audit/2026-09-04` (замерено `forge build --sizes`):

| Контракт | До | После | Δ |
|---|---|---|---|
| StableLPManager | 24 098 (478 B) | — | — |
| VolatileLPManager | 24 355 (221 B) | — | — |
| OpenVolatileLPManager | 24 295 (281 B) | — | — |
| ChainlinkPriceOracle | 3 465 | — | — |

Ожидание по замеру аудита: +24 B на Volatile/Open (запас 197 / 257 B). Оракул не лимитирован.
Заполнить колонку «После» фактическими числами. Если не влезает — перечислить кандидатов на трим
отдельным списком, а не «оптимизировать по ходу».

## Тесты

**Ломаются намеренно** (утверждают ровно то поведение, которое убирает H-1) — инвертировать:

* `test/VolatileLPManagerOperatorSwapGuard.t.sol:185-191` `test_operatorSwaplessRecenter_noOracle_succeeds`
  и `:193-197` `..._swaplessAllocate_noOracle_succeeds` ⇒ теперь `OperatorSwapGuardRequired`;
* `test/StableLPManagerOperatorSwapGuard.t.sol:159` (swapless allocate allowed) ⇒ то же.

**`test/Audit20260904SwaplessDrainPoC.t.sol` не удалять** — переписать ожидания на `vm.expectRevert`
(`OperatorSwapUnverified`: оракул в PoC не задан) и оставить как регрессию сценария.

**Ломаются механически** (новый аргумент конструктора оракула): `test/ChainlinkPriceOracle.t.sol:76`,
`test/UniLensOperatorsOracle.t.sol:149,188`, `test/SetOracleFeeds.t.sol:30`,
`test/DeployStableLP.t.sol:253,282-285`, `test/GasCompareVolatile.fork.t.sol:394-397`.

**Новое:**

* `test/ChainlinkPriceOracleSpot.t.sol` — существующий oracle-suite работает на **фиктивных адресах
  валют без пула** (`ChainlinkPriceOracle.t.sol:71-81`), а spot-ветке нужен настоящий `PoolManager` с
  инициализированным пулом; отдельный файл чище, чем ломать старый. Кейсы: цена в коридоре / ровно на
  границе ±d / за коридором в обе стороны / неинициализированный пул / stale-фид / секвенсер в grace /
  пара с разными decimals (6 vs 18). `MockAggregator`/`MockSequencer` импортировать из
  `ChainlinkPriceOracle.t.sol:12-55` — так уже делают `UniLensOperatorsOracle.t.sol:8` и
  `SetOracleFeeds.t.sol:7`;
* `MockPriceOracle` (`test/helpers/Mocks.sol:65-84`) **игнорирует аргументы**, поэтому все тесты в
  режиме `Mode.Pass` молча пропустят новый вызов с `amountIn == 0` и «потерю» гейта при рефакторинге
  никто не заметит. Добавить счётчик/режим, фиксирующий, что spot-проверка действительно была вызвана
  на add-пути, и утверждать это в тестах allocate/recenter/move;
* сквозной сценарий на **настоящем** оракуле: накачанный пул ⇒ операторский `recenter` ревертит
  `SpotPriceOutOfBounds`; тот же `recenter` от владельца проходит (`byOwner ⇒ return`);
* M-1/L-3: `InvalidBps` при 1 001 на обоих сеттерах; двухшаговая передача владения; ответ на
  `minAnswer`/`maxAnswer` ⇒ `ok = false` ⇒ операторский путь fail-closed.

## Деплой

Задача **входит в прогон `script/RUNBOOK-2026-09-05.md`** (042/043/051/052), а не едет отдельно: иначе
имплементации редеплоятся дважды за несколько дней, а менеджеры, созданные между прогонами, несут H-1
навсегда — клоны неапгрейдимы.

* `script/DeployStableLP.s.sol`: в `OracleParams` (`:63-67`) новое поле `maxSpotDeviationBps`;
  конструктор (`:195-197`) получает `c.poolManager` (уже читается, `:273`) и новый порог; `_readOracle`
  (`:309-319`) — ключ `oracleMaxSpotDeviationBps`, дефолт 50;
* `script/chain_params.json`: `deploy.oracle` → `true` на всех пяти сетях (сейчас `false` на 1 и 130) +
  новый ключ;
* `script/RUNBOOK-2026-09-05.md`: `ChainlinkPriceOracle` переезжает из «не деплоим» в «деплоим»,
  добавляется шаг `setPriceOracle` на существующих менеджерах. **Порядок обязателен:** оракул →
  `SetOracleFeeds` → `setPriceOracle` → новые имплементации. В обратном порядке новые имплементации
  на старом оракуле fail-close'ят все операторские add (`check` при `amountIn == 0` вернёт `false`);
* `script/SetOracleFeeds.s.sol` — перепрогнать на новый адрес оракула.

## Что осталось снаружи этой задачи

* **Владельческий путь.** `_guardSwap` при `byOwner` возвращается сразу, поэтому владелец, нажавший
  Recenter на искажённом графике, не защищён. Решение владельца: принятый риск того же порядка, что
  «отправить актив на случайный адрес». Не закрываем.
* **Остаточный риск после фикса** — экстракция в пределах `maxSpotDeviationBps − fee пула` за операцию,
  повторяемо. Тот же класс, что уже принят для свопов после task_031. Полностью вектор снимает только
  вариант C.
* **Выбор диапазона и пула** оператором не ограничивается (ширина, односторонность, самый тонкий пул из
  набора). При ограниченной цене это управляет долей principal внутри коридора, а не самим коридором;
  второй слой (cap на ширину и на смещение центра от референса) — отдельная задача, если понадобится.
* **L-1** (`owed ≤ desired` врёт на 1 wei), **L-2** (`moveLiquidity` без пред-проверок соседей),
  **L-4** (неполный список принятых рисков в Open), **I-2** (cap на `operatorList`) — отдельными
  задачами.
* **Фронт и MCP** — задача в `stablelp-ui`: `npm run sync-abi` + `npm run sync-deployments`;
  `src/components/manager/OracleSection.tsx:32-34` (четвёртое чтение `maxSpotDeviationBps`);
  `src/lib/errors.ts:8-11` (текст для `SpotPriceOutOfBounds`, иначе общий фолбэк);
  `mcp/reads.ts:87-111` (`oracleStatus` — новое поле).
* **Существующие клоны** новую имплементацию не получат (EIP-1167). Им достаётся только
  `setPriceOracle` на новый оракул; сам add-гейт появится лишь у менеджеров, созданных после деплоя.

## Verification

```bash
cd uniswap-smart-wallet
forge fmt --check
forge build --sizes            # Stable / Volatile / Open < 24 576 B
forge test -vvv
forge test --match-path 'test/ChainlinkPriceOracleSpot.t.sol' -vvv
forge test --match-path 'test/*OperatorSwapGuard.t.sol' -vvv
forge test --match-path 'test/Audit20260904SwaplessDrainPoC.t.sol' -vvv   # обе H-1 ревертят
forge test --match-path 'test/UniLensOperatorsOracle.t.sol' -vvv          # oracleStatus не деградировал

# порог перед деплоем (read-only; RPC по сетям — tasks/oracle_maxdeviation_analysis.md)
POOLS_CONFIG=script/price_pools/8453.json forge script script/PriceDeviation.s.sol --sig "run()" \
  --rpc-url https://mainnet.base.org
```

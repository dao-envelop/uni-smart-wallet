# task_058 — `moveLiquidity` с пресвопом в другом (мостовом) пуле

**Репозиторий:** `uniswap-smart-wallet` · **Ветка:** `task/058-move-bridge-swap`
(от `task/057-oracle-at-init`; релиз v2.2.0) · **Продукты:** Volatile, Open

## Симптом

`moveLiquidity(fromSalt, liquidity, add)` (task_051) освобождает позицию и кладёт деньги в другой пул
за один `unlock`, но ребалансировать умеет только **внутри пула назначения** (`add` — обычная
allocate-нога со своим пресвопом). Если у источника и назначения нет общей валюты — например, ETH/ARB →
USDC/USDT, — назначению нечем платить: освобождены ETH и ARB, а нужны USDC и USDT. Переезд в один вызов
невозможен; MCP-оператор поэтому отказывает в таком маршруте (`move_no_shared_currency` в
`stablelp-ui/mcp/write.ts`), а оператору остаются две транзакции с окном простоя капитала
между ними.

Доказательство — `test_noBridge_sameDestinationFails`: тот же переезд E/A → U/T без моста падает на
расчёте (`ERC20InsufficientBalance` при `settle` валюты U, которой у менеджера нет).

## Причина

Свопа «между» пулами в операции не было: единственный своп — пресвоп ноги `add`, а он идёт в пуле
`add.poolId`. В task_051 это было сознательное ограничение (массивы свопов `RebalanceSwap[]` не влезали
в EIP-170). После task_056 место есть.

## Что сделано

**Новая перегрузка**, старая сигнатура сохранена дословно (требование владельца — совместимость
фронта, MCP, insight и индексатора):

```solidity
struct BridgeSwap {
    PoolId poolId;      // сконфигурированный пул (иначе UnknownPool)
    bool zeroForOne;
    uint256 amountIn;   // exactIn; 0 = без моста
    uint160 priceLimit;
    uint256 minOut;
}
function moveLiquidity(bytes32 fromSalt, uint128 liquidity, VolatileAllocLeg calldata add) external;                       // как было
function moveLiquidity(bytes32 fromSalt, uint128 liquidity, VolatileAllocLeg calldata add, BridgeSwap calldata bridge) external; // новое
```

- Обе внешние функции входят в один `_moveLiquidity` → один `OP_MOVE`, один `_handleMove`, одно событие
  `LiquidityMoved` (без изменений). Старая форма = мост с нулевым `BridgeSwap` (`amountIn == 0` ⇒ своп
  пропускается, `poolId` даже не ищется).
- Порядок в `_handleMove`: `ZeroLiquidity`-проверка → `_pullLiquidity` → **мост**
  `_guardedSwap(pools[_indexOf(bridge.poolId)].key, …)` → `_allocateLegV(add)` (со своим пресвопом) →
  один `_settleManaged`.
- Мост — **только сконфигурированный пул** (`_indexOf`): settlement по-прежнему трогает только валюты
  менеджера, политика хуков Open не меняется (хукнутый пул может быть мостом у Open ровно потому, что
  владелец сам включил его при `initialize`; у Volatile такого пула в наборе быть не может). Single-hop.
- Гарды моста — те же, что у любого свопа продукта (`_guardedSwap`): full fill (`SwapSlippage(bridgePool)`),
  `minOut` (`SwapMinOut(bridgePool)`), `priceLimit`, и для оператора оракул fail-closed: без оракула
  `OperatorSwapGuardRequired`, без свежей цены `OperatorSwapUnverified(bridgePool)`, отклонение — revert
  оракула. Оракул спрашивается о ключе **мостового** пула (`checkOp(bridgeKey, …)`): оператору нужны
  USD-фиды обеих его валют. Владелец свободен, как везде.
- Модификаторы `nonReentrant` / `fixEtherBalance` перенесены с внешних функций на общий `_moveLiquidity`:
  модификатор инлайнится на каждое использование, вторая копия пары стоила 44 B.

Что операция по-прежнему **не** обещает: оператор может оставить часть освобождённого капитала idle
(в тесте ARB остаётся на балансе) — это недополученная доходность, а не утечка: ничего не покидает
менеджер.

## ABI

| | Селектор |
|---|---|
| `moveLiquidity(bytes32,uint128,(bytes32,bytes32,int24,int24,bool,uint256,uint160,uint256,uint256,uint256,uint128))` | `0xf959740c` — **без изменений** |
| `moveLiquidity(bytes32,uint128,(…VolatileAllocLeg…),(bytes32,bool,uint256,uint160,uint256))` | `0x6b154b41` — **новый** |

Ошибки и события не добавлялись. Внутренний payload `OP_MOVE` стал длиннее на 5 слов — снаружи не
виден.

## Размеры (EIP-170)

| Контракт | До (task_057) | Мост в обработчике | + перегрузка | Модификаторы в общий internal | Итог |
|---|---|---|---|---|---|
| StableLPManager | 22 410 | — | — | — | 22 410 (**2 166** своб.) |
| VolatileLPManager | 23 301 | 23 715 (+414) | 24 008 (+293) | 23 964 (−44) | 23 964 (**612** своб.) |
| OpenVolatileLPManager | 23 363 | 23 777 (+414) | 24 070 (+293) | 24 026 (−44) | 24 026 (**550** своб.) |

Итого +663 B. Старая сигнатура влезает с запасом — жертвовать ею не понадобилось.

Газ старой формы (`test_gas_moveLiquidity`): 815 830 → 816 798 тест-газа (+~1 k: payload на 5 слов
длиннее).

## Тесты

`test/VolatileLPManagerMove.t.sol` — новый контракт `VolatileLPManagerMoveBridgeTest` (14), сценарий из
`test/CrossPoolUnlock.t.sol` (`test_moveLiquidityAcrossPairs_withIntermediateSwap_oneUnlock`), но через
менеджер: четыре токена E/A/U/T, источник E/A, мост E/U, назначение U/T.

- оператор переезжает между парами без общей валюты; источник закрыт, назначение открыто в U/T, A
  остаётся idle; без моста тот же переезд падает;
- владелец — без оракула; событие `LiquidityMoved` прежнее;
- оператор без оракула → `OperatorSwapGuardRequired`; оракул не может поручиться →
  `OperatorSwapUnverified(` **мостовой** `poolId)`; отклонение → revert оракула;
- `minOut` → `SwapMinOut(bridge)`; частичное исполнение → `SwapSlippage(bridge)`; неизвестный пул →
  `UnknownPool`; `amountIn == 0` = старая форма (`poolId` игнорируется); посторонний → `NotAuthorized`;
- оба селектора закреплены;
- Open: мост через хукнутый пул из набора проходит.

Все 18 старых тестов `moveLiquidity` (трёхаргументная форма) проходят без правок.

Прогон: `forge fmt --check && forge build --sizes && forge test -vvv` — 364 passed, 0 failed,
4 skipped. Форк-тесты (Arbitrum, мост через боевой оракул) не прогонялись: в окружении нет
`ARBITRUM_RPC`/`BASE_RPC`, а форк-сценария под мост в репо пока нет — добавить вместе с деплоем.

## Фронт и деплой

- **stablelp-ui:** `npm run sync-abi` (перегрузка: в viem/wagmi вызывать по полной сигнатуре или по
  числу аргументов); планировщик `src/lib/planner/move.ts` — маршрут через мост-пул (пул из набора
  менеджера, у которого одна валюта общая с источником, другая — с назначением); `useSupportsMove`
  должен различать имплементации (у v2.1.0 перегрузки нет — вызов с 4 аргументами там ревертится:
  неизвестный селектор, `fallback` у менеджеров нет).
- **MCP** `propose_move` / `execute_move` (`mcp/write.ts`): снять `move_no_shared_currency` для
  менеджеров на новых имплементациях, строить мост; docs скила (`references/tools.md`, `errors.md`); **insight** `suggestMove` — предлагать мостовые
  маршруты. Оператору нужен оракул с USD-фидами обеих валют мостового пула (`SetOracleFeeds.s.sol`).
- **Индексатор/граббер:** событие то же (`LiquidityMoved`), своп виден в логах v4 `Swap` мостового пула.
- **Деплой:** новые имплементации Volatile/Open (+ Stable из task_056/057) и allowlist фабрики.
  Существующие менеджеры мост не получат (клоны неапгрейдимы).

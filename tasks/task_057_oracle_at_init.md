# task_057 — оракул при создании менеджера

**Репозиторий:** `uniswap-smart-wallet` · **Ветка:** `task/057-oracle-at-init`
(от `task/056-eip170-headroom`; релиз v2.2.0)

## Симптом

Новый менеджер рождается **без оракула**. `priceOracle` нет в `InitParams`, фабрика его не ставит
(так прямо и записано в `script/RUNBOOK-2026-09-05.md`). Пока владелец отдельной транзакцией не вызовет
`setPriceOracle`, любой операторский своп и любое операторское добавление ликвидности падают
`OperatorSwapGuardRequired` (fail-closed, task_031/053). Для пользователя это выглядит так: создал
менеджер, подключил бота — бот ничего не может, причина неочевидна, нужна вторая подпись.

Дескриптор `tokenURI` при этом с самого начала ставится полем `InitParams.descriptor` — оракул
просто не сделали так же.

## Решение владельца (10-19)

Оракул — **полем `InitParams`**, UI подставляет оракул сети (как дескриптор). Ноль — без оракула
(поведение прежнее). Апгрейд/замена/сброс — `setPriceOracle`, как и было.

## Что сделано

- `address oracle` в обоих `InitParams` — сразу после `descriptor`:
  - Stable: `(owner, name, descriptor, oracle, StablePoolInit[] pools)`;
  - Volatile (и Open, он наследует): `(owner, name, descriptor, oracle, PoolKey[] pools)`.
- `_finishInit(owner, poolCount, descriptor, oracle)`: ненулевой оракул ставится через новый общий
  `_setPriceOracle` — тот же, что зовёт `setPriceOracle`. Значит, запись и событие `PriceOracleSet` в
  одном месте, и индексатор видит оракул, заданный при рождении, точно так же, как заданный позже.
  При нуле событие не эмитится (ничего не установлено).
- `script/CreateManager.s.sol`: оракул по умолчанию — `.oracle` из `deployments/<chainId>.json`;
  ключ `"oracle"` в конфиге менеджера переопределяет (нулевой адрес — создать без оракула). Логирует
  адрес оракула. Дескриптор и оракул передаются во внутренние билдеры парой `address[2]` (скрипт без
  via-ir, стек тесный).
- `script/DeployStableLP.s.sol` не менялся: `InitParams` он не строит, `.oracle` уже пишет в
  deployments. `script/probe/probe_deployment.mjs` селекторы берёт из артефактов сборки — списка для
  правки там нет.
- Все тесты, собирающие `InitParams` (26 литералов в 23 файлах, включая хелпер `StableLPTestBase`), получили
  `oracle: address(0)` — поведение у них прежнее.

## ABI

| Функция | Было | Стало |
|---|---|---|
| Stable `initialize((address,bytes32,address,((address,address,uint24,int24,address),int24,int24)[]))` | `0xa1a3ea51` | `initialize((address,bytes32,address,address,(…)[]))` → **`0xb3330fb3`** |
| Volatile/Open `initialize((address,bytes32,address,(address,address,uint24,int24,address)[]))` | `0xf53b1c5d` | `initialize((address,bytes32,address,address,(…)[]))` → **`0x65e9e244`** |

`initData` фабрики меняется, а с ним и детерминированный адрес клона (`predictManagerAddress` хэширует
`initData`). Других изменений ABI нет; `PriceOracleSet` прежний.

## Размеры (EIP-170)

| Контракт | До (task_056) | После | Δ |
|---|---|---|---|
| StableLPManager | 22 385 (2 191 своб.) | 22 410 (**2 166**) | +25 |
| VolatileLPManager | 23 276 (1 300) | 23 301 (**1 275**) | +25 |
| OpenVolatileLPManager | 23 338 (1 238) | 23 363 (**1 213**) | +25 |

## Тесты

`test/Task057OracleAtInit.t.sol` (7): Stable/Volatile/Open с оракулом — `priceOracle` выставлен, ровно
одно `PriceOracleSet` при рождении; с нулём — оракула нет и события нет; оператор с оракулом из init
делает `allocate` с пресвопом сразу, без `setPriceOracle`; без оракула — `OperatorSwapGuardRequired`;
владелец меняет и сбрасывает, посторонний — нет; селекторы `initialize` закреплены строками сигнатур.

Прогон: `forge fmt --check && forge build --sizes && forge test -vvv` — 350 passed, 0 failed,
4 skipped (форк-тесты без RPC).

## Фронт и деплой

- **stablelp-ui:** `npm run sync-abi` после деплоя; `initData.ts` / `useCreateManager.ts` — новое поле
  `oracle` в обоих `InitParams` (подставлять `addrs.oracle` сети, ноль если оракула в сети нет). Старые
  имплементации (v2.1.0) это поле **не принимают** — пока фабрика держит в allowlist и старые, и новые
  имплементации, кодировать `initData` по версии выбранной имплементации.
- **MCP / insight:** если где-то собирается `initialize` — то же; на чтение (`priceOracle()`) не влияет.
- **Деплой:** новые имплементации Stable/Volatile/Open + allowlist фабрики. Существующие менеджеры не
  меняются (клоны неапгрейдимы), им оракул по-прежнему ставит владелец через `setPriceOracle`.

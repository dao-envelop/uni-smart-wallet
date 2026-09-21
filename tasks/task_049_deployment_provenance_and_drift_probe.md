# task_049 — Записывать, из какого коммита собран задеплоенный стек, и сверять его с `master`

**Статус:** done (2026-09-21, в master) · **Ветка:** `task/049-deployment-provenance`
**Находка:** `qa-workspace/quality/findings/2026-09-01-deployed-stack-lags-master-by-two-tasks.md`
**Severity:** S3 (домен B — on-chain правда)

## Симптом

На всех пяти сетях живёт сборка релиза **v2.0.0** (23 июля). В `master` с тех пор легли две
контрактные задачи, которых на цепи нет ни одной:

* **task_042** (`88523bf`, 29 июля) — перечисление операторов on-chain (`operatorCount` /
  `operatorList`) и три новых чтения `UniLens` (`operators`, `oracleStatus`, `stableRanges`);
* **task_043** (`bb04fd6`, 30 июля) — `OpenVolatileLPManager`, `ORACLE_TYPE 3002`.

34 дня. Хуже самого разрыва то, что **увидеть его нечем**: `deployments/<chainId>.json` не хранит
коммита сборки, `CHANGELOG [Unreleased]` пуст, CI на цепь не ходит.

## Доказательство

Селектор ищется в рантайме `eth_getCode` и подтверждается живым вызовом (Arbitrum;
`impl 0x7f373092…C4a2`, `volatileImpl 0xa373FBAc…995b`, `lens 0x205549BC…F5B8`):

```
impl         operatorCount()                  ABSENT
impl         operatorList(uint256)            ABSENT
volatileImpl operatorCount()                  ABSENT
volatileImpl operatorList(uint256)            ABSENT
lens         oracleStatus(address)            ABSENT
lens         stableRanges(address)            ABSENT
lens         operators(address)               ABSENT
lens         managerFull(address,address[])   PRESENT
lens         managerConfig(address,address[]) PRESENT
lens         positions(address)               PRESENT

lens.oracleStatus(0x60723973…264b) -> execution reverted
mgr.operatorList(0)                -> execution reverted
mgr.operators(0xD5228C94…05d2)     -> 0x…01   (старый маппинг жив; отсутствует перечисление)
```

Сборка везде одна — длины рантайма совпадают до байта на 1 / 130 / 8453 / 42161 / 1301:
`impl` 23 911, `volatileImpl` 23 630, `lens` 11 620, `descriptor` 18 821.

`OpenVolatileLPManager` не задеплоен нигде: `grep -l openVolatile deployments/*.json` пуст, а в
аллоулисте каждой фабрики ровно два `ImplementationSet`, оба про impl из `deployments/*.json`.

Провенанса нет:

```
$ cat deployments/42161.json
{ "chainId": 42161, "descriptor": …, "factory": …, "feeRedeemer": …, "fromBlock": 486143228,
  "impl": …, "lens": …, "name": "arbitrum-one", "oracle": …, "poolManager": …, "volatileImpl": … }

$ sed -n '/## \[Unreleased\]/,/## \[2.0.0\]/p' CHANGELOG.md
## [Unreleased]

## [2.0.0] - 2026-07-23
```

## Корень (гипотеза)

Деплой — ручной `forge script … --broadcast`, а его результат — четыре адреса в JSON. Нигде не
записано, **из какого коммита** собрано то, что по этим адресам лежит, поэтому пропущенный деплой не
оставляет следа и не выглядит ошибкой. Подтверждение гипотезы — часть задачи: если после появления
провенанса и сверки расхождения перестанут копиться незамеченными, она верна.

## Что сделать

Два шага, в этом порядке. Оба — вне `src/`, контракты не трогаются.

### 1. Провенанс в `deployments/<chainId>.json`

Добавить поля и заполнять их в момент `--broadcast`:

```json
{
  "commit": "fc15f4b…",
  "tag": "v2.0.0",
  "deployedAt": "2026-07-23T00:00:00Z",
  "solc": "0.8.26",
  "optimizerRuns": 200,
  "viaIr": false
}
```

Нынешние пять файлов заполнить постфактум: сборка идентифицируется однозначно — рантаймы совпадают
на всех пяти сетях и соответствуют v2.0.0. Обновить `script/README.md`, чтобы шаг не забывался.

### 2. Сверка `master` ↔ цепь

Расширить существующий `script/probe/probe_lens.mjs` до `script/probe/probe_deployment.mjs`:

* собрать набор внешних селекторов текущего `master` (из `out/<Contract>.sol/<Contract>.json`,
  `methodIdentifiers`) для `StableLPManager`, `VolatileLPManager`, `OpenVolatileLPManager`,
  `UniLens`, `LPManagerFactory`, `ChainlinkPriceOracle`, `FeeRedeemer`;
* по каждой сети из `deployments/` взять `eth_getCode` соответствующего адреса и проверить, что
  каждый селектор присутствует в рантайме;
* печатать расхождение списком: `chain 42161  UniLens  missing: oracleStatus(address),
  stableRanges(address), operators(address)`;
* ненулевой exit code при непустом расхождении.

Сравнение по селекторам, а не по байткоду, — сознательно: полное сравнение требует воспроизводимой
сборки (тот же solc, те же настройки, тот же `metadata`), а расхождение ловится и так.

Подключить job'ом в `.github/workflows/test.yml` (отдельный шаг после `forge build`, или nightly —
на усмотрение исполнителя; RPC берутся из `RPC_<chainId>`, дефолты уже есть в `probe_lens.mjs`).

### 3. Решение про деплой — не в этой задаче

Задеплоить ли task_042/043 сейчас или копить под релиз — решает человек. Что задача обязана
сделать: если копим, `CHANGELOG [Unreleased]` перестаёт быть пустым и перечисляет накопленное. Пустой
`[Unreleased]` при непустой разнице `master` ↔ последний задеплоенный тег — это то же самое
расхождение, только в документации.

## Как проверить

1. В каждом из пяти `deployments/<chainId>.json` непустой `commit`, и он есть в истории `master`.
2. `node script/probe/probe_deployment.mjs` на текущем `master` печатает список отсутствующих
   селекторов ровно для тех сетей и контрактов, где они отсутствуют, и возвращает ненулевой код.
   Сегодня ожидаемый вывод — по три отсутствующих селектора `UniLens` и по два у обоих менеджеров на
   всех пяти сетях.
3. После деплоя нового стека тот же прогон печатает «совпадает» и возвращает 0.
4. Ручная перепроверка любого пункта воспроизводится так же, как в разделе «Доказательство»:
   `eth_getCode` + поиск 4-байтового селектора в рантайме.

## Чего задача не делает

Не деплоит. Не меняет `src/`. Не решает, нужен ли `OpenVolatileLPManager` на цепях — только делает
его отсутствие видимым.

## Сделано (2026-09-21)

1. `DeployStableLP.s.sol` `_write`: поля `commit` (`DEPLOY_COMMIT`, **обязателен** — иначе `ProvenanceMissing`),
   `tag` (`DEPLOY_TAG`), `deployedAt` (`block.timestamp`), `solc`/`optimizerRuns`/`viaIr` (константы, зеркало
   `foundry.toml`). Пять `deployments/*.json` заполнены постфактум из `broadcast/DeployStableLP.s.sol/<chain>/run-latest.json`:
   `commit 12bcb45f…` (тот tree, с которого шёл broadcast 09-08; `src/` побайтно = `v2.1.0`), `tag v2.1.0`,
   `deployedAt` — timestamp броадкаста.
2. `script/probe/probe_deployment.mjs` без зависимостей (fetch + JSON-RPC): селекторы из `out/*.json` ↔ `eth_getCode`
   по каждому компоненту каждой сети; exit 0/1/2. Шаг в `.github/workflows/test.yml` после `forge build`.
   Прогон 09-21: все пять сетей `ok` по 7 компонентам; `OpenVolatileLPManager` — `not deployed` везде (не
   красит CI — решение владельца, записано в `CHANGELOG [Unreleased]`). Негативный контроль: адреса `v2.0.0`
   → `missing: operatorCount(), operatorList(uint256), rangeOf(bytes32)` / `operators, oracleStatus, stableRanges`, exit 1.
3. `CHANGELOG [Unreleased]` не пуст; `script/README.md` и `script/probe/README.md` описывают шаг.

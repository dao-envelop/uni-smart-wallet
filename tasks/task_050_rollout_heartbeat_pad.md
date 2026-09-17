# task_050 — Раскатать подбивку heartbeat'ов на Ethereum, Unichain и Base и начать сверять файл с цепью

**Ветка:** `task/050-heartbeat-pad-rollout` · **Статус:** закрыта 2026-09-17 — снята передеплоем 2.1.0 (09-08): `feeds()` на живых оракулах — chain 1 USDC 83700 / ETH 4500, chain 130 ETH 87300, т.е. подбитые значения; прогонять нечего. Сверка файл ↔ цепь — task_049.
**Находка:** `qa-workspace/quality/findings/2026-09-01-heartbeat-pad-live-on-one-chain-of-four.md`
**Severity:** S3 (домен B — on-chain правда)
**Связано:** task_045 (правило подбивки), task_049 (тот же корень — нет сверки «репозиторий ↔ цепь»)

## Симптом

task_045 установил правило: порог свежести на цепи = `publishedHeartbeat + min(2 · published, 900)`,
потому что порог, равный опубликованному heartbeat'у, недостижим по построению (`updatedAt` ложится
на ~15 с позже запуска раунда). Правило записано в `script/oracle_feeds.json` и линтуется тестом.

**На цепи оно живёт только на Arbitrum.** Ethereum, Unichain и Base несут неподбитые опубликованные
значения — те, что залили при первичной настройке 25 июля, за 19 дней до фикса.

## Доказательство

`feeds(currency)` на живых оракулах, 2026-09-01:

```
chain 1   USDC  agg 0x8fffffd4…18f6  heartbeat 82800   <- ждём 83700
chain 1   ETH   agg 0x5f4ec3df…8419  heartbeat  3600   <- ждём 4500
chain 130 USDC  agg 0xbd1cd151…d75b  heartbeat 86400   <- ждём 87300
chain 130 ETH   agg 0xbce70e19…8cca  heartbeat 86400   <- ждём 87300
base      USDC  agg 0x7e860098…bc6b  heartbeat 86400   <- ждём 87300
base      ETH   agg 0x71041ddd…bb70  heartbeat  1200   <- ждём 2100
base      cbBTC agg 0x07da0e54…9f9d  heartbeat  1200   <- ждём 2100

chain 42161 (подбито 2026-08-13):
  ETH 2655 (1755+900) · USDC 765 (255+510) · WBTC 87300 (86400+900)
```

Агрегаторы совпадают с `oracle_feeds.json` везде — ошиблись не в адресах, а в раскатке.

История `FeedSet` подтверждает: Arbitrum — два прохода (`blk 487476026…` 25 июля с published,
`blk 494123530…` 13 августа с подбитыми); Ethereum — **один** проход 2026-07-25T06:21:59 (5 строк),
Unichain — **один** 2026-07-25T06:21:05 (4 строки), после них ни одного.

Подтверждённых неподбитых строк: **12** (Ethereum 5, Unichain 4, Base 3 по точечному чтению).

## Влияние

Прямой цены сегодня нет: исполнение включено только на Arbitrum, у менеджера Unichain
`priceOracle = 0x000…000`, на Ethereum и Base открытых позиций ноль. Цена появится в тот день, когда
исполнение включат на любой из трёх, — и в форме, которую task_045 уже разобрал: операция молча не
проходит, ошибка не интерпретируется, повтор через минуту работает. На Ethereum ETH/USD
(`published 3600`, порог 3600) попадёт в это окно на каждом раунде, дошедшем до heartbeat'а.

Побочно: находка `2026-08-11-arb-oracle-heartbeat-below-feed-period` закрыта как исправленная, а
исправлено 6 строк из 18.

## Что сделать

### 1. Раскатать

Прогнать `script/SetOracleFeeds.s.sol` владельцем оракула (`0x13b9cbcb…7d3d`) на:

```bash
forge script script/SetOracleFeeds.s.sol --rpc-url $RPC_1     --sender $OWNER --account $KEYSTORE --broadcast
forge script script/SetOracleFeeds.s.sol --rpc-url $RPC_130   --sender $OWNER --account $KEYSTORE --broadcast
forge script script/SetOracleFeeds.s.sol --rpc-url $RPC_8453  --sender $OWNER --account $KEYSTORE --broadcast
forge script script/SetOracleFeeds.s.sol --rpc-url $RPC_1301  --sender $OWNER --account $KEYSTORE --broadcast   # тестнет, заодно
```

Перед прогоном — **сухая проверка на Base**: сколько строк там вообще установлено, сегодня неизвестно
(`base.blockscout.com` отдаёт 500 на `/logs`, `eth_getLogs` режется 10 000 блоками). Достаточно
прочитать `feeds(currency)` по всем токенам секции `8453` файла и сравнить.

### 2. Начать сверять файл с цепью

Добавить сверку — либо в `test/SetOracleFeeds.t.sol` отдельным форк-тестом (env-gated, по образцу
`test/OracleHeartbeat.fork.t.sol`), либо в пробу из task_049. Логика одна:

для каждой сети из `deployments/` и каждой строки соответствующей секции `oracle_feeds.json`
прочитать `feeds(currency)` живого оракула и сравнить `aggregator` и `heartbeat`. Расхождение —
красный, с печатью `chain / token / ожидали / нашли`.

Именно эта сверка, а не разовый прогон, закрывает класс: правка `oracle_feeds.json` без раскатки
должна краснеть, а не проходить молча.

## Как проверить

```
feeds(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) на 1    -> heartbeat 83700
feeds(0x0000000000000000000000000000000000000000) на 1    -> heartbeat  4500
feeds(0x078D782b760474a361dDA0AF3839290b0EF57AD6) на 130  -> heartbeat 87300
feeds(0x0000000000000000000000000000000000000000) на 130  -> heartbeat 87300
feeds(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) на 8453 -> heartbeat 87300
feeds(0x0000000000000000000000000000000000000000) на 8453 -> heartbeat  2100
```

и сверка из шага 2 проходит зелёной на всех сетях. Регресс: изменить `heartbeat` одной строки в
`oracle_feeds.json`, не раскатывая, — сверка обязана покраснеть.

## Чего задача не делает

Не меняет `src/oracle/ChainlinkPriceOracle.sol` — контракт корректен, правило верное, вопрос только в
том, что оно доехало до одной сети из четырёх. Не пересматривает `maxDeviationBps` (он равен 100 на
всех пяти сетях и на живом замере 2026-09-01 имеет запас 49.6–92.8 bps по всем четырём пулам
`arb-vol`).

# Аудит безопасности: VolatileLPManager и рефактор после v1.0.0 (ранее не аудированная поверхность)

**Дата:** 2026-07-18
**Проект:** `uniswap-smart-wallet` (Envelop V2 / UniSmartWallet)
**Ревизия:** ветка `master`, коммит `84a36b2`
**Фокус:** потеря средств / несанкционированный вывод / **риск компрометации оператора**.

> English version: [`AUDIT-REPORT.en.md`](./AUDIT-REPORT.en.md).

---

## 1. Зачем этот аудит

Четыре предыдущих аудита (`audits/2026-05-17`, `06-23`, `06-29`, `07-02`) и релиз **v1.0.0 (2026-06-29)**
покрывали **только `StableLPManager`**. Слова *Volatile* и *recenter* не встречаются **ни в одном** из
прошлых отчётов. Всё из секции `[Unreleased]` CHANGELOG — **добавлено после аудитов и не проверялось**:

- **`VolatileLPManager`** (task_026) — мульти-позиции, per-call диапазоны, **`recenter`**, `IPriceOracle`.
- **Split `BaseLPManager`** (task_028) — монолитный Stable-менеджер вынесен в общую базу.
- **Unified `withdrawTo`** в базу (task_029).
- **Универсальный `LPManagerFactory`** (task_030) — заменил `StableLPFactory`.

Аудит нацелен именно на эту непроверенную поверхность.

### Модель угроз (как в `2026-07-02`)
Внешний вызывающий не достаёт value-функции (`onlyOwnerNFT` / `onlyAuthorized`; `unlockCallback` за
`msg.sender == POOL_MANAGER`). Реальные акторы: **(a) скомпрометированный оператор** (`onlyAuthorized` =
владелец **или** оператор: `allocate` / `allocateFrom` / `reinvest` / `claimFees` / **`recenter`**);
(b) поведение токена (fee-on-transfer / rebasing); (c) чистые ошибки учёта. **Владелец, вредящий себе, —
не находка.**

## 2. Методология

Повторяет multi-agent конвейер `2026-07-02`. **5 независимых finder-агентов** (read-only, читают исходники
напрямую) по доменам: recenter/principal, реестр мульти-позиций, factory/clone, settlement рефактора,
oracle/native/reentrancy. Единственный влияющий на severity кандидат прогнан через **2 независимых
adversarial-верификатора**, каждому поставлена задача **опровергнуть**; находка попадает в отчёт только при
**≥2/3** голосов «реально и это потеря средств». Семантика `modifyLiquidity`/`unlock` сверена с
вендоренным `lib/v4-hooks-public/lib/v4-core/src/PoolManager.sol`.

## 3. Результат

| ID | Severity | Статус | Заголовок |
|---|---|---|---|
| **H-VOL-1** | **HIGH** | **ПОДТВ. 3/3** | Скомпрометированный оператор выводит **principal** позиции через `recenter` |
| **M-VOL-2** | **MEDIUM** | Подтв. (корень/enabler) | Нет обязательного не-операторского порога проскальзывания; оракул off-by-default и fail-open |
| L-FAC-1 | LOW | Подтв. | CREATE2-salt фабрики не включает `initData` → front-run подмены конфига при counterfactual-funding (средства возвратимы) |
| L-REG-1 | LOW | Подтв. | Ghost/дубли записей в `openSalts` (`L==0` add; `recenter` c нулевой L) — только off-chain/UI |
| L-TOK-1 | LOW | Подтв. заново (принято) | FoT/rebasing управляемый токен ломает `_settle`/`withdrawTo` (прежняя C-H2) |
| I-DOC-1 | INFO | — | Устаревшая дока: `WITHDRAW_TO_V=9` (в коде переиспользуется `OP_WITHDRAW_TO=5`); mismatch комментария `ORACLE_TYPE` |

**Вывод по компрометации оператора.** Скомпрометированный оператор **не может** напрямую перевести
средства наружу (`withdrawTo`, `executeEncodedTxBatch` — `onlyOwnerNFT`; разделение ролей и очистка
операторов при трансфере NFT корректны). Но он **может экономически извлекать стоимость через свопы, все
границы проскальзывания которых задаёт сам**. Для **StableLPManager** это ограничено **idle-балансом +
fees** (принятая C-H1). Для **VolatileLPManager** новый `recenter` снимает **principal** позиции ПЕРЕД этим
оператор-параметризованным свопом — значит скомпрометированный оператор может сливать и **principal**. Это
реальная эскалация, на коде, который не смотрел ни один аудит. Буквальный инвариант «операторы не выводят
капитал» верен; экономический — нет.

---

## 4. HIGH

### H-VOL-1 — Оператор выводит principal позиции через `recenter`
**Severity: HIGH · ПОДТВЕРЖДЕНО finder + 2/2 adversarial-верификатора (3/3).**
**Локация:** `src/VolatileLPManager.sol:292` (`recenter`, `onlyAuthorized`), `:298-344` (`_handleRecenter`),
`:347-354` (`_rebalanceSwap`), `:264-286` (`_addLiquidityAt`), `:357-360` (`_posDelta`); settlement
`src/BaseLPManager.sol:472-486`; своп-примитив `src/abstract/V4PositionManager.sol:162-170`.

**Механизм.**
1. `recenter` вызывается оператором (`onlyAuthorized`). Он снимает **всю** ликвидность позиции:
   `modifyLiquidity(liquidityDelta = -pos.liquidity)` (`:305-314`). В v4-core
   `callerDelta = principalDelta + feesAccrued` начисляется в транзиентный счёт менеджера
   (`_accountPoolBalanceDelta`). `_skimFees` берёт только протокольную долю от *fee*-компоненты, поэтому
   **весь principal остаётся положительной `currencyDelta`** — расходуемой внутри того же unlock. Пулы
   hookless, хук не может изменить дельту.

   > **Обновление (task_043).** Эта предпосылка относится к `StableLPManager` и `VolatileLPManager` —
   > они остались hookless. Появилась третья имплементация `OpenVolatileLPManager` (`ORACLE_TYPE 3002`),
   > у которой гейта нет вообще: там хук МОЖЕТ вернуть дельту, и разбор выше на неё не распространяется.
   > Это осознанный выбор владельца (отдельный имплант в allowlist фабрики, не флаг), последствия
   > перечислены в шапке `src/OpenVolatileLPManager.sol` и в `CLAUDE.md` § Hook policy. Отдельно
   > напоминание: `unlockCallback` до сих пор не `nonReentrant` и `(op, payload)` не привязан к внешнему
   > входу ([M-3] аудита 2026-05-17) — для hookless-продуктов этот путь закрыт именно гейтом.
2. `_rebalanceSwap` делает своп с **оператор-заданными** `swapAmountIn`, `swapPriceLimit`, `minAmountOut`.
   Своп неттится против того же счёта, то есть **освобождённый principal финансирует вход свопа**. При
   `minAmountOut = 0` и `swapPriceLimit` на экстремуме MIN/MAX-sqrt обе Uniswap-защиты отключены; проверка
   full-fill (`:350`) — это не порог проскальзывания. Если `swapAmountIn` превышает освобождённый
   principal, недостаток `_settle`-ится из **idle-баланса** менеджера (`_settleCurrency`, `:479-486`) —
   idle тоже сливается.
3. Re-add сайзится из `_posDelta` (положительный остаток) при оператор-заданных `minLiquidity = 0` и
   `newTickLower/newTickUpper`, поэтому может дать `L ≈ 0`; уменьшенный остаток возвращается менеджеру
   через `_settleManaged`.
4. **Единственная защита уровня протокола** — `_guardSwap → IPriceOracle.check` — **no-op при `priceOracle
   == address(0)` (дефолт)** и **fail-open** даже когда задан (не реверт при отсутствии референса).

**Эксплуатация (один контракт-searcher с делегированной ролью оператора):** front-run сконфигурированного
пула для перекоса цены → вызов `recenter{swapAmountIn ≈ principal (+idle), minAmountOut:0, minLiquidity:0,
swapPriceLimit: экстремум}` (менеджер сбрасывает principal по разорительному курсу) → back-run для захвата.
`nonReentrant` не помогает — ноги сэндвича это отдельные unlock'и, не реентранси. Либо оператор просто
контрагент-LP в тонком пуле.

**Impact.** За вызов: ≈ principal входной валюты рецентрируемой позиции + idle этой валюты; повторяемо по
всем позициям и обоим направлениям ⇒ сливаем principal всего портфеля. Доля извлечения ограничена
глубиной пула (≈100% в тонком/JIT-пуле). **Предусловие:** роль оператора + ≥1 открытая позиция +
`priceOracle` не задан (дефолт) или устаревший/мягкий.

**Это НЕ принятая C-H1.** В Stable `onlyAuthorized`-пути не снимают principal (`allocate`/`allocateFrom`
добавляют; `reinvest`/`claimFees` используют `liquidityDelta:0` и свопят только реализованные fees);
единственный путь снятия principal там — `withdrawTo` (`onlyOwnerNFT`). `recenter` — **первый
оператор-вызываемый путь снятия principal**, эскалирующий C-H1 с idle/fees на principal.

**Ремедиация (варианты; решение отложено по запросу):**
- Ввести **не-операторский** порог проскальзывания: сделать строгий, всегда-свежий `IPriceOracle`
  **обязательным** для volatile-свопов и **убрать fail-open** там, где оракул задан; либо выводить
  `minAmountOut` из TWAP пула v4 **внутри контракта**, не доверяя оператору; либо
- добавить **проверку сохранения стоимости** в `recenter` (стоимость после ≥ X% от до, через
  `PositionState`); либо
- быстрый минимал-фикс: перевести **`recenter` на `onlyOwnerNFT`** (убирает операторский principal-путь;
  оператор теряет быстрый recenter).
- PoC: тест на `recenter` по образцу `test/StableLPManagerH1OperatorExtractionPoC`, ассертить прибыль
  атакующего > 0 и потерю principal менеджера.

---

## 5. MEDIUM

### M-VOL-2 — Нет обязательного не-операторского порога проскальзывания (оракул off-by-default и fail-open)
**Severity: MEDIUM (сам по себе) / корень H-VOL-1.**
**Локация:** `src/VolatileLPManager.sol:40` (`priceOracle` дефолт zero), `:146-151` (`_guardSwap`),
`:218-230` (`_allocateLegV`), `:347-354` (`_rebalanceSwap`); `src/StableLPManager.sol:180-185`
(`_allocateLeg`), `:280-282` (`_handleReinvest` — результат свопа **полностью игнорируется**);
`src/interfaces/IPriceOracle.sol` (fail-open по контракту).

Каждая граница свопа (`minAmountOut`, `minLiquidity`, `swapPriceLimit`) **задаётся оператором**, то есть
защищает честного оператора от рыночного проскальзывания и даёт **ноль** защиты от вредоносного.
Единственная не-операторская граница — `IPriceOracle` — (a) `address(0)` по умолчанию, (b) ставится только
владельцем, (c) fail-open даже когда задан. Как следствие скомпрометированный оператор сливает **idle +
fees** через `allocate`/`reinvest` на **обоих продуктах** (своп в Stable `reinvest` слабее всего — вообще
без проверки выхода/full-fill), и **principal** через `recenter` (H-VOL-1). Рекомендуется обязательный,
энфорсимый контрактом порог (см. §4). Как минимум — задокументировать, что строгий оракул **операционно
обязателен** в проде.

---

## 6. LOW / INFO

### L-FAC-1 — CREATE2-salt фабрики не включает `initData`
`src/LPManagerFactory.sol:96` — `salt = keccak256(abi.encode(expectedOwner, implementation, n))`.
`createManager` пермишенлесс, адрес зависит только от `(implementation, expectedOwner, nonce)`, не от
`initData`. Атакующий front-run'ит рекламируемый counterfactual-funding (`predictManagerAddress` +
предотправка) c тем же owner, но своим `initData`, разворачивая клон по предоплаченному адресу жертвы со
своими пулами/дескриптором. **Не кража:** clone+`initialize` атомарны, пост-init проверка
`ownerOf(TOKEN_ID) == expectedOwner` держит, NFT достаётся жертве, а предотправленные средства возвратимы
через `onlyOwnerNFT` escape hatch `executeEncodedTxBatch`. Griefing/мис-конфиг ⇒ LOW. **Фикс:** вшить
payload в salt — `keccak256(abi.encode(expectedOwner, implementation, n, keccak256(initData)))` — и
отразить в `predictManagerAddress`.

### L-REG-1 — Ghost/дубли записей `openSalts`
`src/VolatileLPManager.sol:235-257`, `:264-286` (`L < minLiq` при `minLiq==0` проходит на `L==0`),
`:322-339` (`recenter` может оставить `liquidity==0` зарегистрированной). `L==0` add регистрирует
нулевую позицию; повторный allocate ghost-салта даже второй раз зовёт `_registerSalt`, оставляя вечный
orphan в `openSalts`. **Ни один on-chain путь средств не читает `openSalts`** — его обходят только
view-агрегаторы (`UniLens.sol:68`, `WalletPositionDescriptor.sol:83,204`), а учёт ликвидности идёт по
`_positions[salt]` напрямую, поэтому нет блокировки средств / не ломает выход владельца. Off-chain/UI OOG
⇒ LOW. **Фикс:** отклонять `L == 0` (`require(L > 0)` / `minLiquidity >= 1`).

### L-TOK-1 — Fee-on-transfer / rebasing управляемый токен (прежняя C-H2, подтв. заново/принято)
`src/abstract/V4PositionManager.sol:178` (`_settle`), `:195` (`_take`). FoT/rebasing валюта ломает
`received == sent`: `withdrawTo` молча недодаёт, `allocate` реверт на settle-shortfall (DoS на этот
стейбл). Принято как owner-configured pools. Управляемые валюты **должны быть стандартными ERC-20**.
Опц.: allow-list проверенных стейблов на уровне фабрики/init.

### I-DOC-1 — Устаревшая доборка
`CLAUDE.md` упоминает volatile `WITHDRAW_TO_V=9`; в коде переиспользуется базовый `OP_WITHDRAW_TO=5` через
`super` (диспетчеризация корректна — путаницы op-кодов нет). Mismatch комментария `ORACLE_TYPE` из
`2026-07-02` §7 сохраняется. Капитального риска нет.

---

## 7. Подтверждено корректным (без находок)

- **Изоляция protocol-fee:** `_skimFees` получает только `feesAccrued` (2-й возврат `modifyLiquidity`) во
  всех 7 сайтах — principal не облагается; ceil-skim `(fee*1000+9999)/10000` не переполняется/не
  перескимливает.
- **Net settlement:** `_settleManaged` по дедуп-объединению `managedStables` неттит каждую валюту один раз
  против агрегатной дельты; неуправляемая валюта не может попасть в unlock ⇒ нет `CurrencyNotSettled`
  DoS, нет застрявшего кредита.
- **Reentrancy:** ops `nonReentrant`; `unlockCallback` за `msg.sender==POOL_MANAGER`; v4 реверт вложенного
  `unlock` и энфорс нулевых дельт; `_guardSwap` — `view` → **STATICCALL** (вредоносный оракул может только
  реветить). Callback/ERC777 токен пула не реентрит op, не достаёт `unlockCallback`, не перекредитует.
- **Native ETH:** `settle{value}` / `sync` / `receive()` — точный симметричный учёт; нет утечки/застревания.
- **Clone safety:** иммутабли `POOL_MANAGER`/`PROTOCOL_TREASURY` через delegatecall; impl заблокирован
  (`_initialized=true` в ctor); OZ v5.5.0 `ReentrancyGuard` проверяет `value==ENTERED`, свежий клон `0` =
  not-entered — гард работает без конструктора.
- **Ядро фабрики:** атомарный clone+init, пост-init owner-check реверт (OZ `_requireOwned`) на
  неинициализирующем вызове, re-init/mint-once инварианты держат, allowlist не обойти, Envelop-события не
  подделать чужим байткодом.
- **Мульти-позиции:** cross-pool salt aliasing сдержан `RangeMismatch` + атомарный откат V4; `.poolId`
  иммутабелен после открытия; пре-чек и pull `withdrawTo` читают одну и ту же запись.
- **Stable:** оператор-вызываемого пути снятия principal нет (подтверждено).

---

## 8. Проверка / воспроизведение

```bash
cd uniswap-smart-wallet && git submodule update --init --recursive
forge build --sizes            # StableLPManager < 24576 B (запас EIP-170 ~177 B — ограничивает фиксы Stable)
forge test -vvv
forge test --match-path test/VolatileLPManagerAllocate.t.sol -vvv
BASE_RPC=... forge test --match-path "test/*.fork.t.sol" -vvv
# Рекомендуемый новый PoC (H-VOL-1): recenter под скомпрометированным оператором, ассерт прибыль
# атакующего > 0 и потеря principal менеджера — по образцу test/StableLPManagerH1OperatorExtractionPoC.t.sol.
```

## 9. Заключение

Рефактор (изоляция fee, settlement, авторизация, reentrancy, clone-safety) **чист** — регрессий,
утекающих/застревающих/мисроутящих principal, нет. Единственный новый **HIGH** — **H-VOL-1**:
`VolatileLPManager.recenter` позволяет скомпрометированному **оператору** прогнать **principal** позиции
через самопараметризованный убыточный своп и извлечь его, т.к. **нет обязательного не-операторского порога
проскальзывания**, а оракул выключен по умолчанию и fail-open (M-VOL-2). Это реальная эскалация принятой
C-H1 на код, **не смотренный ни одним аудитом**. Прежде чем полагаться на роль оператора для
`VolatileLPManager` в проде — закрыть H-VOL-1/M-VOL-2 (обязательный оракул / TWAP-порог / value-
conservation, либо `recenter → onlyOwnerNFT`). Low — харденинг (вшить `initData` в salt фабрики; отклонять
`L==0`; энфорс стандартного ERC-20).

*Метод: 5 finder-агентов + 2 adversarial-верификатора, read-only, код в этом проходе не менялся.*
</content>

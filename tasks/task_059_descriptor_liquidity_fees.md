# task_059 — карточка NFT: две суммы вместо «стоимости» и APR

**Репозиторий:** `uniswap-smart-wallet` · **Ветка:** `task/059-descriptor-liquidity-fees`
(от `task/058-move-bridge-swap`; релиз v2.2.0). Меняется только `WalletPositionDescriptor`, менеджеры не
трогаются — новый дескриптор подключается к любому менеджеру, включая v2.1, через `setPositionDescriptor`.

## Симптом

После task_055 карточка показывала одну сумму «Positions value (excl. idle)» = тело позиций + несобранные
комиссии, и APR — только если менеджер отдаёт часы комиссий `feesSince(salt)`. Таких менеджеров нет, и
честного APR в цепи не посчитать: комиссии обнуляются при каждой реализации (claim, reinvest, recenter,
move, довнесение, вывод), а капитал меняется переводами, которых менеджер не видит. Агентская стратегия,
которая часто трогает позиции, выглядела бы на карточке хуже пассивной.

## Решение владельца (2026-10-20)

APR из метаданных убрать. Показывать две суммы, названия — как на странице позиции в Uniswap:

| Сумма | Атрибут | Подпись на картинке |
|---|---|---|
| Тело открытых позиций по живой цене, без idle и без комиссий | `Liquidity (USD)` | `Liquidity` |
| Несобранные комиссии, нетто 10 % протокола | `Unclaimed Fees (USD)` | `Unclaimed fees: $X` |

`TVL` отклонён (это про протокол/пул и обычно включает всё), `Principal` — непонятен вне DeFi-разработки,
`Position value` — двусмыслен (входят ли комиссии).

## Что сделано

- `_totals` считает две суммы, APR, `_feesSince` и вызов `feesSince(bytes32)` удалены;
  `DescriptorLib.formatPercentBps` удалён (не используется).
- Атрибуты: `Liquidity (USD)` и `Unclaimed Fees (USD)` — оба отсутствуют при `Pricing` = `unpriced` или
  `truncated` (как раньше `Positions Value (USD)`).
- `positions[]`: вместо `valueUsd` — `liquidityUsd` и `feesUsd` (только у оценённых позиций).
- SVG: крупная сумма — Liquidity (`≥ $X` при усечении, `unpriced` без цены), под ней строка
  `Unclaimed fees: $Y`.

Размер дескриптора: 20 725 → 20 365 B (свободно 4 211).

## Тесты

`test_twoSums_liquidityAndUnclaimedFees_noApr`: обе суммы и поля позиции сходятся с `positionValue`, APR
нет ни в атрибутах, ни на картинке, claim обнуляет комиссии и не трогает Liquidity. APR-тесты и тест
`formatPercentBps` удалены, остальные атрибутные проверки переведены на новые имена.
`forge test`: 383 passed, 0 failed, 7 skipped; форк `WalletPositionDescriptor.fork.t.sol` на Arbitrum и
Unichain (живые менеджеры) — passed.

## Фронт (`stablelp-ui`, отдельная задача после деплоя)

- `src/lib/server/managerMeta.ts`: читать `Liquidity (USD)` и `Unclaimed Fees (USD)`; старый
  `Total Value (USD)` — пока не все владельцы переключили дескриптор. Если атрибутов нет (`unpriced`,
  `truncated`) — показывать позиции, а не прятать блок.
- `Est. APR (bps)` больше нет нигде; `Pricing` — новый атрибут.
- `positions[]`: `liquidityUsd`, `feesUsd`, `fee`, `pricing`; `fees0/fees1` — нетто; не более 40 позиций.
- `opengraph-image.tsx`: подпись «Total value» → «Liquidity» (+ комиссии отдельно, если показывать).

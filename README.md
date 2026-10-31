# UNET-GAME для Sprinter

Здесь ведётся разработка сетевых библиотек для пошаговых игр на Sprinter. Предусмотрены профили TCP и UDP для SprinterESP, RTL8019AS и 3C509B, а также loopback для проверки игрового кода.

- [Техническое задание](docs/unet-game-spec.md) описывает работу карт, временной бюджет и критерии приёмки.
- [ABI v1](docs/unet-game-abi.md) определяет вызовы библиотеки, владение буферами и порядок событий.

## Состояние

- Веха 0: ABI v1.0 и общий include `include/UNETGAME.INC`, семь DLL собираются
  `sprinter-mkdll` и проходят `verify --target 1.3`, стенд Z на Node с проверкой
  бюджетов, DI, стека и дисциплины ISA, прототип размера GTCP509B.
- Веха 1: loopback GLOOP с полным набором очередей и событий.
- Остальное: [план вех](docs/ARCHITECTURE.md), [сборка](docs/BUILD.md),
  [замеры](docs/MEASUREMENTS.md), [матрица приёмки](docs/acceptance/matrix.md).

Правила разработки для агента — в [CLAUDE.md](CLAUDE.md).

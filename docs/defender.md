# Defender: статус и отложенное удаление

Реализовано read-only получение AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, IsTamperProtected и версии платформы через Get-MpComputerStatus.

```powershell
.\Start.ps1 -Mode Defender
```

Пункт `defender.remove` присутствует для отслеживания запрошенного объёма, но всегда возвращает **Unsupported**. Это не реализованный remover. Ни AllowUnverified, ни AcceptRisk не включают удаление. Скрипт не меняет настройки Defender и не обходит Tamper Protection.

Перед реализацией нужны воспроизводимый метод, проверка лицензии/исходников стороннего инструмента при его использовании, закрепление версии, тесты на каждой заявленной сборке, перезагрузка, Windows Update, Security Center и восстановление из образа. На текущей машине по указанию пользователя это не выполняется.

Tamper Protection может блокировать изменения, несмотря на внешний успех команды. Режим Defender рядом со сторонним AV зависит от конфигурации системы; отключение/пассивный режим не означают удаление. Серверные методы удаления нельзя выдавать за универсальный способ для Windows 11.

Источники: [Tamper Protection](https://learn.microsoft.com/en-us/defender-endpoint/prevent-changes-to-security-settings-with-tamper-protection), [Defender compatibility](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-compatibility).

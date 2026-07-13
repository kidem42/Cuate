HOW TO OPEN AISPOTLIGHT
=======================

1. Drag AISpotlight.app to the Applications folder.

2. On first launch macOS may warn that the app is from an
   unidentified developer.

   - macOS 15 (Sequoia) and newer:
     System Settings -> Privacy & Security -> scroll down ->
     click "Open Anyway", then confirm.

   - macOS 14 and older:
     Right-click (Ctrl-click) the app -> Open -> Open.

   You only need to do this once.

3. Advanced alternative — remove quarantine in Terminal:
     xattr -dr com.apple.quarantine /Applications/AISpotlight.app
   After that the app opens without any warnings.

Tip: if the DMG is transferred without a browser (AirDrop, USB
drive, curl), there may be no warning at all.


КАК ОТКРЫТЬ AISPOTLIGHT
=======================

1. Перетащите AISpotlight.app в папку «Программы» (Applications).

2. При первом запуске macOS может показать предупреждение,
   что приложение от неустановленного разработчика.

   - macOS 15 (Sequoia) и новее:
     Системные настройки → Конфиденциальность и безопасность →
     прокрутите вниз → нажмите «Открыть всё равно», подтвердите.

   - macOS 14 и старее:
     Правый клик (Ctrl+клик) по приложению → «Открыть» → «Открыть».

   Это нужно сделать только один раз.

3. Альтернатива для продвинутых — снять карантин в Терминале:
     xattr -dr com.apple.quarantine /Applications/AISpotlight.app
   После этого приложение открывается без предупреждений.

Совет: если DMG передан не через браузер (AirDrop, флешка, curl),
предупреждения может не быть вовсе.

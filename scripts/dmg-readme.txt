HOW TO OPEN AISPOTLIGHT
=======================

1. Drag AISpotlight.app to the Applications folder.

2. The build is not notarized by Apple, so macOS will block the
   first launch. Remove the quarantine flag in Terminal:

     xattr -dr com.apple.quarantine /Applications/AISpotlight.app

   After that the app opens without any warnings. You only need
   to do this once.

Tip: if the DMG is transferred without a browser (AirDrop, USB
drive, curl), there is no quarantine flag and the app opens
right away.


КАК ОТКРЫТЬ AISPOTLIGHT
=======================

1. Перетащите AISpotlight.app в папку «Программы» (Applications).

2. Сборка не нотаризована Apple, поэтому macOS заблокирует первый
   запуск. Снимите флаг карантина в Терминале:

     xattr -dr com.apple.quarantine /Applications/AISpotlight.app

   После этого приложение открывается без предупреждений.
   Это нужно сделать только один раз.

Совет: если DMG передан не через браузер (AirDrop, флешка, curl),
флага карантина нет и приложение откроется сразу.

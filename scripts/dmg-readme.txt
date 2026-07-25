HOW TO OPEN Cuate
=================

1. Drag Cuate.app to the Applications folder.

2. The build is not notarized by Apple, so macOS will block the
   first launch. Remove the quarantine flag in Terminal:

     xattr -dr com.apple.quarantine /Applications/Cuate.app

   After that the app opens without any warnings. You only need
   to do this once.

Tip: if the DMG is transferred without a browser (AirDrop, USB
drive, curl), there is no quarantine flag and the app opens
right away.


КАК ОТКРЫТЬ Cuate
=================

1. Перетащите Cuate.app в папку «Программы» (Applications).

2. Сборка не нотаризована Apple, поэтому macOS заблокирует первый
   запуск. Снимите флаг карантина в Терминале:

     xattr -dr com.apple.quarantine /Applications/Cuate.app

   После этого приложение открывается без предупреждений.
   Это нужно сделать только один раз.

Совет: если DMG передан не через браузер (AirDrop, флешка, curl),
флага карантина нет и приложение откроется сразу.

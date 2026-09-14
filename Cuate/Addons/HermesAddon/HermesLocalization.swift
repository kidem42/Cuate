import Foundation

/// Self-contained localization for the HermesAddon (pattern:
/// `CalendarLocalization.CAL`). Core AgentGateway strings live in `AGL`.
func HL(_ key: String) -> String {
    let lang = Localization.currentLanguage
    guard let table = HermesAddonStrings.table[key] else { return key }
    return table[lang] ?? table[.english] ?? key
}

enum HermesAddonStrings {
    static let table: [String: [AppLanguage: String]] = [
        "hermes.background.title": [
            .english: "Background work · %d subagents",
            .spanish: "Trabajo en segundo plano · %d subagentes",
            .russian: "Работа в фоне · сабагентов: %d"
        ],
        "hermes.background.waiting": [
            .english: "Subagents were dispatched. Waiting for their results…",
            .spanish: "Los subagentes se iniciaron. Esperando sus resultados…",
            .russian: "Сабагенты запущены. Ожидаю результаты…"
        ],
        "hermes.background.unconfirmed": [
            .english: "No completion report yet. The current status is unconfirmed.",
            .spanish: "Aún no hay informe final. El estado actual no está confirmado.",
            .russian: "Отчёт о завершении ещё не получен. Текущий статус не подтверждён."
        ],
        // MARK: Session continuation consent
        "hermes.continuation.title": [
            .english: "Continue the task?",
            .spanish: "¿Continuar la tarea?",
            .russian: "Продолжить задачу?"
        ],
        "hermes.continuation.body": [
            .english: "Background results are ready. Allow the main agent to continue and prepare the answer? A continuation uses your model quota.",
            .spanish: "Los resultados en segundo plano están listos. ¿Permitir que el agente principal continúe y prepare la respuesta? La continuación consume cuota del modelo.",
            .russian: "Фоновые результаты получены. Разрешить основному агенту продолжить работу и подготовить ответ? Продолжение расходует квоту модели."
        ],
        "hermes.continuation.once": [
            .english: "Continue",
            .spanish: "Continuar",
            .russian: "Продолжить"
        ],
        "hermes.continuation.onceHelp": [
            .english: "Allow one continuation using the results already in this session.",
            .spanish: "Permitir una continuación con los resultados de esta sesión.",
            .russian: "Разрешить одно продолжение с результатами, уже полученными в этой сессии."
        ],
        "hermes.continuation.session": [
            .english: "Allow for this session",
            .spanish: "Permitir en esta sesión",
            .russian: "Разрешать в этой сессии"
        ],
        "hermes.continuation.sessionHelp": [
            .english: "Automatically approve future background-result continuations in this session only. Tool approvals remain separate.",
            .spanish: "Aprobar automáticamente futuras continuaciones con resultados en segundo plano solo en esta sesión. Los permisos de herramientas siguen siendo independientes.",
            .russian: "Автоматически разрешать будущие продолжения после фоновых результатов только в этой сессии. Разрешения на действия инструментов остаются отдельными."
        ],
        "hermes.continuation.later": [
            .english: "Not now",
            .spanish: "Ahora no",
            .russian: "Не сейчас"
        ],
        "hermes.continuation.laterHelp": [
            .english: "Keep the results and decide later. No continuation is sent.",
            .spanish: "Conservar los resultados y decidir más tarde. No se envía una continuación.",
            .russian: "Сохранить результаты и решить позже. Запрос продолжения не отправляется."
        ],
        "hermes.continuation.reopen": [
            .english: "Results ready — review continuation",
            .spanish: "Resultados listos — revisar continuación",
            .russian: "Результаты готовы — разрешить продолжение…"
        ],
        "hermes.continuation.enabled": [
            .english: "Continuations are approved for this session",
            .spanish: "Continuaciones aprobadas para esta sesión",
            .russian: "Автопродолжение разрешено в этой сессии"
        ],
        "hermes.continuation.disable": [
            .english: "Ask each time",
            .spanish: "Preguntar siempre",
            .russian: "Спрашивать каждый раз"
        ],
        "hermes.continuation.disableHelp": [
            .english: "Revoke automatic continuation approval for this session.",
            .spanish: "Revocar la aprobación automática de continuaciones para esta sesión.",
            .russian: "Отозвать авторазрешение продолжений для этой сессии."
        ],
        "hermes.continuation.unavailable": [
            .english: "Continuation has not been sent. The session may be busy or unavailable; you can try again.",
            .spanish: "No se ha enviado la continuación. La sesión puede estar ocupada o no disponible; puedes intentarlo de nuevo.",
            .russian: "Продолжение не отправлено. Сессия может быть занята или недоступна; можно повторить попытку."
        ],
        "hermes.continuation.prompt": [
            .english: "Continue the original task using the background results already received in this session and prepare the answer. Do not repeat completed work.",
            .spanish: "Continúa la tarea original con los resultados en segundo plano ya recibidos en esta sesión y prepara la respuesta. No repitas el trabajo completado.",
            .russian: "Продолжи исходную задачу с учётом фоновых результатов, уже полученных в этой сессии, и подготовь ответ. Не повторяй завершённую работу."
        ],
        // MARK: Compact connection guide
        "hermes.guide.prepare.configure": [
            .english: "If Hermes is not configured yet, run setup, choose a provider and model, then sign in or enter the provider API key. If it already replies, skip setup. Telegram is optional. On a dedicated VPS choose the Local terminal backend; Docker needs a shared upload folder.",
            .spanish: "Si Hermes aún no está configurado, ejecuta setup, elige proveedor y modelo e inicia sesión o introduce la clave API. Si ya responde, omite setup. Telegram es opcional. En un VPS dedicado elige el terminal Local; Docker necesita una carpeta compartida para archivos.",
            .russian: "Если Hermes ещё не настроен, запустите мастер, выберите провайдера и модель, войдите в аккаунт или введите ключ провайдера. Если уже отвечает, мастер пропустите. Telegram необязателен. На отдельном VPS выберите терминал Local; для Docker нужна общая папка загрузок."
        ],
        "hermes.guide.prepare.update": [
            .english: "If the hosting provider preinstalled Hermes or the installation is old, update it first. Skip this command for a freshly installed current version. If the updater fails, keep the error for support; do not bypass it or reset local changes blindly.",
            .spanish: "Si el hosting preinstaló Hermes o la instalación es antigua, actualízalo primero. Omite este comando en una instalación nueva y actual. Si falla, guarda el error para soporte; no lo omitas ni descartes cambios locales sin revisarlos.",
            .russian: "Если Hermes был предустановлен хостингом или давно не обновлялся, сначала обновите его. Для только что установленной актуальной версии эту команду пропустите. При сбое сохраните ошибку для поддержки; не обходите её и не сбрасывайте локальные изменения вслепую."
        ],
        "hermes.guide.title": [
            .english: "Connect Hermes",
            .spanish: "Conectar Hermes",
            .russian: "Как подключить Hermes"
        ],
        "hermes.guide.route": [
            .english: "Connection method",
            .spanish: "Método de conexión",
            .russian: "Способ подключения"
        ],
        "hermes.guide.route.help": [
            .english: "Choose instructions for a VPS with a domain or a Mac connected through SSH. This choice does not change your connection settings.",
            .spanish: "Elige instrucciones para un VPS con dominio o un Mac conectado por SSH. Esta selección no cambia la conexión.",
            .russian: "Выберите инструкцию для VPS с доменом или подключения Mac через SSH. Выбор инструкции не меняет настройки соединения."
        ],
        "hermes.guide.domain": [
            .english: "I have a domain",
            .spanish: "Tengo un dominio",
            .russian: "Есть домен"
        ],
        "hermes.guide.tunnel": [
            .english: "No domain",
            .spanish: "Sin dominio",
            .russian: "Без домена"
        ],
        "hermes.guide.domain.intro": [
            .english: "With a domain, Cuate connects to your VPS over HTTPS. The same addresses work on Mac and Android; no open Terminal window is needed.",
            .spanish: "Con un dominio, Cuate se conecta al VPS por HTTPS. Las mismas direcciones sirven en Mac y Android; no necesitas mantener Terminal abierto.",
            .russian: "С доменом Cuate подключается к VPS по HTTPS. Одни и те же адреса работают на Mac и Android; держать Терминал открытым не нужно."
        ],
        "hermes.guide.tunnel.intro": [
            .english: "Without a domain, an SSH tunnel gives this Mac a private connection to the VPS. It starts after you log in and reconnects after network interruptions. The Mac tunnel does not connect an Android phone.",
            .spanish: "Sin dominio, un túnel SSH conecta este Mac al VPS de forma privada. Se inicia al entrar en tu cuenta y se reconecta tras cortes de red. No conecta un teléfono Android.",
            .russian: "Без домена SSH-туннель создаёт защищённое соединение этого Mac с VPS. Он запускается после входа в macOS и восстанавливается после обрывов сети. На Android туннель с Mac не распространяется."
        ],
        "hermes.guide.steps.prepare": [
            .english: "1. On the VPS: set up Hermes, choose a model and get a reply in its terminal chat.",
            .spanish: "1. En el VPS: configura Hermes, elige un modelo y comprueba que responde en su chat de terminal.",
            .russian: "1. На VPS: настройте Hermes, выберите модель и получите ответ в его чате в терминале."
        ],
        "hermes.guide.steps.server": [
            .english: "2. On the VPS: run the server block for chat, files, the Cuate patch and service autostart. Save the two keys it prints.",
            .spanish: "2. En el VPS: ejecuta el bloque para chat, archivos, parche de Cuate e inicio automático. Guarda las dos claves que muestra.",
            .russian: "2. На VPS: выполните блок настройки чата, файлов, патча Cuate и автозапуска служб. Сохраните два выведенных ключа."
        ],
        "hermes.guide.steps.domain": [
            .english: "3. Connect the domain, then enter the two HTTPS addresses and their keys in Cuate.",
            .spanish: "3. Conecta el dominio e introduce las dos direcciones HTTPS y sus claves en Cuate.",
            .russian: "3. Подключите домен и перенесите в Cuate два HTTPS-адреса и их ключи."
        ],
        "hermes.guide.steps.tunnel": [
            .english: "3. On the Mac: run the automatic tunnel block. In Cuate, enable “VPS through SSH tunnel” and enter the addresses and keys.",
            .spanish: "3. En el Mac: ejecuta el bloque del túnel automático. En Cuate, activa «VPS por túnel SSH» e introduce las direcciones y claves.",
            .russian: "3. На Mac: выполните блок автоматического туннеля. В Cuate включите «VPS через SSH-туннель» и введите адреса и ключи."
        ],
        "hermes.guide.steps.check": [
            .english: "4. Test a reply, an uploaded file and a downloaded file. Then check the connection after restarting.",
            .spanish: "4. Prueba una respuesta, la subida y la descarga de un archivo. Después comprueba la conexión tras reiniciar.",
            .russian: "4. Проверьте ответ, отправку и скачивание файла. Затем проверьте соединение после перезагрузки."
        ],
        "hermes.guide.open": [
            .english: "Open full instructions",
            .spanish: "Abrir instrucciones completas",
            .russian: "Открыть полную инструкцию"
        ],
        "hermes.guide.open.help": [
            .english: "Open the selected guide with complete command blocks and the exact Cuate fields to fill in.",
            .spanish: "Abre la guía elegida con comandos completos y los campos que debes rellenar en Cuate.",
            .russian: "Открыть выбранную инструкцию с полными командами и точными полями для заполнения в Cuate."
        ],
        "hermes.guide.copy.help": [
            .english: "Copy the entire selected guide, including all commands. No saved keys are included.",
            .spanish: "Copia toda la guía elegida con sus comandos. No incluye claves guardadas.",
            .russian: "Скопировать выбранную инструкцию целиком, вместе с командами. Сохранённые ключи в неё не включаются."
        ],
        "hermes.guide.local": [
            .english: "Hermes on this Mac? Use the local setup offered in the connection section. The VPS guide is for a separate server.",
            .spanish: "¿Hermes está en este Mac? Usa la configuración local de la sección de conexión. Esta guía es para un servidor separado.",
            .russian: "Hermes установлен на этом Mac? Используйте локальную настройку в разделе подключения. Эта инструкция — для отдельного сервера."
        ],
        "hermes.guide.tunnel.toggle": [
            .english: "VPS through SSH tunnel",
            .spanish: "VPS por túnel SSH",
            .russian: "VPS через SSH-туннель"
        ],
        "hermes.guide.tunnel.toggle.help": [
            .english: "Enable when the loopback address forwards to another computer. Cuate uploads and downloads files through Dashboard and does not offer to modify a local Hermes installation. This switch does not create a tunnel.",
            .spanish: "Actívalo si la dirección local redirige a otro equipo. Cuate transfiere archivos mediante Dashboard y no ofrece modificar una instalación local de Hermes. Este control no crea el túnel.",
            .russian: "Включите, если локальный адрес ведёт на другой компьютер через туннель. Cuate передаёт файлы через Dashboard и не предлагает менять локальную установку Hermes. Сам туннель этот переключатель не создаёт."
        ],
        "hermes.guide.prerequisites": [
            .english: "You need a VPS, its SSH login and an SSH key, plus a model provider account or API key. First confirm that your usual SSH command connects from the Mac. These complete commands cover a dedicated Ubuntu 22/24 VPS, the root account, and a standard Hermes installation in /root/.hermes/hermes-agent. Docker installations, custom service users, and servers already hosting websites need their administrator’s configuration: [advanced VPS guide](https://github.com/kidem42/Cuate/blob/main/docs/hermes-vps-setup.md). Cuate is the client; it does not buy a server or configure it when you open this guide.",
            .spanish: "Necesitas un VPS, acceso SSH con clave y una cuenta de proveedor de modelos o clave API. Comprueba primero que tu comando SSH habitual conecta desde el Mac. Estos comandos cubren un VPS Ubuntu 22/24 dedicado, la cuenta root y Hermes en /root/.hermes/hermes-agent. Docker, usuarios de servicio personalizados y servidores con sitios web requieren configuración de su administrador: [guía avanzada](https://github.com/kidem42/Cuate/blob/main/docs/hermes-vps-setup.md). Cuate es el cliente; abrir esta guía no compra ni configura un servidor.",
            .russian: "Понадобятся VPS, доступ к нему по SSH с ключом и аккаунт провайдера модели либо API-ключ. Сначала убедитесь, что ваша обычная команда SSH подключает Mac к серверу. Готовые команды рассчитаны на отдельный VPS с Ubuntu 22/24, входом root и обычной установкой Hermes в /root/.hermes/hermes-agent. Для Docker, другого пользователя службы и сервера с работающими сайтами нужна настройка администратором: [расширенная инструкция](https://github.com/kidem42/Cuate/blob/main/docs/hermes-vps-setup.md). Cuate — клиент: открытие этой инструкции не покупает и не настраивает сервер."
        ],
        "hermes.guide.prepare.title": [
            .english: "1. VPS — prepare Hermes",
            .spanish: "1. VPS — preparar Hermes",
            .russian: "1. VPS — подготовить Hermes"
        ],
        "hermes.guide.prepare.body": [
            .english: "Connect to the VPS with your usual SSH command. If Hermes is missing, install it using the [official instructions](https://hermes-agent.nousresearch.com/docs/). Run each command separately and wait for it to finish before pasting the next one.",
            .spanish: "Conecta al VPS con tu comando SSH habitual. Si falta Hermes, sigue la [instalación oficial](https://hermes-agent.nousresearch.com/docs/). Ejecuta cada comando por separado y espera a que termine antes de pegar el siguiente.",
            .russian: "Подключитесь к VPS своей обычной командой SSH. Если Hermes ещё не установлен, установите его по [официальной инструкции](https://hermes-agent.nousresearch.com/docs/). Выполняйте команды по одной и дожидайтесь завершения, прежде чем вставлять следующую."
        ],
        "hermes.guide.prepare.check": [
            .english: "Wait for setup to finish before pasting another command. Then open the chat, send “Hello” and wait for a reply. Exit with Ctrl+C. Continue only after it replies.",
            .spanish: "Espera a que termine la configuración antes de pegar otro comando. Abre el chat, escribe «Hola» y espera la respuesta. Sal con Ctrl+C. Continúa cuando responda.",
            .russian: "Дождитесь завершения мастера, прежде чем вставлять следующую команду. Затем откройте чат, напишите «Привет» и дождитесь ответа. Выйдите через Ctrl+C. Продолжайте, когда Hermes отвечает."
        ],
        "hermes.guide.server.title": [
            .english: "2. VPS — chat, files and compatibility patch",
            .spanish: "2. VPS — chat, archivos y parche",
            .russian: "2. VPS — чат, файлы и патч совместимости"
        ],
        "hermes.guide.server.body": [
            .english: "Paste this entire block into the VPS terminal. It preserves existing keys, configures private API ports, applies the Cuate patch with backups and enables both services at boot. Existing service definitions are retained; custom installations require the advanced guide. Success means “Gateway: OK” and “Dashboard: OK”, followed by two keys. Keep those keys private. If any command fails, stop and share the error without keys; do not bypass a patch check.",
            .spanish: "Pega el bloque completo en el terminal del VPS. Conserva claves existentes, configura puertos privados, aplica el parche con copias de seguridad y activa ambas funciones al arrancar. Conserva los servicios existentes; instalaciones personalizadas necesitan la guía avanzada. Debe mostrar «Gateway: OK» y «Dashboard: OK», seguidos de dos claves. No compartas las claves. Si falla, detente y comparte el error sin claves; no omitas comprobaciones del parche.",
            .russian: "Вставьте весь блок в терминал VPS. Он сохранит существующие ключи, настроит закрытые порты API, применит патч Cuate с резервными копиями и включит обе службы в автозагрузку. Описания существующих служб сохраняются; для нестандартной установки используйте расширенную инструкцию. Успех — строки «Gateway: OK» и «Dashboard: OK», затем два ключа. Ключи не публикуйте. При ошибке остановитесь и передайте её текст без ключей; не обходите проверки патча."
        ],
        "hermes.guide.domain.title": [
            .english: "3. VPS — connect the domain",
            .spanish: "3. VPS — conectar el dominio",
            .russian: "3. VPS — подключить домен"
        ],
        "hermes.guide.domain.body": [
            .english: "At your domain registrar, create two DNS A records: agent and dash, both pointing to the VPS IPv4 address. Allow inbound TCP ports 80 and 443 in the hosting firewall and any server firewall. Replace YOUR_DOMAIN below with your domain, for example example.com, then run the block on the VPS. It installs Caddy for HTTPS and refuses to overwrite an existing web setup. DNS propagation and certificate issuance can take time.",
            .spanish: "En tu registrador, crea dos registros DNS A: agent y dash, ambos con la IPv4 del VPS. Permite los puertos TCP entrantes 80 y 443 en los cortafuegos del hosting y del servidor. Cambia YOUR_DOMAIN por tu dominio, por ejemplo example.com, y ejecuta el bloque en el VPS. Instala Caddy para HTTPS y rechaza sobrescribir una configuración web existente. El DNS y el certificado pueden tardar.",
            .russian: "У регистратора домена создайте две DNS-записи типа A: agent и dash, обе с IPv4-адресом VPS. Разрешите входящие TCP-порты 80 и 443 в панели хостинга и в файрволе сервера, если он включён. Замените YOUR_DOMAIN ниже своим доменом, например example.com, и выполните блок на VPS. Он установит Caddy для HTTPS и откажется перезаписывать существующую веб-настройку. Обновление DNS и выдача сертификата могут занять время."
        ],
        "hermes.guide.tunnel.title": [
            .english: "3. Mac — automatic connection",
            .spanish: "3. Mac — conexión automática",
            .russian: "3. Mac — автоматическое подключение"
        ],
        "hermes.guide.tunnel.body": [
            .english: "Open a NEW Terminal window on the Mac, outside the SSH session. Close any previous manual tunnel using ports 18642/19119. In the block below replace YOUR_SERVER_IP and YOUR_SSH_KEY with the values from your working SSH command; adjust SSH_USER and SSH_PORT if needed. The key path is a file on the Mac. Paste the whole block. Enter the SSH key passphrase when asked; it is saved in macOS Keychain. If asked to trust an unfamiliar host, verify it through your normal SSH login first. “Tunnel ready” means Terminal can be closed. The block installs one login service for both chat and files.",
            .spanish: "Abre una NUEVA ventana de Terminal en el Mac, fuera de la sesión SSH. Cierra túneles manuales que usen 18642/19119. Sustituye YOUR_SERVER_IP y YOUR_SSH_KEY por los valores de tu comando SSH; ajusta SSH_USER y SSH_PORT si hace falta. La clave es un archivo del Mac. Pega todo el bloque e introduce su frase secreta: se guarda en el Llavero. Si el host no es conocido, verifícalo primero con tu acceso SSH habitual. «Tunnel ready» permite cerrar Terminal. El bloque instala un servicio de inicio para chat y archivos.",
            .russian: "Откройте НОВОЕ окно Терминала на Mac, вне SSH-сессии. Закройте прежний ручной туннель на портах 18642/19119. В блоке замените YOUR_SERVER_IP и YOUR_SSH_KEY значениями из рабочей команды SSH; при необходимости измените SSH_USER и SSH_PORT. Путь к ключу — это файл на Mac. Вставьте блок целиком. При запросе введите секретную фразу SSH-ключа: она сохранится в Связке ключей macOS. Если сервер ещё не известен SSH, сначала проверьте его обычным входом. После «Tunnel ready» Терминал можно закрыть. Блок устанавливает одну службу автозапуска сразу для чата и файлов."
        ],
        "hermes.guide.fields.title": [
            .english: "4. Cuate — fill in the connection fields",
            .spanish: "4. Cuate — rellenar la conexión",
            .russian: "4. Cuate — заполнить поля подключения"
        ],
        "hermes.guide.domain.fields": [
            .english: "In Settings → Hermes Agent, turn off “VPS through SSH tunnel”.\n\n| Field | Value |\n|---|---|\n| Gateway address | https://agent.YOUR_DOMAIN |\n| API key | Gateway key from step 2 |\n| Dashboard address | https://dash.YOUR_DOMAIN |\n| Dashboard session token | Dashboard token from step 2 |",
            .spanish: "En Ajustes → Agente Hermes, desactiva «VPS por túnel SSH».\n\n| Campo | Valor |\n|---|---|\n| Dirección del gateway | https://agent.YOUR_DOMAIN |\n| Clave API | Gateway key del paso 2 |\n| Dirección del dashboard | https://dash.YOUR_DOMAIN |\n| Token de sesión del dashboard | Dashboard token del paso 2 |",
            .russian: "В Настройки → Hermes-агент выключите «VPS через SSH-туннель».\n\n| Поле | Значение |\n|---|---|\n| Адрес гейтвея | https://agent.YOUR_DOMAIN |\n| API-ключ | Gateway key из шага 2 |\n| Адрес дашборда | https://dash.YOUR_DOMAIN |\n| Session-токен дашборда | Dashboard token из шага 2 |"
        ],
        "hermes.guide.tunnel.fields": [
            .english: "In Settings → Hermes Agent, turn ON “VPS through SSH tunnel”. This makes attachments travel to the VPS instead of using paths on the Mac.\n\n| Field | Value |\n|---|---|\n| Gateway address | http://127.0.0.1:18642 |\n| API key | Gateway key from step 2 |\n| Dashboard address | http://127.0.0.1:19119 |\n| Dashboard session token | Dashboard token from step 2 |",
            .spanish: "En Ajustes → Agente Hermes, ACTIVA «VPS por túnel SSH» para transferir archivos al VPS.\n\n| Campo | Valor |\n|---|---|\n| Dirección del gateway | http://127.0.0.1:18642 |\n| Clave API | Gateway key del paso 2 |\n| Dirección del dashboard | http://127.0.0.1:19119 |\n| Token de sesión del dashboard | Dashboard token del paso 2 |",
            .russian: "В Настройки → Hermes-агент ВКЛЮЧИТЕ «VPS через SSH-туннель». Тогда вложения отправляются на VPS, а не передаются как пути к файлам на Mac.\n\n| Поле | Значение |\n|---|---|\n| Адрес гейтвея | http://127.0.0.1:18642 |\n| API-ключ | Gateway key из шага 2 |\n| Адрес дашборда | http://127.0.0.1:19119 |\n| Session-токен дашборда | Dashboard token из шага 2 |"
        ],
        "hermes.guide.keys": [
            .english: "Save both keys using their Save buttons. These are two different server access keys. Your model provider key stays in Hermes on the VPS. Select the Hermes role in the chat to talk to that agent.",
            .spanish: "Guarda ambas claves con sus botones Guardar. Son dos claves de acceso distintas. La clave del proveedor de modelos se queda en Hermes en el VPS. Selecciona el rol Hermes en el chat.",
            .russian: "Сохраните оба ключа кнопками сохранения рядом с полями. Это два разных ключа доступа к серверу. Ключ провайдера модели остаётся в Hermes на VPS. Для общения с агентом выберите роль Hermes в чате."
        ],
        "hermes.guide.verify.title": [
            .english: "5. Check chat and files",
            .spanish: "5. Comprobar chat y archivos",
            .russian: "5. Проверить чат и файлы"
        ],
        "hermes.guide.verify.body": [
            .english: "Click Test connection. Send a message and wait for a reply. Attach a small text file and ask the agent to read its contents. Then ask it to create a text file for download and open that file from the reply. A green connection check alone does not verify file transfer. With Docker, the upload directory must be mounted at the same path inside the container; see the advanced guide.",
            .spanish: "Pulsa Probar conexión. Envía un mensaje, adjunta un archivo de texto y pide que lo lea. Después pide crear un archivo para descargar y ábrelo desde la respuesta. Una conexión verde no verifica los archivos. Con Docker, monta la carpeta de subidas en la misma ruta dentro del contenedor; consulta la guía avanzada.",
            .russian: "Нажмите проверку соединения. Отправьте сообщение и дождитесь ответа. Прикрепите небольшой текстовый файл и попросите прочитать его содержимое. Затем попросите создать файл для скачивания и откройте его из ответа. Зелёная проверка соединения сама по себе не проверяет файлы. При Docker папку загрузок нужно подключить внутри контейнера по тому же пути — см. расширенную инструкцию."
        ],
        "hermes.guide.domain.restart": [
            .english: "The VPS services and Caddy start at boot. Check once after a VPS restart. Cuate needs internet access but no SSH window.",
            .spanish: "Los servicios del VPS y Caddy arrancan automáticamente. Compruébalo tras reiniciar el VPS. Cuate necesita internet, pero no una ventana SSH.",
            .russian: "Службы VPS и Caddy запускаются при загрузке сервера. Один раз проверьте подключение после перезагрузки VPS. Cuate нужен интернет, но окно SSH не требуется."
        ],
        "hermes.guide.tunnel.restart": [
            .english: "The VPS services start at boot. The tunnel starts after this user logs into the Mac and reconnects after network interruptions or sleep. Check once after restarting the VPS and after logging back into the Mac. To remove tunnel autostart: run launchctl bootout gui/$(id -u)/com.cuate.hermes-tunnel on the Mac, then remove ~/Library/LaunchAgents/com.cuate.hermes-tunnel.plist.",
            .spanish: "Los servicios del VPS arrancan al encenderlo. El túnel se inicia al entrar en esta cuenta del Mac y se reconecta tras cortes o reposo. Comprueba ambos reinicios. Para quitar el inicio del túnel, ejecuta launchctl bootout gui/$(id -u)/com.cuate.hermes-tunnel en el Mac y elimina ~/Library/LaunchAgents/com.cuate.hermes-tunnel.plist.",
            .russian: "Службы VPS запускаются при загрузке сервера. Туннель запускается после входа этого пользователя в macOS и восстанавливается после обрывов или сна. Один раз проверьте перезагрузку VPS и повторный вход на Mac. Чтобы убрать автозапуск туннеля, выполните на Mac launchctl bootout gui/$(id -u)/com.cuate.hermes-tunnel и удалите ~/Library/LaunchAgents/com.cuate.hermes-tunnel.plist."
        ],
        "hermes.guide.trouble.title": [
            .english: "If something fails",
            .spanish: "Si algo falla",
            .russian: "Если возникла ошибка"
        ],
        "hermes.guide.trouble.body": [
            .english: "If Hermes reports no inference provider, finish step 1. If a patch anchor is missing, stop and send the error to support. If the server block rejects SQLite, and this installation uses uv-managed Python 3.11, run the block below on the VPS and retry step 2. Updating uv first matters. If uv cannot update itself or Hermes still uses an old SQLite, share the output instead of repeatedly reinstalling. For other Python versions, ask the server administrator.",
            .spanish: "Si falta un proveedor, termina el paso 1. Si falta un ancla del parche, detente y envía el error a soporte. Si el bloque rechaza SQLite y Hermes usa Python 3.11 gestionado por uv, ejecuta el bloque de abajo en el VPS y repite el paso 2. Primero se actualiza uv. Si uv no puede actualizarse o SQLite sigue antigua, comparte el resultado; no reinstales repetidamente. Para otras versiones de Python, consulta al administrador.",
            .russian: "Если Hermes сообщает, что провайдер не настроен, завершите шаг 1. Если патч не нашёл ожидаемый участок кода, остановитесь и передайте ошибку в поддержку. Если блок VPS остановился из-за SQLite и установка использует Python 3.11 от uv, выполните блок ниже на VPS и повторите шаг 2. Важно сначала обновить uv. Если uv не обновляется или SQLite в Hermes остаётся старой, передайте вывод вместо повторных переустановок. Для других версий Python обратитесь к администратору."
        ],
        "hermes.guide.maintenance": [
            .english: "These instructions do not schedule Hermes updates. A reboot preserves the patch; a Hermes update may overwrite it. Update deliberately with hermes update, then repeat the compatibility step and verify chat and files. Hosting-provider update jobs are separate. For an HTTP 401, check the key for that service; for an empty skills list, check /v1/skills before assuming skills are missing.",
            .spanish: "Esta guía no programa actualizaciones de Hermes. Reiniciar conserva el parche; actualizar Hermes puede sobrescribirlo. Actualiza con hermes update cuando lo decidas, repite el paso de compatibilidad y comprueba chat y archivos. Las tareas de actualización del hosting son independientes. Ante HTTP 401, revisa la clave del servicio; si no hay habilidades, comprueba /v1/skills antes de asumir que faltan.",
            .russian: "Эта инструкция не настраивает автообновление Hermes. Перезагрузка сохраняет патч, обновление Hermes может его перезаписать. Обновляйте осознанно командой hermes update, затем повторяйте шаг совместимости и проверяйте чат и файлы. Задания обновления от хостинга — отдельная настройка. При HTTP 401 проверьте ключ нужной службы; при пустом списке навыков сначала проверьте /v1/skills, а не считайте, что навыки отсутствуют."
        ],
        "hermes.tab": [.english: "Hermes Agent", .spanish: "Agente Hermes", .russian: "Hermes-агент"],
        "hermes.lock.switched": [
            .english: "Session model → %model% (%provider%)",
            .spanish: "Modelo de la sesión → %model% (%provider%)",
            .russian: "Модель сессии → %model% (%provider%)"
        ],
        "hermes.lock.rerouted": [
            .english: "⚠️ The gateway rerouted the lock: you asked for %requested%, but a model route in its config pins this model to %provider% — the session now runs %model% (%provider%). To really use %requested%, remove the model_routes alias on the gateway or pick a model without one.",
            .spanish: "⚠️ El gateway redirigió el bloqueo: pediste %requested%, pero una ruta de modelo en su configuración fija este modelo a %provider% — la sesión ahora usa %model% (%provider%). Para usar %requested% de verdad, elimina el alias de model_routes en el gateway o elige un modelo sin alias.",
            .russian: "⚠️ Гейтвей перенаправил лок: вы просили %requested%, но маршрут модели в его конфиге прибивает эту модель к %provider% — сессия теперь работает на %model% (%provider%). Чтобы реально использовать %requested%, уберите алиас в model_routes на гейтвее или выберите модель без алиаса."
        ],
        "hermes.lock.switchFailed": [
            .english: "Couldn't switch this session to %model%: %error%. The session keeps its previous model.",
            .spanish: "No se pudo cambiar esta sesión a %model%: %error%. La sesión mantiene su modelo anterior.",
            .russian: "Не удалось переключить сессию на %model%: %error%. Сессия остаётся на прежней модели."
        ],
        "hermes.fail.quota.hint": [
            .english: "👉 This looks like an exhausted provider quota. Pick a model from another provider in the model menu below the composer — or, if your limits have renewed, just send again: the session keeps your chosen model.",
            .spanish: "👉 Parece una cuota de proveedor agotada. Elige un modelo de otro proveedor en el menú de modelo bajo el compositor — o, si tus límites se han renovado, simplemente reenvía: la sesión mantiene tu modelo elegido.",
            .russian: "👉 Похоже, у провайдера исчерпан лимит. Выберите модель другого провайдера в меню модели под композером — или, если лимиты обновились, просто отправьте ещё раз: сессия остаётся на выбранной вами модели."
        ],
        "hermes.fail.model.hint": [
            .english: "👉 The gateway couldn't reach this session's model. Pick another one in the model menu below the composer.",
            .spanish: "👉 El gateway no pudo acceder al modelo de esta sesión. Elige otro en el menú de modelo bajo el compositor.",
            .russian: "👉 Гейтвею не удалось обратиться к модели этой сессии. Выберите другую в меню модели под композером."
        ],

        // MARK: Service-notice cards (delegation / process reports)
        "hermes.notice.delegation": [
            .english: "Subagent results",
            .spanish: "Resultados de subagentes",
            .russian: "Результаты субагентов"
        ],
        "hermes.notice.process": [
            .english: "Background process",
            .spanish: "Proceso en segundo plano",
            .russian: "Фоновый процесс"
        ],
        "hermes.notice.task": [
            .english: "Task %@",
            .spanish: "Tarea %@",
            .russian: "Задача %@"
        ],

        // MARK: General tab master switch
        "hermes.general.enable": [
            .english: "Hermes Agent (beta)",
            .spanish: "Agente Hermes (beta)",
            .russian: "Hermes-агент (бета)"
        ],
        "hermes.general.enable.caption": [
            .english: "Connect your self-hosted Hermes agent (Nous Research) as a role in the chat switcher. The agent keeps its own memory, tools and model keys; conversations continue across Telegram, CLI and this app.",
            .spanish: "Conecta tu agente Hermes autoalojado (Nous Research) como un rol en el selector del chat. El agente mantiene su propia memoria, herramientas y claves de modelos; las conversaciones continúan entre Telegram, CLI y esta app.",
            .russian: "Подключите свой самохостируемый Hermes-агент (Nous Research) как роль в свитчере чата. Агент хранит собственную память, инструменты и ключи моделей; беседы продолжаются между Telegram, CLI и этим приложением."
        ],

        // MARK: Connection section
        "hermes.conn.header": [.english: "Connection", .spanish: "Conexión", .russian: "Подключение"],

        // What the connected gateway advertises — the version string cannot
        // tell these builds apart, the capability flags can.
        "hermes.caps.streaming": [
            .english: "Live streaming:", .spanish: "Transmisión en vivo:", .russian: "Живой стрим:"
        ],
        "hermes.caps.steer": [
            .english: "Mid-turn follow-ups:", .spanish: "Mensajes durante el turno:",
            .russian: "Досылка в работающий ход:"
        ],
        "hermes.caps.steer.builtin": [
            .english: "built into the gateway", .spanish: "incluido en el gateway",
            .russian: "штатная ручка гейтвея"
        ],
        "hermes.caps.steer.patched": [
            .english: "through Cuate's patch", .spanish: "mediante el parche de Cuate",
            .russian: "через патч Cuate"
        ],
        "hermes.caps.files": [
            .english: "File exchange:", .spanish: "Intercambio de archivos:", .russian: "Обмен файлами:"
        ],
        "hermes.caps.files.unset": [
            .english: "dashboard not configured", .spanish: "panel no configurado",
            .russian: "дашборд не настроен"
        ],
        "hermes.caps.yes": [.english: "available", .spanish: "disponible", .russian: "доступно"],
        "hermes.caps.no": [.english: "unavailable", .spanish: "no disponible", .russian: "недоступно"],
        "hermes.conn.endpoint": [.english: "Gateway address", .spanish: "Dirección del gateway", .russian: "Адрес гейтвея"],
        "hermes.conn.endpoint.help": [
            .english: "http://127.0.0.1:8642 for a gateway on this Mac; a Tailscale/LAN address for a remote one.",
            .spanish: "http://127.0.0.1:8642 para un gateway en este Mac; una dirección de Tailscale/LAN para uno remoto.",
            .russian: "http://127.0.0.1:8642 для гейтвея на этом Mac; адрес Tailscale/LAN — для удалённого."
        ],
        "hermes.conn.key": [.english: "API key", .spanish: "Clave API", .russian: "API-ключ"],
        "hermes.conn.key.placeholder": [
            .english: "API_SERVER_KEY from the gateway's .env",
            .spanish: "API_SERVER_KEY del .env del gateway",
            .russian: "API_SERVER_KEY из .env гейтвея"
        ],
        "hermes.conn.key.save": [.english: "Save", .spanish: "Guardar", .russian: "Сохранить"],
        "hermes.conn.key.remove": [.english: "Remove", .spanish: "Eliminar", .russian: "Удалить"],
        "hermes.conn.test": [.english: "Test connection", .spanish: "Probar conexión", .russian: "Проверить соединение"],
        "hermes.conn.testing": [.english: "Checking…", .spanish: "Comprobando…", .russian: "Проверяю…"],
        "hermes.conn.security": [
            .english: "The key is stored only in the Keychain. It grants full access to the agent's tools — including its terminal. For a remote gateway, prefer Tailscale/WireGuard over exposing the port.",
            .spanish: "La clave se guarda solo en el Llavero. Da acceso completo a las herramientas del agente — incluida su terminal. Para un gateway remoto, prefiere Tailscale/WireGuard antes que exponer el puerto.",
            .russian: "Ключ хранится только в Keychain. Он даёт полный доступ к инструментам агента — включая его терминал. Для удалённого гейтвея используйте Tailscale/WireGuard, а не открытый порт."
        ],

        // MARK: Host app features in agent sessions (separate opt-in)
        "hermes.appFeatures.header": [
            .english: "App features",
            .spanish: "Funciones de la app",
            .russian: "Функции приложения"
        ],
        "hermes.appFeatures.toggle": [
            .english: "Image processing and OCR in agent sessions",
            .spanish: "Procesado de imágenes y OCR en sesiones del agente",
            .russian: "Обработка изображений и OCR в сессиях агента"
        ],
        "hermes.appFeatures.caption": [
            .english: "Off: the agent handles attachments entirely on its own. On: the app's Upscale, Remove Background, Remove Objects and Extract Text actions also appear in agent chats — they run on the app's own models and keys (pick the models in the Images tab and the OCR provider in the Chat tab), and results stay in this app only, invisible to the agent's other surfaces.",
            .spanish: "Desactivado: el agente gestiona los adjuntos por su cuenta. Activado: las acciones de la app — Escalar, Quitar fondo, Eliminar objetos y Extraer texto — aparecen también en los chats del agente; usan los modelos y claves propios de la app (elige los modelos en la pestaña Imágenes y el proveedor de OCR en la pestaña Chat), y los resultados se quedan solo en esta app, invisibles para las demás superficies del agente.",
            .russian: "Выкл.: агент разбирается с вложениями полностью сам. Вкл.: действия приложения — «Апскейл», «Убрать фон», «Удалить объекты» и «Извлечь текст» — появляются и в чатах агента; они работают на собственных моделях и ключах приложения (модели — во вкладке «Изображения», провайдер OCR — во вкладке «Чат»), а результаты остаются только в этом приложении и не видны другим поверхностям агента."
        ],

        // MARK: Dashboard courier (remote files)
        "hermes.dash.header": [
            .english: "Remote files (dashboard)",
            .spanish: "Archivos remotos (dashboard)",
            .russian: "Файлы на удалённой машине (дашборд)"
        ],
        "hermes.dash.url": [
            .english: "Dashboard address",
            .spanish: "Dirección del dashboard",
            .russian: "Адрес дашборда"
        ],
        "hermes.dash.url.placeholder": [
            .english: "http://HOST:9119 (via Tailscale/SSH tunnel)",
            .spanish: "http://HOST:9119 (vía Tailscale/túnel SSH)",
            .russian: "http://ХОСТ:9119 (через Tailscale/SSH-туннель)"
        ],
        "hermes.dash.token": [
            .english: "Dashboard session token",
            .spanish: "Token de sesión del dashboard",
            .russian: "Session-токен дашборда"
        ],
        "hermes.dash.caption": [
            .english: "Only needed for a REMOTE gateway: file attachments are uploaded to the agent's machine (~/cuate-uploads) through the Hermes dashboard's files API before sending. A local gateway reads your files directly — leave empty.",
            .spanish: "Solo para un gateway REMOTO: los adjuntos se suben a la máquina del agente (~/cuate-uploads) mediante la API de archivos del dashboard antes de enviar. Un gateway local lee tus archivos directamente — déjalo vacío.",
            .russian: "Нужно только для УДАЛЁННОГО гейтвея: файлы-вложения перед отправкой загружаются на машину агента (~/cuate-uploads) через files-API дашборда Hermes. Локальный гейтвей читает файлы напрямую — оставьте пустым."
        ],
        "hermes.dash.missing": [
            .english: "The gateway is remote, but the dashboard courier is not set up (Settings → Hermes Agent → Remote files) — the agent cannot read paths from this Mac.",
            .spanish: "El gateway es remoto, pero el courier del dashboard no está configurado (Ajustes → Agente Hermes → Archivos remotos) — el agente no puede leer rutas de este Mac.",
            .russian: "Гейтвей удалённый, а курьер дашборда не настроен (Настройки → Hermes-агент → Файлы на удалённой машине) — агент не сможет прочитать пути с этого Mac."
        ],
        "hermes.dash.uploadFailed": [
            .english: "Failed to upload to the agent's machine: %@",
            .spanish: "No se pudo subir a la máquina del agente: %@",
            .russian: "Не удалось загрузить на машину агента: %@"
        ],

        // MARK: Onboarding (server-side setup)
        "hermes.setup.header": [.english: "Gateway setup", .spanish: "Configuración del gateway", .russian: "Настройка гейтвея"],
        "hermes.setup.intro": [
            .english: "On the machine running Hermes, enable the API server and start the gateway:",
            .spanish: "En la máquina donde corre Hermes, activa el servidor API y arranca el gateway:",
            .russian: "На машине с Hermes включите API-сервер и запустите гейтвей:"
        ],
        "hermes.setup.local.title": [
            .english: "Hermes on this Mac — run in Terminal once:",
            .spanish: "Hermes en este Mac — ejecuta en Terminal una vez:",
            .russian: "Hermes на этом Mac — выполните в Терминале один раз:"
        ],
        "hermes.setup.showKey": [
            .english: "The API server is already enabled? Just read the existing key:",
            .spanish: "¿El servidor API ya está activado? Solo lee la clave existente:",
            .russian: "API-сервер уже включён? Просто покажите существующий ключ:"
        ],
        "hermes.setup.remote.title": [
            .english: "Hermes on a remote machine (VPS, cloud server, home server, Mac mini) — over SSH:",
            .spanish: "Hermes en una máquina remota (VPS, servidor en la nube, servidor doméstico, Mac mini) — por SSH:",
            .russian: "Hermes на удалённой машине (VPS, облачный сервер, домашний сервер, Mac mini) — через SSH:"
        ],
        "hermes.setup.remote.caption": [
            .english: "Then set the gateway address above to http://HOST:8642. API_SERVER_HOST=0.0.0.0 is required — by default the server listens on loopback only. Prefer a Tailscale/WireGuard address over exposing the port to the internet.",
            .spanish: "Luego pon la dirección del gateway arriba como http://HOST:8642. API_SERVER_HOST=0.0.0.0 es obligatorio — por defecto el servidor escucha solo en loopback. Prefiere una dirección de Tailscale/WireGuard antes que exponer el puerto a internet.",
            .russian: "Затем укажите адрес гейтвея выше: http://ХОСТ:8642. API_SERVER_HOST=0.0.0.0 обязателен — по умолчанию сервер слушает только loopback. Для доступа используйте адрес Tailscale/WireGuard, а не открытый в интернет порт."
        ],
        "hermes.setup.copy": [.english: "Copy", .spanish: "Copiar", .russian: "Скопировать"],

        // MARK: Model routing
        "hermes.model.header": [.english: "Agent model", .spanish: "Modelo del agente", .russian: "Модель агента"],
        "hermes.model.auto": [
            .english: "Agent's own default",
            .spanish: "Predeterminado del agente",
            .russian: "Как настроено у агента"
        ],
        "hermes.model.caption": [
            .english: "The agent is a black box with its own configuration — new sessions follow its configured model unless you pick another one here.",
            .spanish: "El agente es una caja negra con su propia configuración — las sesiones nuevas siguen su modelo configurado salvo que elijas otro aquí.",
            .russian: "Агент — чёрный ящик со своей конфигурацией: новые сессии идут на его модель, если здесь не выбрана другая."
        ],

        // MARK: Sessions section
        "hermes.sessions.header": [.english: "Agent sessions", .spanish: "Sesiones del agente", .russian: "Сессии агента"],
        "hermes.sessions.caption": [
            .english: "The agent's sessions exist beyond this app (Telegram, CLI, cron). \"Continue here\" binds the role's chat to an existing session.",
            .spanish: "Las sesiones del agente existen más allá de esta app (Telegram, CLI, cron). \"Continuar aquí\" vincula el chat del rol a una sesión existente.",
            .russian: "Сессии агента существуют и без этого приложения (Telegram, CLI, крон). «Продолжить здесь» привязывает чат роли к выбранной сессии."
        ],
        "hermes.sessions.continue": [.english: "Continue here", .spanish: "Continuar aquí", .russian: "Продолжить здесь"],
        "hermes.sessions.delete": [.english: "Delete", .spanish: "Eliminar", .russian: "Удалить"],
        "hermes.sessions.refresh": [.english: "Refresh", .spanish: "Actualizar", .russian: "Обновить"],
        "hermes.sessions.empty": [.english: "No sessions on the gateway.", .spanish: "No hay sesiones en el gateway.", .russian: "На гейтвее нет сессий."],
        "hermes.sessions.working": [.english: "The agent is working in this session…", .spanish: "El agente está trabajando en esta sesión…", .russian: "Агент работает в этой сессии…"],
        "hermes.sessions.creating": [.english: "Creating session…", .spanish: "Creando sesión…", .russian: "Создаю сессию…"],
        "hermes.sessions.createFailed": [
            .english: "Couldn't create the session — the gateway didn't respond. Check the connection and try again.",
            .spanish: "No se pudo crear la sesión: el gateway no respondió. Revisa la conexión e inténtalo de nuevo.",
            .russian: "Не удалось создать сессию — гейтвей не ответил. Проверьте соединение и попробуйте ещё раз."
        ],
        "hermes.sessions.messages": [.english: "%d messages", .spanish: "%d mensajes", .russian: "%d сообщений"],

        // MARK: Formatting briefing (per-session preamble)
        "hermes.briefing.header": [
            .english: "Formatting briefing",
            .spanish: "Instrucciones de formato",
            .russian: "Брифинг по форматированию"
        ],
        "hermes.briefing.toggle": [
            .english: "Teach the agent Cuate's formatting",
            .spanish: "Enseñar al agente el formato de Cuate",
            .russian: "Обучать агента форматированию Cuate"
        ],
        "hermes.briefing.caption": [
            .english: "The first message of each session carries a hidden preamble telling the agent how to format replies for this app: rich Markdown, HTML/Mermaid blocks only for interactives and diagrams, full re-issues of edited documents. Costs ~350 tokens once per session; the agent's other surfaces are unaffected, though the preamble is visible when that session's transcript is read from Telegram or the CLI.",
            .spanish: "El primer mensaje de cada sesión lleva un preámbulo oculto que indica al agente cómo formatear las respuestas para esta app: Markdown completo, bloques HTML/Mermaid solo para interactivos y diagramas, reediciones completas de documentos corregidos. Cuesta ~350 tokens una vez por sesión; las demás superficies del agente no se ven afectadas, aunque el preámbulo es visible al leer esa sesión desde Telegram o la CLI.",
            .russian: "Первое сообщение каждой сессии несёт скрытую преамбулу — как оформлять ответы для этого приложения: полноценный Markdown, блоки HTML/Mermaid только для интерактивов и диаграмм, правки документов — полным переизданием. Стоит ~350 токенов один раз на сессию; другие поверхности агента не затрагиваются, но преамбула видна, если читать транскрипт той же сессии из Telegram или CLI."
        ],

        // MARK: Notifications
        "hermes.notif.header": [.english: "Notifications", .spanish: "Notificaciones", .russian: "Уведомления"],
        "hermes.notif.hideDetails": [
            .english: "Hide command details in banners",
            .spanish: "Ocultar detalles de comandos en los avisos",
            .russian: "Скрывать детали команд в баннерах"
        ],
        "hermes.notif.hideDetails.caption": [
            .english: "Banners say \"the agent asks permission\" without the command text — it can be visible on the lock screen.",
            .spanish: "Los avisos dicen \"el agente pide permiso\" sin el texto del comando — puede verse en la pantalla bloqueada.",
            .russian: "Баннер скажет «агент просит разрешение» без текста команды — он может быть виден на заблокированном экране."
        ],

        // MARK: Diagnostics
        "hermes.diag.header": [.english: "Diagnostics", .spanish: "Diagnóstico", .russian: "Диагностика"],
        "hermes.diag.server": [.english: "Gateway", .spanish: "Gateway", .russian: "Гейтвей"],

        // MARK: Session management (sidebar)
        "hermes.sessions.new": [.english: "New session", .spanish: "Nueva sesión", .russian: "Новая сессия"],
        "hermes.sessions.rename": [.english: "Rename", .spanish: "Renombrar", .russian: "Переименовать"],
        "hermes.sessions.pin": [.english: "Pin", .spanish: "Fijar", .russian: "Закрепить"],
        "hermes.sessions.unpin": [.english: "Unpin", .spanish: "Soltar", .russian: "Открепить"],
        "hermes.sessions.color": [.english: "Color", .spanish: "Color", .russian: "Цвет"],
        "hermes.sessions.color.red": [.english: "Red", .spanish: "Rojo", .russian: "Красный"],
        "hermes.sessions.color.orange": [.english: "Orange", .spanish: "Naranja", .russian: "Оранжевый"],
        "hermes.sessions.color.yellow": [.english: "Yellow", .spanish: "Amarillo", .russian: "Жёлтый"],
        "hermes.sessions.color.green": [.english: "Green", .spanish: "Verde", .russian: "Зелёный"],
        "hermes.sessions.color.teal": [.english: "Teal", .spanish: "Turquesa", .russian: "Бирюзовый"],
        "hermes.sessions.color.blue": [.english: "Blue", .spanish: "Azul", .russian: "Синий"],
        "hermes.sessions.color.purple": [.english: "Purple", .spanish: "Morado", .russian: "Фиолетовый"],
        "hermes.sessions.color.pink": [.english: "Pink", .spanish: "Rosa", .russian: "Розовый"],
        "hermes.sessions.color.gray": [.english: "Gray", .spanish: "Gris", .russian: "Серый"],
        "hermes.sessions.color.none": [.english: "No color", .spanish: "Sin color", .russian: "Без цвета"],
        "hermes.sidebar.openApp": [
            .english: "Configure in the Hermes app (skill toggles, backends, messengers)",
            .spanish: "Configurar en la app de Hermes (habilidades, backends, mensajeros)",
            .russian: "Настроить в приложении Hermes (тоглы скиллов, бэкенды, мессенджеры)"
        ],
        "hermes.slash.skills": [.english: "Agent skills", .spanish: "Habilidades del agente", .russian: "Скиллы агента"],
        "hermes.slash.cuate": [.english: "Cuate (local)", .spanish: "Cuate (local)", .russian: "Cuate (локально)"],
        "hermes.composer.effort": [.english: "Effort", .spanish: "Esfuerzo", .russian: "Усилие"],
        "hermes.composer.effort.default": [.english: "Agent default", .spanish: "Predeterminado", .russian: "Как у агента"],
        "hermes.vps.open": [
            .english: "VPS setup guide",
            .spanish: "Guía de instalación en VPS",
            .russian: "Гайд по установке на VPS"
        ],
        "hermes.vps.caption": [
            .english: "Full walkthrough: your own agent on a VPS over HTTPS, reachable from any network without a VPN — 4 steps, two paste-blocks. Self-sufficient: read it here, or copy and hand it to any capable LLM to be walked through.",
            .spanish: "Guía completa: tu propio agente en un VPS por HTTPS, accesible desde cualquier red sin VPN — 4 pasos, dos bloques para pegar. Autosuficiente: léela aquí, o cópiala y dásela a cualquier LLM capaz para que te acompañe.",
            .russian: "Полный проход: свой агент на VPS по HTTPS, доступен из любой сети без VPN — 4 шага, две вставки. Самодостаточный текст: читайте здесь или скопируйте и отдайте любой нейронке — она проведёт по шагам."
        ],
        "hermes.composer.context.help": [
            .english: "How full this session's context is (tokens of the last turn, against this model's own window). Click to compact it now — the gateway also compacts on its own near the limit.",
            .spanish: "Cuán lleno está el contexto de esta sesión (tokens del último turno, sobre la ventana propia de este modelo). Clic para compactarlo ahora — el gateway también compacta solo cerca del límite.",
            .russian: "Насколько заполнен контекст этой сессии (токены последнего хода от окна ЭТОЙ модели). Клик — сжать сейчас; у предела гейтвей сжимает и сам."
        ],
        "hermes.composer.model.help": [
            .english: "Model for THIS session (switches the gateway's session lock)",
            .spanish: "Modelo para ESTA sesión (cambia el bloqueo de sesión del gateway)",
            .russian: "Модель ЭТОЙ сессии (переключает session lock на гейтвее)"
        ],

        // MARK: Sidebar section tooltips (what the categories ARE)
        "hermes.sessions.help": [
            .english: "The agent's conversations across ALL its surfaces — Telegram, CLI, this app. Click one to continue it here; right-click to rename, pin, color or delete. The badge counts messages that arrived while the thread was closed.",
            .spanish: "Las conversaciones del agente en TODAS sus superficies — Telegram, CLI, esta app. Clic para continuarla aquí; clic derecho para renombrar, fijar, colorear o borrar. La insignia cuenta mensajes llegados con el hilo cerrado.",
            .russian: "Беседы агента на ВСЕХ его поверхностях — Telegram, CLI, это приложение. Клик — продолжить здесь; правый клик — переименовать, закрепить, цвет, удалить. Бейдж считает сообщения, пришедшие, пока тред был закрыт."
        ],
        "hermes.skills.help": [
            .english: "The agent's saved skills — procedures it learned (notes, arXiv, ASCII art…). Invoke one in the chat by typing /skill-name; enable/disable them in the Hermes app.",
            .spanish: "Las habilidades guardadas del agente — procedimientos aprendidos (notas, arXiv, ASCII art…). Invócalas en el chat con /nombre; se activan en la app de Hermes.",
            .russian: "Сохранённые навыки агента — его выученные процедуры (заметки, arXiv, ASCII-арт…). Вызываются в чате через /имя-скилла; включаются и выключаются в приложении Hermes."
        ],
        "hermes.toolsets.help": [
            .english: "Tool groups the agent can use on ITS host: web search, browser, terminal, files… Dimmed = disabled on the gateway; toggling lives in the Hermes app.",
            .spanish: "Grupos de herramientas que el agente usa en SU host: web, navegador, terminal, archivos… Atenuado = desactivado en el gateway; se conmutan en la app de Hermes.",
            .russian: "Группы инструментов, доступные агенту на ЕГО хосте: веб-поиск, браузер, терминал, файлы… Приглушённые — выключены на гейтвее; переключаются в приложении Hermes."
        ],
        "hermes.agent.help": [
            .english: "The agent's passport: the model it currently thinks with, and the host where its commands and tools actually execute — check it before approving anything.",
            .spanish: "El pasaporte del agente: el modelo con el que piensa ahora y el host donde se ejecutan sus comandos y herramientas — míralo antes de aprobar algo.",
            .russian: "Паспорт агента: модель, которой он сейчас думает, и хост, где реально исполняются его команды и инструменты — сверяйтесь перед тем, как что-то одобрять."
        ],

        // MARK: Sidebar (management column)
        "hermes.sidebar.skills": [.english: "Skills", .spanish: "Habilidades", .russian: "Скиллы"],
        "hermes.sidebar.toolsets": [.english: "Toolsets", .spanish: "Herramientas", .russian: "Тулсеты"],
        "hermes.sidebar.agent": [.english: "Agent", .spanish: "Agente", .russian: "Агент"],
        "hermes.sidebar.toolsetOff": [.english: "disabled", .spanish: "desactivado", .russian: "выключен"],
        "hermes.sidebar.more": [.english: "+%d more", .spanish: "+%d más", .russian: "ещё %d"],
        "hermes.sidebar.execNote": [
            .english: "Tools and commands run on this host",
            .spanish: "Las herramientas y comandos se ejecutan en este host",
            .russian: "Инструменты и команды выполняются на этом хосте"
        ],
        "hermes.sidebar.toggle": [
            .english: "Agent panel",
            .spanish: "Panel del agente",
            .russian: "Панель агента"
        ],

        // MARK: Chat-side
        "hermes.noKey": [
            .english: "No gateway key yet — paste the API_SERVER_KEY in Settings → Hermes Agent (opening it now).",
            .spanish: "Aún no hay clave del gateway — pega la API_SERVER_KEY en Ajustes → Agente Hermes (abriéndolo ahora).",
            .russian: "Ключ гейтвея ещё не введён — вставьте API_SERVER_KEY в Настройках → Hermes-агент (открываю их)."
        ],
        "hermes.setup.local.auto": [
            .english: "Hermes on this Mac needs no terminal: when the gateway is unreachable, the Connection section offers a one-click setup that configures it and installs it as a service.",
            .spanish: "Hermes en este Mac no necesita terminal: cuando el gateway no responde, la sección Conexión ofrece una configuración de un clic que lo configura y lo instala como servicio.",
            .russian: "Для Hermes на этом Маке терминал не нужен: когда гейтвей недоступен, в секции «Подключение» появляется настройка в один клик — она всё конфигурирует и ставит сервис."
        ],

        // MARK: One-click local gateway setup
        "hermes.auto.found": [
            .english: "Hermes is installed on this Mac, but its gateway (which hosts the API server) is not running. Cuate can configure it and install it as a background service that starts on login.",
            .spanish: "Hermes está instalado en este Mac, pero su gateway (que aloja el servidor API) no está en marcha. Cuate puede configurarlo e instalarlo como servicio en segundo plano que arranca al iniciar sesión.",
            .russian: "Hermes установлен на этом Маке, но его гейтвей (в нём живёт API-сервер) не запущен. Cuate может настроить его и установить как фоновый сервис с автозапуском при входе."
        ],
        "hermes.auto.run": [
            .english: "Set up and start the service",
            .spanish: "Configurar y arrancar el servicio",
            .russian: "Настроить и запустить сервис"
        ],
        "hermes.auto.running": [
            .english: "Setting up the gateway…",
            .spanish: "Configurando el gateway…",
            .russian: "Настраиваю гейтвей…"
        ],
        "hermes.auto.ok": [
            .english: "Done: the gateway is installed as a service (starts on login, listed as “Hermes Gateway (Cuate)” in Login Items), the key from .env is saved and verified.",
            .spanish: "Listo: el gateway está instalado como servicio (arranca al iniciar sesión, aparece como “Hermes Gateway (Cuate)” en Ítems de inicio), la clave de .env está guardada y verificada.",
            .russian: "Готово: гейтвей установлен как сервис (автозапуск при входе, в «Объектах входа» — «Hermes Gateway (Cuate)»), ключ из .env сохранён и проверен."
        ],
        "hermes.auto.step.env": [
            .english: "Completing ~/.hermes/.env…",
            .spanish: "Completando ~/.hermes/.env…",
            .russian: "Дозаполняю ~/.hermes/.env…"
        ],
        "hermes.auto.step.install": [
            .english: "Installing the gateway service…",
            .spanish: "Instalando el servicio del gateway…",
            .russian: "Устанавливаю сервис гейтвея…"
        ],
        "hermes.auto.step.patch": [
            .english: "Applying gateway compatibility fixes…",
            .spanish: "Aplicando correcciones de compatibilidad del gateway…",
            .russian: "Применяю исправления совместимости гейтвея…"
        ],
        "hermes.patch.found": [
            .english: "This gateway needs compatibility fixes for the context gauge, background runs or model catalog. Cuate will back up the affected files, apply the matching fixes and restart the gateway. After an update, this offer may appear again.",
            .spanish: "Este gateway necesita correcciones de compatibilidad para el contexto, las tareas en segundo plano o el catálogo de modelos. Cuate guardará copias de los archivos afectados, aplicará las correcciones y reiniciará el gateway. Tras una actualización, esta opción puede reaparecer.",
            .russian: "Этому гейтвею нужны исправления совместимости для индикатора контекста, фоновых задач или списка моделей. Cuate сохранит копии затронутых файлов, применит подходящие исправления и перезапустит гейтвей. После обновления это предложение может появиться снова."
        ],
        "hermes.patch.run": [
            .english: "Apply gateway fixes",
            .spanish: "Aplicar correcciones del gateway",
            .russian: "Применить исправления гейтвея"
        ],
        "hermes.patch.running": [
            .english: "Patching the gateway and restarting…",
            .spanish: "Parcheando el gateway y reiniciando…",
            .russian: "Патчу гейтвей и перезапускаю…"
        ],
        "hermes.patch.ok": [
            .english: "Gateway fixes applied. Restart and model catalog check succeeded.",
            .spanish: "Correcciones aplicadas. El reinicio y la comprobación del catálogo de modelos se completaron correctamente.",
            .russian: "Исправления применены. Перезапуск и проверка списка моделей прошли успешно."
        ],
        "hermes.patch.err": [
            .english: "Could not patch the gateway:",
            .spanish: "No se pudo parchear el gateway:",
            .russian: "Не удалось пропатчить гейтвей:"
        ],
        "hermes.setup.patch.title": [
            .english: "Gateway patch: honest context gauge",
            .spanish: "Parche del gateway: medidor de contexto honesto",
            .russian: "Патч гейтвея: честный гейдж контекста"
        ],
        "hermes.setup.patch.caption": [
            .english: "Paste into the remote machine's terminal after a Hermes update. One anchored edit to api_server.py: usage.context_tokens / context_window — the real context fill, which the API otherwise omits, so the gauge stops estimating. Mid-turn follow-ups need no patch: recent Hermes ships its own route and Cuate uses it automatically. Backup next to the file; refuses on unknown layouts without touching anything. Safe to re-run; repeat after every Hermes update.",
            .spanish: "Pega esto en la terminal de la máquina remota tras actualizar Hermes. Una edición anclada en api_server.py: usage.context_tokens / context_window — el llenado real del contexto que la API omite, para que el medidor deje de estimar. Los mensajes durante el turno no necesitan parche: Hermes reciente trae su propia ruta y Cuate la usa sola. Copia de seguridad junto al archivo; se niega ante estructuras desconocidas sin tocar nada. Se puede repetir; repítelo tras cada actualización de Hermes.",
            .russian: "Вставьте в терминал удалённой машины после обновления Hermes. Одна правка по якорю в api_server.py: usage.context_tokens / context_window — реальное заполнение контекста, которого нет в API, чтобы индикатор не гадал. Досылка сообщений патча не требует: в свежем Hermes есть своя ручка, и Cuate использует её сама. Бэкап рядом с файлом; на незнакомой структуре откажется, ничего не тронув. Повторный запуск безопасен; после каждого обновления Hermes — повторить."
        ],
        "hermes.auto.step.reload": [
            .english: "Starting the gateway…",
            .spanish: "Arrancando el gateway…",
            .russian: "Запускаю гейтвей…"
        ],
        "hermes.auto.step.health": [
            .english: "Waiting for the gateway to answer…",
            .spanish: "Esperando respuesta del gateway…",
            .russian: "Жду ответа гейтвея…"
        ],
        "hermes.auto.err.keychain": [
            .english: "Could not save the key to the Keychain — open Settings → API Keys and allow Keychain access, then try again.",
            .spanish: "No se pudo guardar la clave en el Llavero — abre Ajustes → Claves API y permite el acceso al Llavero, luego inténtalo de nuevo.",
            .russian: "Не удалось сохранить ключ в Keychain — разрешите доступ к связке ключей и попробуйте ещё раз."
        ],
        "hermes.auto.err.probe": [
            .english: "The gateway is up, but the connection test still fails — see the message above.",
            .spanish: "El gateway está en marcha, pero la prueba de conexión sigue fallando — mira el mensaje de arriba.",
            .russian: "Гейтвей поднялся, но проверка соединения всё ещё не проходит — см. сообщение выше."
        ],
        "hermes.auto.err.cli": [
            .english: "The hermes CLI was not found on this Mac.",
            .spanish: "No se encontró la CLI de hermes en este Mac.",
            .russian: "CLI hermes на этом Маке не найден."
        ],
        "hermes.auto.err.env": [
            .english: "Could not update ~/.hermes/.env:",
            .spanish: "No se pudo actualizar ~/.hermes/.env:",
            .russian: "Не удалось обновить ~/.hermes/.env:"
        ],
        "hermes.auto.err.install": [
            .english: "hermes gateway install failed:",
            .spanish: "hermes gateway install falló:",
            .russian: "hermes gateway install завершился с ошибкой:"
        ],
        "hermes.auto.err.timeout": [
            .english: "The gateway did not come up — check ~/.hermes/logs/gateway.log.",
            .spanish: "El gateway no arrancó — revisa ~/.hermes/logs/gateway.log.",
            .russian: "Гейтвей так и не поднялся — загляните в ~/.hermes/logs/gateway.log."
        ],
        "hermes.role.help": [
            .english: "Hermes agent role — the conversation lives on the agent and continues across its other surfaces",
            .spanish: "Rol del agente Hermes — la conversación vive en el agente y continúa en sus otras superficies",
            .russian: "Роль Hermes-агента — беседа живёт у агента и продолжается на других его поверхностях"
        ]
    ]
}
